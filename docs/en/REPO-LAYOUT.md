[**Русский**](../REPO-LAYOUT.md) · **English**

# Repository map: what lives where

Below is the full list of repository files with their purpose. Paths are relative to the
repository root.

---

## 1. GitHub Actions — `.github/workflows/`

### `build-vanilla.yml` — pipeline 1 (vanilla OpenWrt)

Builds the firmware from the **pure upstream** `https://github.com/openwrt/openwrt`.

Input parameters (`workflow_dispatch`):

| Parameter | Default | Purpose |
|---|---|---|
| `ref` | `main` | OpenWrt branch or tag (`main`, `openwrt-25.12`, `v24.10.5`, any SHA) |
| `switch_driver` | `dsa` | `dsa` — in-tree RTL8366UB driver; `swconfig` — out-of-tree Realtek driver |
| `profile` | `full` | `full` — all fragments from `config/fragments/`; `minimal` — target only |
| `jobs` | `8` | number of parallel build jobs |
| `strict_patches` | `true` | fail the build if any patch does not apply |

Triggers: manual run, `push` to `main` (on changes in `patches/`, `config/`, `scripts/`), daily `schedule`.

Steps: install dependencies → free up disk → cache `dl/` and ccache → `scripts/build.sh --source upstream` → collect artifacts → `actions/upload-artifact`.

### `build-glinet.yml` — pipeline 2 (GL.iNet)

Builds the firmware from the **GL.iNet fork** `https://github.com/GLiNet-Tech/openwrt`,
branch `mt5000`. The input parameter set is the same, except `ref` defaults to `mt5000`.

Difference from vanilla: the MT5000 support patches are not applied (they are already in
the branch), only the GL.iNet runtime configuration is added.

---

## 2. Build scripts — `scripts/`

| File | Purpose |
|---|---|
| `common.sh` | shared functions: logging, detecting the tree's kernel version (`kernel_series`), locating the kernel-patch directory (`pending_dir`), small utilities. Sourced (`.`) by all other scripts. |
| `fetch-source.sh` | source cloning: `--source upstream|glinet`, `--ref <branch|tag|sha>`, `--dest <dir>`. On re-runs it reuses the existing checkout and does a `git fetch`. |
| `apply-patches.sh` | applies the patch series from `patches/<flavour>/series`. Directives: `require-series`, `apply`, `pending`. There is a `git apply` → `git apply -3` → `patch -p1 --fuzz=3` cascade. `--strict`/`--no-strict` modes. Additionally installs the out-of-tree driver `package/kernel/rtl8366ub` when `--switch-driver swconfig` is used. |
| `install-runtime.sh` | creates the `package/glinet-mt5000-defaults` package in the tree from the files in `config/runtime/<variant>/`. The `uci-defaults` and `init.d` files become part of the image. The package must have `TITLE`, `CATEGORY`, `SECTION` and `VERSION` fields (without `VERSION` the `apk`-based build (OpenWrt 2026) fails), `PKG_NAME`/`PKG_VERSION` must be set **before** `include $(INCLUDE_DIR)/package.mk` (otherwise `PKG_BUILD_DIR` is empty), and a package without sources needs an empty `Build/Compile` and `Build/Prepare` — like `package/base-files`. |
| `gen-config.sh` | generates `.config`: `make defconfig` → merge `config/buildinfo/<flavour>.config.buildinfo` → merge the `config/fragments/*.config` fragments → merge runtime additions (the `glinet-mt5000-defaults` package, `kmod-rtl8366ub` for swconfig) → final `make defconfig`. |
| `merge-config.py` | merges configuration fragments into `.config` (upstream removed the `diffconfig.sh -m` mode in 2026, so the merger is our own). It can parse `tmp/.config-target.in` and deselect the other members of the Kconfig `choice` (target/subtarget/device) — without that `make defconfig` keeps the old profile and silently drops the new one. |
| `verify-kernel-patches.sh` | preflight check of the kernel patches: unpacks the kernel, applies the OpenWrt patches that touch our files and checks our patches — otherwise the build dies an hour in, in `toolchain/kernel-headers`. |
| `build.sh` | the main orchestrator: fetch → patches → runtime → feeds → config → `make download` → `make` → collect. |
| `collect-artifacts.sh` | copies the finished images (`*gl-mt5000*`), `.config`, `config.buildinfo` into the output directory + `SHA256SUMS` + `build-info.txt`. Files get the `<release id>` prefix = `mt5000-<source>-<branch/tag>-<driver>-<UTC date-time>`, which is also used as the GitHub release tag. `release.md` (release description) and `release.json` (tag/name/parameters — used by the workflow) are placed alongside. |

All scripts are POSIX/bash, run from the repository root; the repository path is determined automatically (`BUILDER_ROOT`).

---

## 3. Patches — `patches/`

### `patches/vanilla/series`

The series manifest (format: `<directive> <argument>`):

```
require-series 6.18      # kernel version required by the following kernel patches
apply   0001-...patch     # patch is applied to the OpenWrt tree
pending kernel/940-...    # patch is copied into target/linux/generic/pending-<version>/
```

Entry conditions (after the file name):

| Condition | Meaning |
|---|---|
| `driver=dsa` / `driver=swconfig` | the entry is used only with this switch driver |
| `series=6.18` | the entry is used only with this kernel |
| `optional` | the entry is skipped with a warning if it does not fit the tree |

The kernel-version check is performed **only for entries that are actually installed**:
in `swconfig` mode the DSA patches are dropped by the `driver=` condition, and the
"kernel 6.18" requirement is not checked — that is why branches with an older kernel
(25.12 etc.) still build.

### `patches/vanilla/*.patch` (applied to the tree)

| File | What it does | Source |
|---|---|---|
| `0001-mediatek-dts-add-mt7987a-glinet-gl-mt5000.patch` | adds `target/linux/mediatek/dts/mt7987a-glinet-gl-mt5000.dts` | GL.iNet `mt5000` branch |
| `0002-mediatek-image-add-glinet-gl-mt5000.patch` | adds the `Device/glinet_gl-mt5000` image definition to `target/linux/mediatek/image/filogic.mk` | GL.iNet `mt5000` branch |
| `0003-mediatek-filogic-base-files-add-mt5000-network.patch` | `board.d/02_network` (DSA): LAN = `lan1 lan2` (DSA switch ports), WAN = `eth1` | GL.iNet `mt5000` branch |
| `0003s-mediatek-filogic-base-files-add-mt5000-network-swconfig.patch` | `board.d/02_network` (swconfig): LAN = `eth0.1`, switch `switch0` with ports `0:lan`, `1:lan`, `17@eth0` — same as stock GL.iNet | stock GL.iNet 4.9.0 firmware |
| `0004-mediatek-filogic-base-files-add-mt5000-upgrade.patch` | `upgrade/platform.sh`: allows sysupgrade on MT5000 | GL.iNet `mt5000` branch |
| `0005-mediatek-filogic-kconfig-enable-rtl8366ub.patch` | `target/linux/mediatek/filogic/config-6.18`: `CONFIG_NET_DSA_REALTEK{,_MDIO,_RTL8366UB}=y` | GL.iNet `mt5000` branch |

### `patches/vanilla/kernel/*.patch` (kernel patches, installed into `pending-<version>/`)

| File | What it does | GL.iNet original |
|---|---|---|
| `990-01-net-dsa-realtek-add-rtl8366ub.patch` | **in-tree RTL8366UB DSA driver + 802.1Q tagger** (`drivers/net/dsa/realtek/rtl8366ub_*`, `net/dsa/tag_rtl8366ub_8021q.c`, Kconfig `NET_DSA_REALTEK_RTL8366UB`, `NET_DSA_TAG_RTL8366UB_8021Q`) | `795-10-net-dsa-realtek-add-rtl8366ub.patch` |
| `990-02-net-mediatek-rtl8366ub-ppe-offload.patch` | tagger integration with `mtk_eth_soc`/`mtk_ppe_offload`/flowtable (without it the PPE cannot see the EtherType and WAN→LAN offload does not work); hunks rebased onto the current main (the PPE rework `795-01..795-09`/`797-01`/`797-02`, the `num_tags` check and `967-4x`/YT922X, and the integer return of `nft_dev_path_info` are taken into account) | `795-11-net-mediatek-rtl8366ub-ppe-offload.patch` |

The numbers were renamed from `795-xx` to `990-xx` so that the patches apply **after**
all regular OpenWrt patches (`pending-6.18`'s highest number is 936, `backport-6.18`'s — 942).

The kernel-patch context depends on the kernel version: `990-01`/`990-02` were
regenerated for linux 6.18.60 with the kernel patches of `openwrt/openwrt@main`.
Previously a separate `990-03` carried the dummy-NAPI race fix from `795-11`; that fix
is now in kernel 6.18.60 itself, so the patch was removed. When the kernel is updated,
use `tools/regen-kernel-patches.sh`, and before building run
`scripts/verify-kernel-patches.sh` (preflight check).

### `patches/glinet/series`

An empty manifest: the GL.iNet `mt5000` branch already contains the DTS, image,
board scripts and kernel patches. A place for local tweaks.

### `tools/regen-patches.sh`

Rebuilds the whole `patches/vanilla/` series from two sources:
`openwrt/openwrt@main` (base) and `GLiNet-Tech/openwrt@mt5000` (changes).
Used when upstream moved on and the patch context shifted.

### `tools/regen-kernel-patches.sh`

Regenerates the `990-03` kernel patch for the branch's current kernel version:
unpacks the kernel, applies the OpenWrt kernel patches and our `990-01`/`990-02`,
and then generates the patch from scratch. If the fix has already been merged into the
upstream kernel (as in 6.18.60), the script deletes the local `990-03`. Run manually
when the branch's kernel is updated.

### `tools/extract-stock-defaults.sh`

Downloads the stock GL.iNet firmware for MT5000, unpacks the squashfs and prints
`/etc/board.d/*`, `/etc/uci-defaults/*`, `/etc/config/{dhcp,firewall}` and the package
list — the reference for `config/runtime/`.

---

## 4. Build configuration — `config/`

### `config/buildinfo/*.config.buildinfo`

The mandatory part of the configuration in `diffconfig` syntax. Contains the target,
device, rootfs and the packages without which the router does not work.

* `vanilla.config.buildinfo` — for builds from upstream.
* `glinet.config.buildinfo` — for builds from the GL.iNet branch (differences are marked with comments).

### `config/fragments/*.config`

Optional sets, layered on top of the buildinfo (alphabetical order):

| File | Contents |
|---|---|
| `00-target.config` | target/subtarget/device, rootfs type and its size |
| `10-network.config` | dnsmasq/firewall4, tools, MediaTek offload (PPE/HNAT) |
| `20-storage.config` | USB 3.0, file systems (ext4/vfat/f2fs/ntfs/exfat), mount-utils |
| `30-vpn.config` | OpenVPN, WireGuard, Tailscale, ZeroTier + their LuCI protocols |
| `40-luci.config` | LuCI and modules (including the Russian language) |
| `50-services.config` | chrony, AdGuardHome, SmartDNS, mwan3, SQM, utilities |

### `config/runtime/<variant>/`

The runtime configuration installed into the image by the `glinet-mt5000-defaults` package.

```
config/runtime/dsa/files/etc/
├── init.d/gl-mt5000-led            # white "system" LED turned on at boot
└── uci-defaults/99_gl-mt5000-defaults   # IP, DHCP, hostname, IPv6, firewall, console.gl-inet.com
config/runtime/swconfig/files/etc/
├── init.d/gl-mt5000-led
└── uci-defaults/99_gl-mt5000-defaults
```

In `swconfig` mode the switch layout is set not by this package but by
`board.d/02_network` (patch `0003s-...-swconfig.patch`) — exactly as in the stock
GL.iNet firmware.

Important: `/etc/config/*` are **not** overridden by the package (otherwise there are
conflicts with `dnsmasq`/`firewall4`); everything is applied via `uci-defaults` —
exactly the way the stock GL.iNet firmware does it.

---

## 5. Documentation — `docs/`

| File | Contents |
|---|---|
| `REPO-LAYOUT.md` | Russian version of this file |
| `BUILD.md` | Russian: local build, cache and ccache, adding features, debugging |
| `FLASHING.md` | Russian: flashing via the web UI and UART, stock firmware recovery |
| `GLINET-DEFAULTS.md` | Russian: correspondence table of GL.iNet (4.9.0) defaults and our configuration |
| `en/REPO-LAYOUT.md` | this file |
| `en/BUILD.md` | local build, cache and ccache, adding features, debugging |
| `en/FLASHING.md` | flashing via the web UI and UART, stock firmware recovery |
| `en/GLINET-DEFAULTS.md` | correspondence table of GL.iNet (4.9.0) defaults and our configuration |

Every document (and both READMEs) has a language switcher at the top:
**Русский · English**.

---

## 6. Miscellaneous

| File | Purpose |
|---|---|
| `.gitignore` | excludes build working directories (`build/`, `.work/`, `.patchgen/`) |
| `LICENSE` | MIT |
