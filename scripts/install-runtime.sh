#!/usr/bin/env bash
#
# install-runtime.sh - add the GL.iNet style runtime configuration to the tree.
#
# The runtime configuration cannot be shipped as plain /etc/config/* files: those
# files are owned by the dnsmasq/firewall4 packages and a second package with
# the same file would break the build. Instead everything is applied by a
# uci-defaults script, exactly the way GL.iNet does it in their stock firmware
# (/etc/uci-defaults/03_gl_network, 01_gl_system, ...).
#
# Usage: install-runtime.sh --tree <openwrt-dir> [--variant dsa|swconfig]
#                            [--runtime-dir <dir>]
#
set -euo pipefail
. "$(dirname "$0")/common.sh"

TREE=""
VARIANT="dsa"
RUNTIME_DIR=""

while [ $# -gt 0 ]; do
	case "$1" in
		--tree)        TREE="$2"; shift 2 ;;
		--variant)     VARIANT="$2"; shift 2 ;;
		--runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
		-h|--help)     awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

[ -n "${TREE}" ] || die "--tree is required"

if [ -z "${RUNTIME_DIR}" ]; then
	RUNTIME_DIR="${BUILDER_ROOT}/config/runtime/${VARIANT}"
fi
[ -d "${RUNTIME_DIR}" ] || die "runtime directory not found: ${RUNTIME_DIR}"

PKG_DIR="${TREE}/package/glinet-mt5000-defaults"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}/files"

log "installing runtime configuration (variant: ${VARIANT}) from ${RUNTIME_DIR}"
# the runtime directories contain a "files/" folder that becomes the root of the
# package (etc/... -> /etc/... in the image)
if [ -d "${RUNTIME_DIR}/files" ]; then
	cp -a "${RUNTIME_DIR}/files/." "${PKG_DIR}/files/"
else
	cp -a "${RUNTIME_DIR}/." "${PKG_DIR}/files/"
fi

# make sure the uci-defaults hooks are executable
find "${PKG_DIR}/files/etc/uci-defaults" -type f -exec chmod 0755 {} + 2>/dev/null || true

cat > "${PKG_DIR}/Makefile" <<'EOF'
#
# Runtime configuration of the GL.iNet GL-MT5000 (Brume 3).
#
# The files below are applied on the first boot by the uci-defaults hooks,
# they reproduce the defaults of the GL.iNet stock firmware (LAN 192.168.8.1,
# DHCP pool 192.168.8.100-249, hostname GL-MT5000, IPv6 disabled on WAN, ...).
#
include $(TOPDIR)/rules.mk

# OpenWrt 2026 (apk) requires the fields TITLE, CATEGORY, SECTION and VERSION.
# PKG_NAME and PKG_VERSION have to be set *before* package.mk is included:
# include/package.mk computes PKG_BUILD_DIR from them at include time.
PKG_NAME:=glinet-mt5000-defaults
PKG_VERSION:=1.0.0

include $(INCLUDE_DIR)/package.mk

define Package/glinet-mt5000-defaults
  SECTION:=base
  CATEGORY:=GL.iNet
  TITLE:=GL.iNet runtime defaults for GL-MT5000
  VERSION:=$(PKG_VERSION)
  DEPENDS:=+luci
  PKGARCH:=all
endef

define Package/glinet-mt5000-defaults/description
 Runtime configuration (network, DHCP, firewall, system) that follows the
 defaults of the GL.iNet stock firmware for the GL-MT5000.
endef

# the package has no sources, it only installs files - the same as
# package/base-files: create the build directory and skip the compile step
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Quilt
endef

define Build/Compile/Default

endef
Build/Compile = $(Build/Compile/Default)

define Package/glinet-mt5000-defaults/install
	$(INSTALL_DIR) $(1)/etc
	$(CP) ./files/. $(1)/
endef

$(eval $(call BuildPackage,glinet-mt5000-defaults))
EOF

log "runtime package created: ${PKG_DIR#"${TREE}"/}"

# sanity check: OpenWrt 2026 refuses to build a package without these fields
for field in TITLE CATEGORY SECTION VERSION; do
	grep -qE "^[[:space:]]*${field}:=" "${PKG_DIR}/Makefile" || \
		die "the package Makefile has no ${field} field (OpenWrt 2026 requires it)"
done

# PKG_NAME/PKG_VERSION have to be set before "include package.mk", otherwise
# PKG_BUILD_DIR stays empty and the package build fails with
# "No targets specified and no makefile found"
python3 - "${PKG_DIR}/Makefile" <<'PY' || die "the package Makefile has a wrong include order"
import re, sys
path = sys.argv[1]
txt = open(path).read()
name = re.search(r"^PKG_NAME:=", txt, re.M)
ver = re.search(r"^PKG_VERSION:=", txt, re.M)
inc = re.search(r"^include \$\(INCLUDE_DIR\)/package\.mk", txt, re.M)
if not (name and ver and inc):
    sys.exit(1)
if name.start() > inc.start() or ver.start() > inc.start():
    sys.exit(1)
PY

find "${PKG_DIR}/files" -type f | sed "s|${PKG_DIR}/|    |"
exit 0
