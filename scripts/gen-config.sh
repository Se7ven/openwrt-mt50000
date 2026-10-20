#!/usr/bin/env bash
#
# gen-config.sh - generate the OpenWrt .config for the GL-MT5000.
#
# The configuration is built in three layers:
#
#   1. config/buildinfo/<flavour>.config.buildinfo
#        the mandatory part: target, subtarget, device, rootfs and the packages
#        that are needed for a working router (switch, firewall, DNS, ...).
#   2. config/fragments/*.config
#        optional feature sets (USB storage, VPN, LuCI applications, ...).
#        They are merged on top of layer 1 in alphabetical order.
#   3. runtime additions
#        things that depend on the selected switch driver, e.g. the package
#        with the GL.iNet style runtime configuration.
#
# The fragments are merged with scripts/merge-config.py (upstream removed the
# "diffconfig.sh -m" mode in 2026) and are resolved by "make defconfig".
#
# The Kconfig symbol of the device is *detected* in the tree (upstream changed
# the naming of the device symbols in 2026: besides
# TARGET_<board>_<subtarget>_DEVICE_<device> there is now also
# TARGET_DEVICE_<board>_<subtarget>_DEVICE_<device> for multi device builds),
# so the same configuration works with old and new OpenWrt branches.
#
# Usage: gen-config.sh --tree <openwrt-dir> --flavour <vanilla|glinet>
#                       [--profile minimal|full|custom] [--fragment <file>]...
#                       [--switch-driver dsa|swconfig]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
FLAVOUR="vanilla"
PROFILE="full"
SWITCH_DRIVER="dsa"
DEVICE_ID="glinet_gl-mt5000"
EXTRA_FRAGMENTS=()

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)           TREE="$2"; shift 2 ;;
		--flavour)        FLAVOUR="$2"; shift 2 ;;
		--profile)        PROFILE="$2"; shift 2 ;;
		--fragment)       EXTRA_FRAGMENTS+=("$2"); shift 2 ;;
		--switch-driver)  SWITCH_DRIVER="$2"; shift 2 ;;
		--device)         DEVICE_ID="$2"; shift 2 ;;
		-h|--help)        awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"

BUILDINFO="${BUILDER_ROOT}/config/buildinfo/${FLAVOUR}.config.buildinfo"
[ -f "${BUILDINFO}" ] || die "buildinfo not found: ${BUILDINFO}"

cd "${TREE}"
need_cmd make python3

log "generating .config (flavour=${FLAVOUR}, profile=${PROFILE}, switch=${SWITCH_DRIVER})"

# 1. base configuration ---------------------------------------------------
log "make defconfig (base)"
make defconfig >/dev/null

# ---------------------------------------------------------------------------
# detect the Kconfig symbols of the device in this tree
#
#   OpenWrt <= 25.12 : config TARGET_mediatek_filogic_DEVICE_glinet_gl-mt5000
#   OpenWrt 2026     : config TARGET_mediatek_filogic_DEVICE_glinet_gl-mt5000
#                      menuconfig TARGET_DEVICE_mediatek_filogic_DEVICE_glinet_gl-mt5000
# ---------------------------------------------------------------------------
detect_device_symbols() {
	local f sym
	local found=""
	for f in \
		"${TREE}"/tmp/.config-target.in \
		"${TREE}"/tmp/.config-target.in.* \
		"${TREE}"/tmp/.config-target \
		"${TREE}"/target/linux/mediatek/Config.in \
		"${TREE}"/Config.in
	do
		[ -f "${f}" ] || continue
		# only the "config" symbol is the member of the "Target Profile"
		# choice, the "menuconfig TARGET_DEVICE_..." one belongs to the
		# multi device menu and needs TARGET_MULTI_PROFILE
		while read -r sym; do
			[ -n "${sym}" ] || continue
			case " ${found} " in
				*" ${sym} "*) continue ;;
			esac
			found="${found} ${sym}"
		done <<< "$(grep -oE "^config [A-Za-z0-9_]*${DEVICE_ID}\$" "${f}" 2>/dev/null | awk '{print $2}')"
	done
	echo "${found}"
}

DEVICE_SYMBOLS="$(detect_device_symbols)"
if [ -z "${DEVICE_SYMBOLS}" ]; then
	die "the device ${DEVICE_ID} is unknown to this tree - the image definition is missing (check the patch series)"
fi
log "device symbols: ${DEVICE_SYMBOLS}"

MERGE_LIST=()

# the mandatory part
MERGE_LIST+=("${BUILDINFO}")

# 2. feature fragments ----------------------------------------------------
if [ "${PROFILE}" = "full" ]; then
	for f in "${BUILDER_ROOT}"/config/fragments/*.config; do
		[ -f "${f}" ] || continue
		MERGE_LIST+=("${f}")
	done
elif [ "${PROFILE}" = "custom" ]; then
	for f in ${EXTRA_FRAGMENTS+"${EXTRA_FRAGMENTS[@]}"}; do
		MERGE_LIST+=("$f")
	done
elif [ "${PROFILE}" != "minimal" ]; then
	die "unknown profile: ${PROFILE}"
fi

for f in ${EXTRA_FRAGMENTS+"${EXTRA_FRAGMENTS[@]}"}; do
	case "${f}" in
		/*) : ;;
		*) f="${BUILDER_ROOT}/config/fragments/${f}" ;;
	esac
	[ -f "${f}" ] && MERGE_LIST+=("${f}")
done

# 3. the device itself ----------------------------------------------------
DEVICE_FRAGMENT="$(mktemp)"
{
	for sym in ${DEVICE_SYMBOLS}; do
		echo "CONFIG_${sym}=y"
	done
	# never build all devices of the subtarget
	echo "# CONFIG_TARGET_MULTI_PROFILE is not set"
	# the string that names the selected profile (OpenWrt 2026)
	if grep -qs "^config TARGET_PROFILE" "${TREE}/tmp/.config-target.in" 2>/dev/null; then
		echo "CONFIG_TARGET_PROFILE=\"DEVICE_${DEVICE_ID}\""
	fi
} > "${DEVICE_FRAGMENT}"
MERGE_LIST+=("${DEVICE_FRAGMENT}")

# 4. runtime additions ----------------------------------------------------
RUNTIME_FRAGMENT="$(mktemp)"
{
	echo "CONFIG_PACKAGE_glinet-mt5000-defaults=y"
	if [ "${SWITCH_DRIVER}" = "swconfig" ]; then
		echo "CONFIG_PACKAGE_kmod-rtl8366ub=y"
		echo "CONFIG_PACKAGE_kmod-swconfig=y"
		echo "CONFIG_PACKAGE_swconfig=y"
	fi
} > "${RUNTIME_FRAGMENT}"
MERGE_LIST+=("${RUNTIME_FRAGMENT}")

trap 'rm -f "${DEVICE_FRAGMENT}" "${RUNTIME_FRAGMENT}"' EXIT

# --- merge ----------------------------------------------------------------
log "merging ${#MERGE_LIST[@]} config file(s)"
MERGE_ARGS=()
for f in "${MERGE_LIST[@]}"; do
	[ -f "${f}" ] || die "config file not found: ${f}"
	log "  + $(basename "${f}")"
	MERGE_ARGS+=("--merge" "${f}")
done

# the Kconfig file is needed to detect the members of the target/profile
# choices: the target, the subtarget and the device are members of a choice,
# so the previously selected member has to be unset explicitly
KCONFIG_FILE=""
for f in "${TREE}/tmp/.config-target.in" "${TREE}/tmp/.config-target.in."*; do
	[ -f "${f}" ] && { KCONFIG_FILE="${f}"; break; }
done
[ -n "${KCONFIG_FILE}" ] || warn "no generated Kconfig found, the choice members may not be unset"
[ -n "${KCONFIG_FILE}" ] && MERGE_ARGS+=("--kconfig" "${KCONFIG_FILE}")

python3 "${BUILDER_ROOT}/scripts/merge-config.py" --config .config "${MERGE_ARGS[@]}"

# resolve the dependencies of the merged configuration
log "make defconfig (final)"
make defconfig >/dev/null

# save the resulting configuration
cp -f .config "${TREE}/.config.used"
{
	echo "# configuration used for the build"
	echo "# generated by scripts/gen-config.sh (flavour=${FLAVOUR}, profile=${PROFILE}, switch=${SWITCH_DRIVER})"
	grep -E "^CONFIG_(TARGET|PACKAGE|ALL)" .config || true
} > "${TREE}/config.buildinfo"

# sanity check -------------------------------------------------------------
SELECTED=""
for sym in ${DEVICE_SYMBOLS}; do
	grep -q "^CONFIG_${sym}=y" .config && SELECTED="${sym}"
done
if [ -z "${SELECTED}" ]; then
	err "the MT5000 device is not selected in .config"
	err "known device symbols: ${DEVICE_SYMBOLS}"
	err "current target selection:"
	grep -E "^CONFIG_TARGET" .config | sed 's/^/    /' >&2
	die "check the image patch and the buildinfo"
fi
log "device selected: ${SELECTED}"

log "configuration generated:"
grep -E "^CONFIG_TARGET_mediatek|^CONFIG_TARGET_ROOTFS|^CONFIG_PACKAGE_(kmod-rtl8366ub|glinet-mt5000)" .config | sed 's/^/    /'
exit 0
