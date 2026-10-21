#!/usr/bin/env bash
#
# build.sh - build an OpenWrt firmware for the GL.iNet GL-MT5000 (Brume 3).
#
#   --source upstream|glinet   upstream OpenWrt or the GL.iNet fork
#   --ref <branch|tag>         branch or tag of the source repository
#   --switch-driver dsa|swconfig
#                              dsa      : in-tree Realtek DSA driver (recommended)
#                              swconfig : out-of-tree Realtek SDK driver, the same
#                                         one the GL.iNet stock firmware uses
#   --profile minimal|full|custom
#   --flavour vanilla|glinet   which buildinfo/config set to use
#
# Usage: build.sh --workdir <dir> [options]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

WORKDIR=""
SOURCE="upstream"
REF="main"
FLAVOUR=""
PROFILE="full"
SWITCH_DRIVER="dsa"
JOBS="$(nproc 2>/dev/null || echo 4)"
EXTRA_FRAGMENTS=()
SKIP_DOWNLOAD=0
SKIP_BUILD=0
SKIP_VERIFY=0
STAMP=""
# in CI every patch has to apply, locally a failing patch is only a warning
STRICT="${STRICT_PATCHES:-}"
if [ -z "${STRICT}" ]; then
	if [ -n "${GITHUB_ACTIONS:-}" ]; then STRICT=1; else STRICT=0; fi
fi

while [ $# -gt 0 ]; do
	case "$1" in
		--workdir)        WORKDIR="$2"; shift 2 ;;
		--source)         SOURCE="$2"; shift 2 ;;
		--ref)            REF="$2"; shift 2 ;;
		--flavour)        FLAVOUR="$2"; shift 2 ;;
		--profile)        PROFILE="$2"; shift 2 ;;
		--switch-driver)  SWITCH_DRIVER="$2"; shift 2 ;;
		--jobs)           JOBS="$2"; shift 2 ;;
		--fragment)       EXTRA_FRAGMENTS+=("$2"); shift 2 ;;
		--skip-download)  SKIP_DOWNLOAD=1; shift ;;
		--skip-build)     SKIP_BUILD=1; shift ;;
		--skip-verify)    SKIP_VERIFY=1; shift ;;
		--stamp)          STAMP="$2"; shift 2 ;;
		--strict)         STRICT=1; shift ;;
		--no-strict)      STRICT=0; shift ;;
		-h|--help)        awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${WORKDIR}" ] || die "--workdir is required"
[ -n "${FLAVOUR}" ] || FLAVOUR="${SOURCE}"

TREE="${WORKDIR}/openwrt"
OUT="${WORKDIR}/out"
mkdir -p "${WORKDIR}" "${OUT}"

# ---------------------------------------------------------------------------
log "=== 1/6 fetching the source (${SOURCE} @ ${REF}) ==="
"${BUILDER_ROOT}/scripts/fetch-source.sh" --source "${SOURCE}" --ref "${REF}" --dest "${TREE}"

# ---------------------------------------------------------------------------
log "=== 2/6 applying the MT5000 patch series ==="
if [ "${SOURCE}" = "upstream" ]; then
	SERIES="${BUILDER_ROOT}/patches/vanilla/series"
else
	SERIES="${BUILDER_ROOT}/patches/glinet/series"
fi
"${BUILDER_ROOT}/scripts/apply-patches.sh" --tree "${TREE}" --series "${SERIES}" \
	--switch-driver "${SWITCH_DRIVER}" $([ "${STRICT}" = "1" ] && echo "--strict")

# ---------------------------------------------------------------------------
log "=== 3/6 installing the GL.iNet runtime configuration ==="
"${BUILDER_ROOT}/scripts/install-runtime.sh" --tree "${TREE}" --variant "${SWITCH_DRIVER}"

# ---------------------------------------------------------------------------
log "=== 4/6 updating the feeds ==="
cd "${TREE}"
./scripts/feeds update -a
./scripts/feeds install -a

# ---------------------------------------------------------------------------
log "=== 5/6 generating the configuration ==="
"${BUILDER_ROOT}/scripts/gen-config.sh" --tree "${TREE}" --flavour "${FLAVOUR}" \
	--profile "${PROFILE}" --switch-driver "${SWITCH_DRIVER}" \
	${EXTRA_FRAGMENTS+"--fragment" "${EXTRA_FRAGMENTS[@]}"}

# ---------------------------------------------------------------------------
log "=== 6/6 building ==="
if [ "${SKIP_DOWNLOAD}" -eq 0 ]; then
	make download -j"${JOBS}"

	# preflight: check that our kernel patches fit the kernel of this branch
	# (otherwise the build dies in the middle of the kernel build)
	if [ "${SKIP_VERIFY}" -eq 0 ]; then
		log "=== 6a/6 checking the kernel patches ==="
		"${BUILDER_ROOT}/scripts/verify-kernel-patches.sh" --tree "${TREE}" \
			--series "${SERIES}" --switch-driver "${SWITCH_DRIVER}" || \
			die "the kernel patches do not fit the kernel of this branch (see docs/BUILD.md)"
	fi
fi
if [ "${SKIP_BUILD}" -eq 0 ]; then
	make -j"${JOBS}" V=s
fi

# ---------------------------------------------------------------------------
log "collecting the artifacts"
if [ -n "${STAMP}" ] && ! valid_stamp "${STAMP}"; then
	warn "the build stamp '${STAMP}' is not a date (YYYYMMDD-HHMM) - using the current time"
	STAMP=""
fi
[ -n "${STAMP}" ] || STAMP="$(build_stamp)"
RELEASE_ID="$(release_id "${SOURCE}" "${REF}" "${SWITCH_DRIVER}" "${STAMP}")"
log "release id: ${RELEASE_ID}"

"${BUILDER_ROOT}/scripts/collect-artifacts.sh" --tree "${TREE}" --out "${OUT}" \
	--flavour "${FLAVOUR}" --switch-driver "${SWITCH_DRIVER}" \
	--source "${SOURCE}" --ref "${REF}" --stamp "${STAMP}" --release-id "${RELEASE_ID}"

log "build finished, artifacts are in ${OUT}"
exit 0
