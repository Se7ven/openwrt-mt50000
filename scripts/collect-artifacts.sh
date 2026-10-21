#!/usr/bin/env bash
#
# collect-artifacts.sh - collect the firmware images and the build information.
#
# The names of the files get the prefix <release id>, so it is always visible
# how the image was built:
#
#   mt5000-upstream-main-dsa-20261021-1432-openwrt-mediatek-filogic-...-sysupgrade.bin
#   mt5000-glinet-mt5000-swconfig-20261021-1432-openwrt-mediatek-filogic-...-sysupgrade.bin
#
# The same identifier is used as the tag of the GitHub release, the metadata
# is written to build-info.txt and release.json.
#
# Usage: collect-artifacts.sh --tree <openwrt-dir> --out <dir>
#                             [--flavour vanilla|glinet] [--switch-driver dsa|swconfig]
#                             [--source upstream|glinet] [--ref <branch|tag>]
#                             [--stamp <YYYYMMDD-HHMM>] [--release-id <id>]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
OUT=""
FLAVOUR="vanilla"
SWITCH_DRIVER="dsa"
SOURCE=""
REF=""
STAMP=""
RELEASE_ID=""

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)          TREE="$2"; shift 2 ;;
		--out)           OUT="$2"; shift 2 ;;
		--flavour)       FLAVOUR="$2"; shift 2 ;;
		--switch-driver) SWITCH_DRIVER="$2"; shift 2 ;;
		--source)        SOURCE="$2"; shift 2 ;;
		--ref)           REF="$2"; shift 2 ;;
		--stamp)         STAMP="$2"; shift 2 ;;
		--release-id)    RELEASE_ID="$2"; shift 2 ;;
		-h|--help)       awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"
[ -n "${OUT}" ]  || die "--out is required"
mkdir -p "${OUT}"

[ -n "${SOURCE}" ] || SOURCE="${FLAVOUR}"
[ -n "${REF}" ] || REF="$(git -C "${TREE}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
[ -n "${STAMP}" ] || STAMP="$(build_stamp)"
[ -n "${RELEASE_ID}" ] || RELEASE_ID="$(release_id "${SOURCE}" "${REF}" "${SWITCH_DRIVER}" "${STAMP}")"

log "release id: ${RELEASE_ID}"

# --- firmware images -------------------------------------------------------
log "collecting the firmware images"
IMAGES=()
while IFS= read -r -d '' f; do
	name="$(basename "${f}")"
	target="${OUT}/${RELEASE_ID}-${name}"
	cp -f "${f}" "${target}"
	IMAGES+=("${target}")
	log "  ${RELEASE_ID}-${name} ($(du -h "${target}" | cut -f1))"
done < <(find "${TREE}/bin/targets" -type f \
	\( -name '*gl-mt5000*' -o -name '*glinet_gl-mt5000*' \) \
	! -name '*.sha256sum' -print0 2>/dev/null)

if [ "${#IMAGES[@]}" -eq 0 ]; then
	warn "no MT5000 image was found - the build did not produce a firmware"
fi

# --- build information -----------------------------------------------------
REPO_URL="$(git -C "${TREE}" remote get-url origin 2>/dev/null | head -1 || echo unknown)"
COMMIT="$(git -C "${TREE}" rev-parse HEAD 2>/dev/null | head -1 || echo unknown)"
DESCRIBE="$(git -C "${TREE}" describe --tags --always 2>/dev/null | head -1 || echo unknown)"
KERNEL="$(kernel_series "${TREE}")"
BUILD_DATE="$(date -u -d "${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2}" +%Y-%m-%d 2>/dev/null || build_date)"
BUILD_TIME="${STAMP:9:2}:${STAMP:11:2}"

TITLE="GL-MT5000 firmware: ${SOURCE} @ ${REF}, ${SWITCH_DRIVER}, ${BUILD_DATE} ${BUILD_TIME} UTC"

cat > "${OUT}/build-info.txt" <<EOF
release id:     ${RELEASE_ID}
title:          ${TITLE}
source:         ${SOURCE}
ref:            ${REF}
commit:         ${COMMIT}
describe:       ${DESCRIBE}
repository:     ${REPO_URL}
switch driver:  ${SWITCH_DRIVER}
kernel:         ${KERNEL}
flavour:        ${FLAVOUR}
build date:     ${BUILD_DATE}
build time:     ${BUILD_DATE} ${BUILD_TIME} UTC
builder:        $(uname -a)
EOF

# --- the body of the release ------------------------------------------------
{
	echo "## ${TITLE}"
	echo
	echo "| Параметр | Значение |"
	echo "|---|---|"
	echo "| Источник | ${SOURCE} (\`${REPO_URL}\`) |"
	echo "| Ветка / тег | \`${REF}\` |"
	echo "| Коммит | \`${COMMIT}\` (${DESCRIBE}) |"
	echo "| Драйвер свитча RTL8366UB | **${SWITCH_DRIVER}** |"
	echo "| Ядро | ${KERNEL} |"
	echo "| Профиль | ${FLAVOUR} |"
	echo "| Дата сборки | ${BUILD_DATE} ${BUILD_TIME} UTC |"
	echo
	echo "Файлы образа имеют префикс \`${RELEASE_ID}-\`, он же является тегом релиза."
	echo
	echo "### Конфигурация сборки"
	echo
	echo '```'
	grep -E "^CONFIG_(TARGET|PACKAGE)" "${TREE}/.config" 2>/dev/null | head -40 || true
	echo '```'
} > "${OUT}/release.md"

# machine readable metadata (used by the GitHub Actions workflow)
cat > "${OUT}/release.json" <<EOF
{
  "tag": "${RELEASE_ID}",
  "name": "${TITLE}",
  "source": "${SOURCE}",
  "ref": "${REF}",
  "commit": "${COMMIT}",
  "switch_driver": "${SWITCH_DRIVER}",
  "kernel": "${KERNEL}",
  "flavour": "${FLAVOUR}",
  "date": "${BUILD_DATE}",
  "stamp": "${STAMP}"
}
EOF

# --- the configuration and the checksums ------------------------------------
if [ -f "${TREE}/.config" ]; then
	cp -f "${TREE}/.config" "${OUT}/${RELEASE_ID}.config"
fi
if [ -f "${TREE}/config.buildinfo" ]; then
	cp -f "${TREE}/config.buildinfo" "${OUT}/${RELEASE_ID}.config.buildinfo"
fi

( cd "${OUT}" && sha256sum ./* > SHA256SUMS 2>/dev/null || true )

log "artifacts in ${OUT}:"
ls -la "${OUT}"
exit 0
