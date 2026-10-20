#!/usr/bin/env bash
#
# apply-patches.sh - apply the MT5000 patch series to an OpenWrt tree.
#
# The series is described by a manifest file (patches/<flavour>/series) with
# the following directives:
#
#   require-series <x.y>   the kernel series the following "pending" patches
#                          need; if the tree uses another series the pending
#                          patches are skipped (or the build fails in strict
#                          mode, because the switch would not work at all)
#   apply <file>           apply the patch to the tree root
#   pending <file>         install the patch into target/linux/generic/pending-*/
#
# Usage: apply-patches.sh --tree <openwrt-dir> --series <series-file>
#                         [--strict] [--switch-driver dsa|swconfig]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
SERIES=""
STRICT=0
SWITCH_DRIVER="dsa"

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)           TREE="$2"; shift 2 ;;
		--series)         SERIES="$2"; shift 2 ;;
		--strict)         STRICT=1; shift ;;
		--switch-driver)  SWITCH_DRIVER="$2"; shift 2 ;;
		-h|--help)        awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ]   || die "--tree is required"
[ -n "${SERIES}" ] || die "--series is required"
[ -d "${TREE}" ]   || die "tree not found: ${TREE}"

SERIES_DIR="$(cd "$(dirname "${SERIES}")" && pwd)"
TREE_SERIES="$(kernel_series "${TREE}")"
PENDING_DIR="$(pending_dir "${TREE}")"

log "tree kernel series: ${TREE_SERIES}"
log "kernel pending dir: ${PENDING_DIR:-<none>}"

need_cmd git patch

APPLIED=0
SKIPPED=0
FAILED=0

apply_one() {
	local patch_file="$1"
	local name; name="$(basename "${patch_file}")"

	if git -C "${TREE}" apply --check --whitespace=nowarn "${patch_file}" 2>/dev/null; then
		git -C "${TREE}" apply --whitespace=nowarn "${patch_file}"
		log "applied  ${name}"
		APPLIED=$((APPLIED + 1))
		return 0
	fi

	# git apply failed: try the 3-way merge, then a fuzzy patch(1) run
	if git -C "${TREE}" apply -3 --whitespace=nowarn "${patch_file}" 2>/dev/null; then
		log "applied (3-way) ${name}"
		APPLIED=$((APPLIED + 1))
		return 0
	fi

	if patch -p1 -d "${TREE}" --forward --fuzz=3 --no-backup-if-mismatch \
		< "${patch_file}" >/dev/null 2>&1; then
		log "applied (fuzzy) ${name}"
		APPLIED=$((APPLIED + 1))
		return 0
	fi

	warn "FAILED   ${name}"
	FAILED=$((FAILED + 1))
	if [ "${STRICT}" -eq 1 ]; then
		die "patch ${name} does not apply to the tree (strict mode)"
	fi
	return 1
}

install_pending() {
	local patch_file="$1"
	local name; name="$(basename "${patch_file}")"

	if [ -z "${PENDING_DIR}" ]; then
		warn "no kernel pending directory found, skipping ${name}"
		SKIPPED=$((SKIPPED + 1))
		return 0
	fi

	install -D -m 0644 "${patch_file}" "${PENDING_DIR}/${name}"
	log "installed ${name} -> ${PENDING_DIR#"${TREE}"/}"
	APPLIED=$((APPLIED + 1))
}

REQUIRED_SERIES=""
while IFS= read -r line || [ -n "${line}" ]; do
	# strip comments and split the line into fields
	line="${line%%#*}"
	line="$(echo "${line}" | tr -s ' \t' ' ')"
	[ -z "${line}" ] && continue

	# shellcheck disable=SC2086
	set -- ${line}
	directive="$1"; arg1="${2:-}"; arg2="${3:-}"

	# optional condition: "driver=dsa" / "driver=swconfig"
	case "${arg2}" in
		driver=*)
			want="${arg2#driver=}"
			if [ "${want}" != "${SWITCH_DRIVER}" ]; then
				warn "skipped ${arg1} (only for driver=${want}, current: ${SWITCH_DRIVER})"
				SKIPPED=$((SKIPPED + 1))
				continue
			fi
			;;
	esac

	case "${directive}" in
		require-series)
			REQUIRED_SERIES="${arg1}"
			if [ "${TREE_SERIES}" != "${REQUIRED_SERIES}" ]; then
				warn "tree uses kernel ${TREE_SERIES}, but the RTL8366UB kernel patches need ${REQUIRED_SERIES}"
				if [ "${STRICT}" -eq 1 ]; then
					die "kernel series mismatch (strict mode) - use a ${REQUIRED_SERIES} based branch (e.g. 'main') or switch to --switch-driver swconfig"
				fi
			fi
			;;
		apply)
			apply_one "${SERIES_DIR}/${arg1}" || true
			;;
		pending)
			if [ "${REQUIRED_SERIES}" = "${TREE_SERIES}" ] || [ -z "${REQUIRED_SERIES}" ]; then
				install_pending "${SERIES_DIR}/${arg1}"
			else
				warn "skipped kernel patch $(basename "${arg1}") (wrong kernel series)"
				SKIPPED=$((SKIPPED + 1))
			fi
			;;
		*)
			die "unknown directive in series file: ${directive}"
			;;
	esac
done < "${SERIES}"

# ---------------------------------------------------------------------------
# switch driver flavour
#
#   dsa      : the RTL8366UB is driven by the in-tree Realtek DSA driver
#              (patch series 940-01/940-02) - this is the default and the mode
#              used by the GL.iNet "mt5000" branch.
#   swconfig : the RTL8366UB is driven by the out-of-tree Realtek SDK driver
#              (kmod-rtl8366ub, same driver as in the GL.iNet stock firmware).
#              The driver source is pulled from https://github.com/gl-inet/gl-rtl8366ub
# ---------------------------------------------------------------------------
if [ "${SWITCH_DRIVER}" = "swconfig" ]; then
	log "installing the out-of-tree RTL8366UB driver (swconfig flavour)"
	rm -rf "${TREE}/package/kernel/rtl8366ub"
	mkdir -p "${TREE}/package/kernel/rtl8366ub"
	git clone --depth 1 https://github.com/gl-inet/gl-rtl8366ub.git \
		"${TREE}/package/kernel/rtl8366ub"
	# the upstream package installs a diagnostic script that is not part of the
	# repository - drop that line so the package can be built
	chmod -R u+w "${TREE}/package/kernel/rtl8366ub"
	sed -i '/rtl8366ub-diag\.sh/d' "${TREE}/package/kernel/rtl8366ub/Makefile"
	# the stock driver is built for the mediatek target only
	sed -i 's/@TARGET_mediatek/@TARGET_mediatek_filogic/' \
		"${TREE}/package/kernel/rtl8366ub/Makefile"
	log "out-of-tree driver installed"
fi

log "patch summary: applied=${APPLIED} skipped=${SKIPPED} failed=${FAILED}"
[ "${FAILED}" -eq 0 ] || { [ "${STRICT}" -eq 1 ] && die "${FAILED} patch(es) failed"; }
exit 0
