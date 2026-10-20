#!/usr/bin/env bash
#
# extract-stock-defaults.sh - dump the runtime defaults of the GL.iNet stock
# firmware for the MT5000.
#
# The script downloads the official image, unpacks the squashfs rootfs and
# prints the files that define the defaults of the router:
#
#   /etc/board.d/*            (порты, hostname, LAN)
#   /etc/uci-defaults/*       (применяемые при первом запуске правки)
#   /etc/config/{dhcp,firewall,glconfig,gl_led,system}
#   /usr/lib/opkg/status      (список установленных пакетов)
#
# It is the reference used for config/runtime/ - the runtime configuration of
# this repository follows the values found here.
#
# Usage: tools/extract-stock-defaults.sh [--version 4.9.0] [--keep]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

VERSION="4.9.0"
KEEP=0
WORK="${BUILDER_ROOT}/.work/stock"

while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="$2"; shift 2 ;;
		--keep)    KEEP=1; shift ;;
		-h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

need_cmd curl tar unsquashfs python3

mkdir -p "${WORK}"

# --- find the image --------------------------------------------------------
log "querying the GL.iNet firmware API for mt5000 ${VERSION}"
URL="$(python3 - <<'PY'
import json, urllib.request, sys
version = sys.argv[1]
api = "https://firmware-api.gl-inet.com/cloud-api/model/info?model=mt5000&type=release"
data = json.load(urllib.request.urlopen(api))
for info in data.get("info", []):
    if info.get("version") == version:
        for d in info.get("download", []):
            print(d["link"])
        break
PY
"${VERSION}")"

[ -n "${URL}" ] || die "no firmware found for version ${VERSION}"
log "image: ${URL}"

# --- download ---------------------------------------------------------------
IMG="${WORK}/stock-${VERSION}.bin"
if [ ! -f "${IMG}" ]; then
	curl -fsSL -o "${IMG}" "${URL}"
fi

# --- unpack -----------------------------------------------------------------
log "unpacking the image"
rm -rf "${WORK}/unpack" "${WORK}/root"
mkdir -p "${WORK}/unpack"
tar xf "${IMG}" -C "${WORK}/unpack"
ROOT="$(find "${WORK}/unpack" -name root -type f | head -1)"
[ -n "${ROOT}" ] || die "rootfs not found in the image"
unsquashfs -n -d "${WORK}/root" "${ROOT}" >/dev/null

# --- dump -------------------------------------------------------------------
echo
echo "################ /etc/board.d/02_network (mt5000 part) ################"
grep -n -A8 "mt5000" "${WORK}/root/etc/board.d/02_network" || true

echo
echo "################ /etc/board.d/02_gl_system ################"
cat "${WORK}/root/etc/board.d/02_gl_system" 2>/dev/null || true

echo
echo "################ /etc/board.d/03_gl_network ################"
cat "${WORK}/root/etc/board.d/03_gl_network" 2>/dev/null || true

echo
echo "################ /etc/config/dhcp ################"
cat "${WORK}/root/etc/config/dhcp" 2>/dev/null || true

echo
echo "################ /etc/config/firewall (без комментариев) ################"
grep -vE "^\s*#" "${WORK}/root/etc/config/firewall" 2>/dev/null | sed '/^$/d' || true

echo
echo "################ /etc/config/glconfig, gl_led, board_special ################"
for f in glconfig gl_led board_special; do
	echo "--- ${f}"
	cat "${WORK}/root/etc/config/${f}" 2>/dev/null || true
done

echo
echo "################ /etc/uci-defaults ################"
ls "${WORK}/root/etc/uci-defaults" 2>/dev/null || true

echo
echo "################ список пакетов стоковой прошивки ################"
grep -E "^Package: " "${WORK}/root/usr/lib/opkg/status" 2>/dev/null | awk '{print $2}' | sort | tr '\n' ' '
echo

[ "${KEEP}" -eq 1 ] || rm -rf "${WORK}/unpack" "${WORK}/root"
log "done"
