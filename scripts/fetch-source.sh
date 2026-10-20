#!/usr/bin/env bash
#
# fetch-source.sh - get the OpenWrt source tree that has to be built.
#
#   upstream : https://github.com/openwrt/openwrt.git   (vanilla pipeline)
#   glinet   : https://github.com/GLiNet-Tech/openwrt.git (GL.iNet pipeline, branch mt5000)
#
# Usage: fetch-source.sh --source <upstream|glinet> --ref <branch|tag|sha> \
#                         --dest <dir> [--depth <n>]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

SOURCE="upstream"
REF="main"
DEST=""
DEPTH="1"

while [ $# -gt 0 ]; do
	case "$1" in
		--source) SOURCE="$2"; shift 2 ;;
		--ref)    REF="$2";    shift 2 ;;
		--dest)   DEST="$2";   shift 2 ;;
		--depth)  DEPTH="$2";  shift 2 ;;
		-h|--help) awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${DEST}" ] || die "--dest is required"

case "${SOURCE}" in
	upstream) REPO="https://github.com/openwrt/openwrt.git" ;;
	glinet)   REPO="https://github.com/GLiNet-Tech/openwrt.git" ;;
	*)        die "unknown source: ${SOURCE}" ;;
esac

need_cmd git

if [ -d "${DEST}/.git" ]; then
	log "reusing existing checkout in ${DEST}"
	git -C "${DEST}" fetch --tags --prune origin
else
	log "cloning ${REPO} (${REF}) into ${DEST}"
	mkdir -p "$(dirname "${DEST}")"
	git clone --depth "${DEPTH}" --branch "${REF}" "${REPO}" "${DEST}" || {
		# the ref may be a SHA or a tag that is not branch-like: clone without
		# --branch and check it out afterwards
		warn "clone with --branch ${REF} failed, falling back to a full clone"
		rm -rf "${DEST}"
		git clone --filter=blob:none "${REPO}" "${DEST}"
	}
fi

git -C "${DEST}" checkout --force "${REF}"
git -C "${DEST}" submodule update --init --recursive || warn "no submodules to update"

log "source: ${REPO} @ $(git -C "${DEST}" rev-parse --short HEAD) ($(git -C "${DEST}" describe --tags --always 2>/dev/null || echo 'no tag'))"
