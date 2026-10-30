#!/usr/bin/env bash
# regen-patches.sh - regenerate the "vanilla" patch series against upstream OpenWrt.
#
# The MT5000 support does not exist in upstream OpenWrt yet (PR #24237 is open),
# so the vanilla pipeline carries the whole set of changes as a patch series.
#
# Sources:
#   * upstream base : https://raw.githubusercontent.com/openwrt/openwrt/main/<path>
#   * GL.iNet source: https://raw.githubusercontent.com/GLiNet-Tech/openwrt/mt5000/<path>
#
# Usage:  tools/regen-patches.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${ROOT}/.patchgen"
OUT="${ROOT}/patches/vanilla"
UPSTREAM="https://raw.githubusercontent.com/openwrt/openwrt/main"
GLINET="https://raw.githubusercontent.com/GLiNet-Tech/openwrt/mt5000"

rm -rf "${WORK}"
mkdir -p "${WORK}/base" "${WORK}/new" "${OUT}"

fetch() { # fetch <url> <dest>
	mkdir -p "$(dirname "$2")"
	curl -fsSL "$1" -o "$2"
}

# ---------------------------------------------------------------- DTS (new file)
DTS="target/linux/mediatek/dts/mt7987a-glinet-gl-mt5000.dts"
mkdir -p "${WORK}/new/$(dirname "${DTS}")"
fetch "${GLINET}/${DTS}" "${WORK}/new/${DTS}"
{
	echo "Subject: [PATCH] mediatek: dts: add DTS for GL.iNet GL-MT5000 (Brume 3)"
	echo
	echo "Add the device tree for the GL.iNet GL-MT5000 (Brume 3): MediaTek MT7987A"
	echo "with an external Realtek RTL8366UB 2.5G switch behind gmac0 and the"
	echo "internal 2.5G PHY (gmac1) used as WAN."
	echo
	echo "Taken as-is from the GL.iNet mt5000 branch (see patches/vanilla/series)."
	echo
	diff -u --label /dev/null --label "b/${DTS}" /dev/null "${WORK}/new/${DTS}" || true
} > "${OUT}/0001-mediatek-dts-add-mt7987a-glinet-gl-mt5000.patch"

# ------------------------------------------------- image definition (filogic.mk)
IMG="target/linux/mediatek/image/filogic.mk"
fetch "${UPSTREAM}/${IMG}" "${WORK}/base/${IMG}"
mkdir -p "${WORK}/new/$(dirname "${IMG}")"
cp "${WORK}/base/${IMG}" "${WORK}/new/${IMG}"
python3 - "${WORK}/new/${IMG}" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
anchor = "TARGET_DEVICES += glinet_gl-mt3600be\n"
block = """
define Device/glinet_gl-mt5000
  DEVICE_VENDOR := GL.iNet
  DEVICE_MODEL := GL-MT5000
  DEVICE_DTS := mt7987a-glinet-gl-mt5000
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES := glinet,gl-mt5000
  DEVICE_PACKAGES := mkf2fs blkid blockdev kmod-fs-ext4 mt7987-2p5g-phy-firmware \\
                     kmod-mmc kmod-fs-f2fs kmod-fs-vfat
  IMAGES += factory.bin
  IMAGE/factory.bin := append-kernel | pad-to 32M | append-rootfs
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-gl-metadata
endef
TARGET_DEVICES += glinet_gl-mt5000
"""
if "glinet_gl-mt5000" in txt:
    sys.exit(0)
assert anchor in txt, "anchor not found in filogic.mk"
txt = txt.replace(anchor, anchor + block, 1)
open(path, "w").write(txt)
PY
{
	echo "Subject: [PATCH] mediatek: filogic: add image definition for GL-MT5000"
	echo
	echo "Add the GL.iNet GL-MT5000 (Brume 3) image definition: eMMC device with"
	echo "a factory image and a GL.iNet metadata carrying sysupgrade tarball."
	echo
	diff -u --label "a/${IMG}" --label "b/${IMG}" "${WORK}/base/${IMG}" "${WORK}/new/${IMG}" || true
} > "${OUT}/0002-mediatek-image-add-glinet-gl-mt5000.patch"

# ------------------------------------------------------ board.d/02_network
NET="target/linux/mediatek/filogic/base-files/etc/board.d/02_network"
fetch "${UPSTREAM}/${NET}" "${WORK}/base/${NET}"
mkdir -p "${WORK}/new/$(dirname "${NET}")"
cp "${WORK}/base/${NET}" "${WORK}/new/${NET}"
python3 - "${WORK}/new/${NET}" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
anchor = "\twavlink,wl-wnt100x3-ubootmod)\n\t\tucidef_set_interfaces_lan_wan eth0 eth1\n\t\t;;\n"
block = "\tglinet,gl-mt5000)\n\t\tucidef_set_interfaces_lan_wan \"lan1 lan2\" eth1\n\t\t;;\n"
if "gl-mt5000" in txt:
    sys.exit(0)
assert anchor in txt, "anchor not found in 02_network"
txt = txt.replace(anchor, anchor + block, 1)
open(path, "w").write(txt)
PY
{
	echo "Subject: [PATCH] mediatek: filogic: add network config for GL-MT5000"
	echo
	echo "The two 2.5G LAN ports are the user ports (lan1/lan2) of the RTL8366UB"
	echo "DSA switch, the WAN port is the internal 2.5G PHY of the SoC (eth1)."
	echo
	diff -u --label "a/${NET}" --label "b/${NET}" "${WORK}/base/${NET}" "${WORK}/new/${NET}" || true
} > "${OUT}/0003-mediatek-filogic-base-files-add-mt5000-network.patch"

# ------------------------------- network config for the swconfig flavour ---
# With the out-of-tree Realtek SDK driver (kmod-rtl8366ub) the switch is a
# plain swconfig switch, the layout is the one of the GL.iNet stock firmware:
# switch0 with the ports 0 and 1 as LAN and the port 17 as the CPU port.
cp "${WORK}/base/${NET}" "${WORK}/new/${NET}"
python3 - "${WORK}/new/${NET}" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
anchor = "\twavlink,wl-wnt100x3-ubootmod)\n\t\tucidef_set_interfaces_lan_wan eth0 eth1\n\t\t;;\n"
block = ("\tglinet,gl-mt5000)\n"
         "\t\tucidef_set_interfaces_lan_wan \"eth0.1\" eth1\n"
         "\t\tucidef_add_switch \"switch0\"\n"
         "\t\tucidef_add_switch_attr \"switch0\" \"enable\" true\n"
         "\t\tucidef_add_switch \"switch0\" \"0:lan\" \"1:lan\" \"17@eth0\"\n"
         "\t\tucidef_add_switch_attr \"switch0\" \"reset\" false\n"
         "\t\t;;\n")
if "gl-mt5000" in txt:
    sys.exit(0)
assert anchor in txt, "anchor not found in 02_network"
txt = txt.replace(anchor, anchor + block, 1)
open(path, "w").write(txt)
PY
{
	echo "Subject: [PATCH] mediatek: filogic: add network config for GL-MT5000 (swconfig)"
	echo
	echo "Variant of the MT5000 network configuration for the out-of-tree Realtek"
	echo "SDK driver (kmod-rtl8366ub): the switch is a plain swconfig switch with"
	echo "the ports 0 and 1 as LAN and the port 17 as the CPU port, exactly like"
	echo "in the GL.iNet stock firmware."
	echo
	diff -u --label "a/${NET}" --label "b/${NET}" "${WORK}/base/${NET}" "${WORK}/new/${NET}" || true
} > "${OUT}/0003s-mediatek-filogic-base-files-add-mt5000-network-swconfig.patch"

# ------------------------------------------------------ upgrade/platform.sh
UPG="target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
fetch "${UPSTREAM}/${UPG}" "${WORK}/base/${UPG}"
mkdir -p "${WORK}/new/$(dirname "${UPG}")"
cp "${WORK}/base/${UPG}" "${WORK}/new/${UPG}"
python3 - "${WORK}/new/${UPG}" <<'PY'
import sys
path = sys.argv[1]
txt = open(path).read()
# platform_do_upgrade() and platform_check_image(): the "filogic bootloader does
# the upgrade" lists
anchor1 = "\tglinet,gl-mt2500-airoha|\\\n\tglinet,gl-mt6000|\\\n"
assert anchor1 in txt, "anchor1 not found"
txt = txt.replace(anchor1, "\tglinet,gl-mt2500-airoha|\\\n\tglinet,gl-mt5000|\\\n\tglinet,gl-mt6000|\\\n", 1)
assert anchor1 in txt, "anchor2 not found"
txt = txt.replace(anchor1, "\tglinet,gl-mt2500-airoha|\\\n\tglinet,gl-mt5000|\\\n\tglinet,gl-mt6000|\\\n", 1)
open(path, "w").write(txt)
PY
{
	echo "Subject: [PATCH] mediatek: filogic: allow sysupgrade on GL-MT5000"
	echo
	echo "The MT5000 is upgraded by the bootloader, so the platform upgrade hooks"
	echo "have to accept the device."
	echo
	diff -u --label "a/${UPG}" --label "b/${UPG}" "${WORK}/base/${UPG}" "${WORK}/new/${UPG}" || true
} > "${OUT}/0004-mediatek-filogic-base-files-add-mt5000-upgrade.patch"

# ------------------------------------------------------ kernel config
KCFG="target/linux/mediatek/filogic/config-6.18"
fetch "${UPSTREAM}/${KCFG}" "${WORK}/base/${KCFG}"
mkdir -p "${WORK}/new/$(dirname "${KCFG}")"
cp "${WORK}/base/${KCFG}" "${WORK}/new/${KCFG}"
python3 - "${WORK}/new/${KCFG}" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().splitlines(True)
add = [
 "CONFIG_NET_DSA_REALTEK=y\n",
 "CONFIG_NET_DSA_REALTEK_MDIO=y\n",
 "CONFIG_NET_DSA_REALTEK_RTL8366UB=y\n",
]
if any("NET_DSA_REALTEK_RTL8366UB" in l for l in lines):
    sys.exit(0)
out = []
for l in lines:
    out.append(l)
    if l.startswith("CONFIG_NET_DSA_MT7530_MMIO="):
        out.extend(add)
open(path, "w").writelines(out)
PY
{
	echo "Subject: [PATCH] mediatek: filogic: enable the RTL8366UB DSA driver"
	echo
	echo "Enable the in-tree Realtek DSA switch driver family and the RTL8366UB"
	echo "variant used by the GL.iNet GL-MT5000."
	echo
	diff -u --label "a/${KCFG}" --label "b/${KCFG}" "${WORK}/base/${KCFG}" "${WORK}/new/${KCFG}" || true
} > "${OUT}/0005-mediatek-filogic-kconfig-enable-rtl8366ub.patch"

# --------------------------------------------- kernel pending patches (copies)
# These are not "applied" to the tree, they are *installed* into the kernel
# pending directory of the target (see patches/vanilla/series).
#
# The GL.iNet mt5000 branch mirrors the upstream PR #24237 revisions:
#   795-10-net-dsa-realtek-add-rtl8366ub.patch        - driver + 802.1Q tagger
#   795-11-net-mediatek-rtl8366ub-ppe-offload.patch   - mtk_eth_soc/PPE/flowtable
# The upstream 795-11 also contains the dummy NAPI hunks; they are stripped
# here and kept as the separately regeneratable patch 990-03
# (see tools/regen-kernel-patches.sh).
#
# Warning: GL.iNet's 795-11 predates the upstream 797-01/797-02 PPE rework
# that is already in main. Our shipped 990-02 is rebased onto main (it keeps
# the extra u16 *wcid parameter of mtk_flow_set_output_device and returns -1
# from the now integer nft_dev_path_info). After re-fetching 795-11 here,
# re-check with scripts/verify-kernel-patches.sh and rebase the hunks by
# hand if they no longer fit.
PENDING="target/linux/generic/pending-6.18"
mkdir -p "${OUT}/kernel"
fetch "${GLINET}/${PENDING}/795-10-net-dsa-realtek-add-rtl8366ub.patch" \
	"${OUT}/kernel/990-01-net-dsa-realtek-add-rtl8366ub.patch"
fetch "${GLINET}/${PENDING}/795-11-net-mediatek-rtl8366ub-ppe-offload.patch" \
	"${WORK}/795-11.raw"
python3 - "${WORK}/795-11.raw" "${OUT}/kernel/990-02-net-mediatek-rtl8366ub-ppe-offload.patch" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().split('\n')
out, i = [], 0
while i < len(lines) and not lines[i].startswith('--- a/'):
    out.append(lines[i]); i += 1
while i < len(lines):
    out.extend([lines[i], lines[i + 1]]); i += 2
    while i < len(lines) and not lines[i].startswith('--- a/'):
        if lines[i].startswith('@@'):
            h = [lines[i]]; i += 1
            while i < len(lines) and not lines[i].startswith('@@') and not lines[i].startswith('--- a/'):
                h.append(lines[i]); i += 1
            if any('dummy_dev' in l for l in h[1:]):
                continue          # the dummy NAPI move -> 990-03
            out.extend(h)
        else:
            out.append(lines[i]); i += 1
txt = '\n'.join(out)
txt = txt.replace(
    "Initialize the shared dummy NAPI device before publishing netdevs so\n"
    "a link-up racing with probe cannot enter mtk_open() too early.\n",
    "Note: the dummy NAPI initialization fix is not part of this patch here,\n"
    "it is shipped separately as 990-03 so that it can be regenerated when the\n"
    "kernel version of the branch moves.\n")
txt = txt.replace(
    "Apply after the RTL8366UB switch and tagger patch.",
    "Apply after the RTL8366UB switch and tagger patch (990-01).")
open(dst, 'w').write(txt)
PY
# 990-03 (dummy NAPI init fix) is not fetched anymore: upstream folded the
# hunks into 795-11. The file is maintained/regenerated by
# tools/regen-kernel-patches.sh.

rm -rf "${WORK}"
echo "patches regenerated in ${OUT}"
ls -1 "${OUT}" "${OUT}/kernel"
