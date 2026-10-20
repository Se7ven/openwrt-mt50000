#!/usr/bin/env bash
#
# verify-kernel-patches.sh - preflight check of the kernel patches.
#
# The kernel patches of the RTL8366UB switch driver are applied by the kernel
# build with "patch -p1" - if one of them does not fit the kernel of the
# branch, the build dies after a long time (toolchain/kernel-headers).
# This script reproduces the kernel patch environment of the build and checks
# our patches before the build starts:
#
#   1. take the kernel tarball from dl/ (it is downloaded by "make download")
#   2. apply the kernel patches of OpenWrt that touch the same files as our
#      patches (applying all of them would take ~1 hour)
#   3. apply our kernel patches one by one and report the first one that
#      does not fit
#
# Usage: verify-kernel-patches.sh --tree <openwrt-dir> [--series <series-file>]
#                                 [--switch-driver dsa|swconfig] [--keep]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
SERIES=""
SWITCH_DRIVER="dsa"
KEEP=0

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)          TREE="$2"; shift 2 ;;
		--series)        SERIES="$2"; shift 2 ;;
		--switch-driver) SWITCH_DRIVER="$2"; shift 2 ;;
		--keep)          KEEP=1; shift ;;
		-h|--help)       awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"
[ -d "${TREE}" ] || die "tree not found: ${TREE}"
if [ -z "${SERIES}" ]; then
	SERIES="${BUILDER_ROOT}/patches/vanilla/series"
fi

need_cmd patch tar python3

KERNEL_SERIES="$(kernel_series "${TREE}")"

# --- the version of the kernel ----------------------------------------------
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
[ -n "${KERNEL_VERSION}" ] || die "cannot determine the kernel version from ${KVER_FILE}"

# --- our kernel patches -----------------------------------------------------
LIST="$(mktemp)"
"${BUILDER_ROOT}/scripts/apply-patches.sh" --tree "${TREE}" --series "${SERIES}" \
	--switch-driver "${SWITCH_DRIVER}" --print-install-list "${LIST}" >/dev/null

cleanup() {
	rm -f "${LIST}"
	[ "${KEEP}" -eq 1 ] || rm -rf "${WORK}"
}
WORK="$(mktemp -d)"
trap cleanup EXIT

if [ ! -s "${LIST}" ]; then
	log "no kernel patches to check for this configuration"
	exit 0
fi

# --- the kernel tarball -----------------------------------------------------
TARBALL=""
for ext in tar.xz tar.gz tar.bz2 tar; do
	[ -f "${TREE}/dl/linux-${KERNEL_VERSION}.${ext}" ] && { TARBALL="${TREE}/dl/linux-${KERNEL_VERSION}.${ext}"; break; }
done
if [ -z "${TARBALL}" ]; then
	warn "the kernel tarball linux-${KERNEL_VERSION} is not in dl/ yet - run 'make download' first, skipping the check"
	exit 0
fi

log "checking the kernel patches against linux-${KERNEL_VERSION}"
tar xf "${TARBALL}" -C "${WORK}"
KDIR="$(find "${WORK}" -maxdepth 1 -type d -name "linux-*" | head -1)"
[ -n "${KDIR}" ] || die "cannot unpack the kernel tarball"

# --- the files our patches touch -------------------------------------------
FILES="$(cat "${LIST}" | xargs grep -hE '^\+\+\+ b/' 2>/dev/null | awk '{print $2}' | sed 's|^b/||' | sort -u)"
log "the patches touch: $(echo ${FILES} | tr '\n' ' ')"

# --- the kernel patches of OpenWrt that touch the same files ---------------
TARGET_BOARD="$(sed -n 's/^CONFIG_TARGET_\([a-z0-9_]*\)=y$/\1/p' "${TREE}/.config" 2>/dev/null | head -1 || true)"
TARGET_BOARD="${TARGET_BOARD%%_*}"
[ -n "${TARGET_BOARD}" ] || TARGET_BOARD="mediatek"

SELECTED="$(mktemp)"
for dir in \
	"${TREE}/target/linux/generic/backport-${KERNEL_SERIES}" \
	"${TREE}/target/linux/generic/pending-${KERNEL_SERIES}" \
	"${TREE}/target/linux/generic/hack-${KERNEL_SERIES}" \
	"${TREE}/target/linux/${TARGET_BOARD}/patches-${KERNEL_SERIES}"
do
	[ -d "${dir}" ] || continue
	for p in $(ls "${dir}"/*.patch 2>/dev/null | sort); do
		# skip our own patches, they are checked separately
		grep -qF "$(basename "${p}")" "${LIST}" && continue
		for f in ${FILES}; do
			if grep -qE "^\+\+\+ b/${f//./\\.}([[:space:]]|$)" "${p}" 2>/dev/null; then
				echo "${p}" >> "${SELECTED}"
				break
			fi
		done
	done
done

log "applying $(wc -l < "${SELECTED}" 2>/dev/null || echo 0) related OpenWrt kernel patch(es) (of $(ls "${TREE}/target/linux/generic/pending-${KERNEL_SERIES}"/*.patch 2>/dev/null | wc -l) in the pending directory)"
while read -r p; do
	[ -n "${p}" ] || continue
	patch -f -p1 --forward -d "${KDIR}" -s < "${p}" >/dev/null 2>&1 || true
done < "${SELECTED}"
rm -f "${SELECTED}"

# --- check our patches ------------------------------------------------------
RC=0
while read -r p; do
	[ -n "${p}" ] || continue
	name="$(basename "${p}")"
	if patch -f -p1 -d "${KDIR}" --dry-run < "${p}" > "${WORK}/out.log" 2>&1; then
		log "ok       ${name}"
		patch -f -p1 -d "${KDIR}" -s < "${p}" >/dev/null 2>&1 || true
	else
		err "FAILED   ${name}"
		grep -E "FAILED|Hunk" "${WORK}/out.log" | head -5 | sed 's/^/         /' >&2
		RC=1
		break
	fi
done < "${LIST}"

if [ "${RC}" -ne 0 ]; then
	err "the kernel patch does not fit linux-${KERNEL_VERSION}"
	err "regenerate it with tools/regen-kernel-patches.sh (see docs/BUILD.md)"
fi
exit "${RC}"
