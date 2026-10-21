#!/usr/bin/env bash
# common.sh - shared helpers for the GL-MT5000 build scripts.
# Sourced by every other script, do not run it directly.

set -euo pipefail

BUILDER_ROOT="${BUILDER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export BUILDER_ROOT

# --------------------------------------------------------------- logging ----
log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

# --------------------------------------------------------------- helpers ----
# run <cmd...> - run a command and abort the whole build on failure
run() {
	log "$*"
	"$@"
}

# need_cmd <cmd...> - verify that all commands exist
need_cmd() {
	local c
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
	done
}

# kernel_series <openwrt-dir> - print the kernel series of the tree, e.g. "6.18"
kernel_series() {
	local tree="$1"
	local d
	# the kernel series is the version of the "include/kernel-<series>" file
	for d in "${tree}"/include/kernel-*; do
		[ -d "$d" ] || continue
		basename "$d" | sed 's/^kernel-//'
		return 0
	done
	# some trees keep the kernel configuration in the generic target
	for d in "${tree}"/target/linux/generic/kernel-*; do
		[ -d "$d" ] || continue
		basename "$d" | sed 's/^kernel-//'
		return 0
	done
	# fallback: the "pending-<series>" directory of the generic target
	for d in "${tree}"/target/linux/generic/pending-*; do
		[ -d "$d" ] || continue
		basename "$d" | sed 's/^pending-//'
		return 0
	done
	echo "unknown"
}

# pending_dir <openwrt-dir> - print the kernel pending patch directory of the tree
pending_dir() {
	local tree="$1" d
	for d in "${tree}"/target/linux/generic/pending-*; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo ""
}

# target_patch_dir <openwrt-dir> - print the "patches-<series>" dir of the mediatek target
target_patch_dir() {
	local tree="$1" d
	for d in "${tree}"/target/linux/mediatek/patches-*; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo ""
}

# file_sha256 <file>
file_sha256() {
	sha256sum "$1" | cut -d' ' -f1
}

# --------------------------------------------------------------- releases ---
# sanitize_ref <ref> - make a git ref safe for a file or tag name
sanitize_ref() {
	echo "$1" | sed 's|[^A-Za-z0-9._-]|_|g; s|__*|_|g; s|^_||; s|_$||'
}

# build_stamp - the build date/time (UTC), e.g. "20261021-1432"
build_stamp() {
	date -u +%Y%m%d-%H%M
}

# valid_stamp <stamp> - check the format YYYYMMDD-HHMM
#
# It protects against a stamp that was not evaluated by the shell (e.g. the
# literal "$(date ...)" from a YAML environment variable).
valid_stamp() {
	echo "$1" | grep -qE '^[0-9]{8}-[0-9]{4}$'
}

# build_date - the build date (UTC), e.g. "2026-10-21"
build_date() {
	date -u +%Y-%m-%d
}

# release_id <source> <ref> <driver> <stamp> - the identifier of a build
#
# It is used as the release tag and as the prefix of the file names, so it
# always shows how the image was built:
#
#   mt5000-upstream-main-dsa-20261021-1432
#   mt5000-glinet-mt5000-swconfig-20261021-1432
release_id() {
	printf 'mt5000-%s-%s-%s-%s' \
		"${1:-unknown}" \
		"$(sanitize_ref "${2:-unknown}")" \
		"${3:-unknown}" \
		"${4:-$(build_stamp)}"
}
