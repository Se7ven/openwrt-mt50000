#!/usr/bin/env bash
#
# regen-kernel-patches.sh - regenerate the kernel patches of the RTL8366UB
# switch driver against the kernel version that the build actually uses.
#
# The kernel patches are applied by the kernel build with "patch -p1": when
# the kernel of the branch moves, their context stops matching and the build
# dies. This script reproduces the kernel patch environment (the kernel
# tarball + the kernel patches of OpenWrt + our own patches) and regenerates
# the patch that has to be adapted.
#
# Usage: tools/regen-kernel-patches.sh --tree <openwrt-dir>
#
# The tree has to contain the kernel tarball in dl/ ("make download").
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"
[ -d "${TREE}" ] || die "tree not found: ${TREE}"

need_cmd patch tar python3 curl

KERNEL_SERIES="$(kernel_series "${TREE}")"
KVER_FILE="${TREE}/target/linux/generic/kernel-${KERNEL_SERIES}"
[ -f "${KVER_FILE}" ] || die "cannot find ${KVER_FILE}"
KERNEL_VERSION="$(python3 - "${KVER_FILE}" "${KERNEL_SERIES}" <<'PY'
import re, sys
path, series = sys.argv[1], sys.argv[2]
for line in open(path):
    m = re.match(r"LINUX_VERSION-%s\s*=\s*(\S+)" % re.escape(series), line)
    if m:
        v = m.group(1)
        print(v if v.startswith(series) else series + v)
        break
PY
)"
[ -n "${KERNEL_VERSION}" ] || die "cannot determine the kernel version"

TARBALL=""
for ext in tar.xz tar.gz tar.bz2 tar; do
	[ -f "${TREE}/dl/linux-${KERNEL_VERSION}.${ext}" ] && { TARBALL="${TREE}/dl/linux-${KERNEL_VERSION}.${ext}"; break; }
done
if [ -z "${TARBALL}" ]; then
	log "downloading linux-${KERNEL_VERSION}"
	mkdir -p "${TREE}/dl"
	curl -fSL -o "${TREE}/dl/linux-${KERNEL_VERSION}.tar.xz" \
		"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
	TARBALL="${TREE}/dl/linux-${KERNEL_VERSION}.tar.xz"
fi

WORK="$(mktemp -d)"
cleanup() { [ "${KEEP}" -eq 1 ] || rm -rf "${WORK}"; }
trap cleanup EXIT

log "unpacking linux-${KERNEL_VERSION}"
tar xf "${TARBALL}" -C "${WORK}"
KDIR="$(find "${WORK}" -maxdepth 1 -type d -name "linux-*" | head -1)"
[ -n "${KDIR}" ] || die "cannot unpack the kernel tarball"

apply_patch_dir() {
	local dir="$1" p
	[ -d "${dir}" ] || return 0
	for p in $(ls "${dir}"/*.patch 2>/dev/null | sort); do
		patch -f -p1 --forward -d "${KDIR}" -s < "${p}" >/dev/null 2>&1 || true
	done
}

log "applying the kernel patches of OpenWrt"
apply_patch_dir "${TREE}/target/linux/generic/backport-${KERNEL_SERIES}"
apply_patch_dir "${TREE}/target/linux/generic/pending-${KERNEL_SERIES}"
apply_patch_dir "${TREE}/target/linux/generic/hack-${KERNEL_SERIES}"
apply_patch_dir "${TREE}/target/linux/mediatek/patches-${KERNEL_SERIES}"

KDIR="${KDIR}" python3 - <<'PY'
import os, re, sys

kdir = os.environ["KDIR"]
path = os.path.join(kdir, "drivers/net/ethernet/mediatek/mtk_eth_soc.c")
txt = open(path).read()

# the block that allocates the dummy NAPI device
alloc_re = re.compile(
    r"\t/\* we run 2 devices on the same DMA ring so we need a dummy device\n"
    r"\t \* for NAPI to work[^\n]*\n"
    r"\t \*/\n"
    r"\teth->dummy_dev = alloc_netdev_dummy\(0\);\n"
    r"\tif \(!eth->dummy_dev\) \{\n"
    r"\t\terr = -ENOMEM;\n"
    r"\t\tdev_err\(eth->dev, \"failed to allocated dummy device\\n\"\);\n"
    r"\t\tgoto err_unreg_netdev;\n"
    r"\t\}\n"
    r"\teth->dummy_dev->threaded = 1;\n"
    r"\tstrcpy\(eth->dummy_dev->name, \"mtk_eth\"\);\n"
    r"\tnetif_napi_add\(eth->dummy_dev, &eth->tx_napi, mtk_napi_tx\);\n"
    r"\tnetif_napi_add\(eth->dummy_dev, &eth->rx_napi, mtk_napi_rx\);\n")

m = alloc_re.search(txt)
if not m:
    sys.exit("the dummy NAPI device block was not found - the kernel changed too much")
block = m.group(0)
txt = txt[:m.start()] + txt[m.end():]
# remove the empty line that followed the block
txt = txt.replace("\n\n\tplatform_set_drvdata(pdev, eth);", "\n\tplatform_set_drvdata(pdev, eth);", 1)

# the registration loop of the netdevs
loop_re = re.compile(
    r"\tfor \(i = 0; i < MTK_MAX_DEVS; i\+\+\) \{\n"
    r"\t\tif \(!eth->netdev\[i\]\)\n"
    r"\t\t\tcontinue;\n"
    r"\n"
    r"\t\terr = register_netdev\(eth->netdev\[i\]\);\n")
m = loop_re.search(txt)
if not m:
    sys.exit("the netdev registration loop was not found - the kernel changed too much")

new_block = (block
             .replace("for NAPI to work\n", "for NAPI to work. Allocate it before registering the netdevs, so a\n\t * userspace link-up cannot race with its initialization.\n")
             .replace("goto err_unreg_netdev;", "goto err_deinit_ppe;"))
txt = txt[:m.start()] + new_block + "\n" + txt[m.start():]

# free the dummy device on the error path
label = "err_unreg_netdev:\n\tmtk_unreg_dev(eth);\n"
if label not in txt:
    sys.exit("the error label err_unreg_netdev was not found")
txt = txt.replace(label, label +
                  "err_free_dummy:\n"
                  "\tnetif_napi_del(&eth->tx_napi);\n"
                  "\tnetif_napi_del(&eth->rx_napi);\n"
                  "\tfree_netdev(eth->dummy_dev);\n"
                  "\teth->dummy_dev = NULL;\n", 1)

open(path, "w").write(txt)
print("patched " + path)
PY

# --- generate the patch ------------------------------------------------------
BEFORE="${WORK}/mtk_eth_soc.c.before"
cp "${KDIR}/drivers/net/ethernet/mediatek/mtk_eth_soc.c" "${WORK}/mtk_eth_soc.c.after"
# undo the change to get the "before" version: apply the change in reverse
python3 - "${WORK}" <<'PY'
import os, re, subprocess, sys
work = sys.argv[1]
after = os.path.join(work, "mtk_eth_soc.c.after")
before = os.path.join(work, "mtk_eth_soc.c.before")
txt = open(after).read()

# move the dummy block back and restore the old error path
alloc_re = re.compile(
    r"\t/\* we run 2 devices on the same DMA ring so we need a dummy device\n"
    r"\t \* for NAPI to work\. Allocate it before registering the netdevs, so a\n"
    r"\t \* userspace link-up cannot race with its initialization\.\n"
    r"\t \*/\n"
    r"\teth->dummy_dev = alloc_netdev_dummy\(0\);\n"
    r"\tif \(!eth->dummy_dev\) \{\n"
    r"\t\terr = -ENOMEM;\n"
    r"\t\tdev_err\(eth->dev, \"failed to allocated dummy device\\n\"\);\n"
    r"\t\tgoto err_deinit_ppe;\n"
    r"\t\}\n"
    r"\teth->dummy_dev->threaded = 1;\n"
    r"\tstrcpy\(eth->dummy_dev->name, \"mtk_eth\"\);\n"
    r"\tnetif_napi_add\(eth->dummy_dev, &eth->tx_napi, mtk_napi_tx\);\n"
    r"\tnetif_napi_add\(eth->dummy_dev, &eth->rx_napi, mtk_napi_rx\);\n")
m = alloc_re.search(txt)
block = m.group(0)
txt = txt[:m.start()] + txt[m.end():]
old_block = (block
             .replace("for NAPI to work. Allocate it before registering the netdevs, so a\n\t * userspace link-up cannot race with its initialization.\n",
                      "for NAPI to work\n")
             .replace("goto err_deinit_ppe;", "goto err_unreg_netdev;"))
txt = txt.replace("\n\tplatform_set_drvdata(pdev, eth);", "\n" + old_block + "\n\tplatform_set_drvdata(pdev, eth);", 1)
txt = txt.replace("err_free_dummy:\n\tnetif_napi_del(&eth->tx_napi);\n\tnetif_napi_del(&eth->rx_napi);\n\tfree_netdev(eth->dummy_dev);\n\teth->dummy_dev = NULL;\n", "", 1)
open(before, "w").write(txt)
PY

OUT="${BUILDER_ROOT}/patches/vanilla/kernel/990-03-net-mediatek-init-dummy-napi-before-netdev-registration.patch"
{
	cat <<EOF
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: GL.iNet Test Build <support@gl-inet.com>
Date: Fri, 4 Sep 2026 12:00:00 +0800
Subject: [PATCH] net: ethernet: mediatek: init dummy NAPI device before netdev registration

The MediaTek Ethernet driver registers its netdevs before allocating the
dummy device used by the shared NAPI queues. A userspace link-up racing with
probe can therefore enter mtk_open() while dummy_dev is NULL, triggering the
XDP "Missing net_device from driver" warning and returning -ENODEV.

Allocate and initialize the dummy NAPI device before publishing any netdev,
and release it on the registration error path.

The context of the original patch was based on an older 6.18 snapshot, the
hunks are regenerated against linux ${KERNEL_VERSION}. The error path keeps the
unregistration of the already registered netdevs and frees the dummy device
afterwards, so the NAPI queues are not released too early.

Signed-off-by: GL.iNet Test Build <support@gl-inet.com>
---
diff --git a/drivers/net/ethernet/mediatek/mtk_eth_soc.c b/drivers/net/ethernet/mediatek/mtk_eth_soc.c
EOF
	diff -u --label a/drivers/net/ethernet/mediatek/mtk_eth_soc.c \
		--label b/drivers/net/ethernet/mediatek/mtk_eth_soc.c \
		"${BEFORE}" "${WORK}/mtk_eth_soc.c.after" || true
} > "${OUT}"

log "written: ${OUT}"
