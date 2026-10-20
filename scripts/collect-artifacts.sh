#!/usr/bin/env bash
#
# collect-artifacts.sh - collect the firmware images and the build information.
#
# Usage: collect-artifacts.sh --tree <openwrt-dir> --out <dir>
#                             [--flavour vanilla|glinet] [--switch-driver dsa|swconfig]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
OUT=""
FLAVOUR="vanilla"
SWITCH_DRIVER="dsa"

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)          TREE="$2"; shift 2 ;;
		--out)           OUT="$2"; shift 2 ;;
		--flavour)       FLAVOUR="$2"; shift 2 ;;
		--switch-driver) SWITCH_DRIVER="$2"; shift 2 ;;
		-h|--help)       awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"
[ -n "${OUT}" ]  || die "--out is required"
mkdir -p "${OUT}"

# --- firmware images -------------------------------------------------------
log "collecting the firmware images"
find "${TREE}/bin/targets" -type f \
	\( -name '*gl-mt5000*' -o -name '*glinet_gl-mt5000*' \) \
	! -name '*.sha256sum' -print0 2>/dev/null |
while IFS= read -r -d '' f; do
	cp -f "${f}" "${OUT}/"
	log "  $(basename "${f}") ($(du -h "${f}" | cut -f1))"
done

# --- build information -----------------------------------------------------
{
	echo "flavour:          ${FLAVOUR}"
	echo "switch driver:    ${SWITCH_DRIVER}"
	echo "source:           $(git -C "${TREE}" remote get-url origin 2>/dev/null || echo '?')"
	echo "commit:           $(git -C "${TREE}" rev-parse HEAD 2>/dev/null || echo '?')"
	echo "describe:         $(git -C "${TREE}" describe --tags --always 2>/dev/null || echo '?')"
	echo "kernel:           $(kernel_series "${TREE}")"
	echo "built:            $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${OUT}/build-info.txt"

if [ -f "${TREE}/.config" ]; then
	cp -f "${TREE}/.config" "${OUT}/config-${FLAVOUR}.config"
fi
if [ -f "${TREE}/config.buildinfo" ]; then
	cp -f "${TREE}/config.buildinfo" "${OUT}/config-${FLAVOUR}.config.buildinfo"
fi

( cd "${OUT}" && sha256sum ./* > SHA256SUMS 2>/dev/null || true )

log "artifacts in ${OUT}:"
ls -la "${OUT}"
exit 0
