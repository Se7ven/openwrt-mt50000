[**Русский**](../BUILD.md) · **English**

# Local build

## 1. Requirements

* Linux (tested on Ubuntu 22.04/24.04), ~100 GB of free disk, 8 GB of RAM;
* the OpenWrt build toolchain is installed automatically, the only extra requirement is a host compiler.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib \
    gettext git libncurses-dev libssl-dev python3 python3-setuptools \
    rsync swig unzip zlib1g-dev file wget
```

## 2. Building

### 2.1 Vanilla (upstream)

```bash
./scripts/build.sh \
    --workdir "$PWD/build" \
    --source upstream \
    --ref main \
    --switch-driver dsa \
    --profile full \
    --jobs "$(nproc)"
```

`--ref` accepts a branch, tag or SHA. On branches whose kernel is not 6.18 the in-tree
DSA driver will not apply — use `--switch-driver swconfig` (see below) or the `main` branch.

### 2.2 GL.iNet (`mt5000` branch)

```bash
./scripts/build.sh \
    --workdir "$PWD/build-gl" \
    --source glinet \
    --ref mt5000 \
    --switch-driver dsa \
    --profile full \
    --jobs "$(nproc)"
```

### 2.3 Rebuilding (cache)

`scripts/build.sh` reuses the `--workdir` directory: the OpenWrt tree, `dl/` (package
sources) and the toolchain stay in place. For a full rebuild:

```bash
rm -rf build/openwrt/{staging_dir,build_dir,tmp}   # reset only the build directories
rm -rf build/openwrt/.config                         # reset the configuration
```

Complete cleanup: `rm -rf build`.

## 3. What `scripts/build.sh` does

1. **fetch** — clones the sources (`--source`, `--ref`).
2. **patches** — applies the series from `patches/<flavour>/series`:
   * `apply` — a patch for the tree (`git apply` → `git apply -3` → `patch --fuzz=3`);
   * `pending` — a kernel patch is copied into `target/linux/generic/pending-<kernel version>/`,
     the directory name is determined automatically from the tree;
   * `require-series` — checks that the tree's kernel version matches the required one
     (currently 6.18). On mismatch, a strict-mode build fails with a clear message.
3. **runtime** — adds the `glinet-mt5000-defaults` package with GL.iNet defaults.
4. **feeds** — `scripts/feeds update -a && scripts/feeds install -a`.
5. **config** — `scripts/gen-config.sh`: `make defconfig` + merge of buildinfo/fragments + `make defconfig`.
6. **build** — `make download -jN` and `make -jN V=s`.
7. **artifacts** — `scripts/collect-artifacts.sh` puts the images into `<workdir>/out/`.

## 4. Build configuration

### 4.1 Layers

```
config/buildinfo/<flavour>.config.buildinfo   # mandatory
config/fragments/*.config                     # optional (alphabetical order)
+ runtime additions (glinet-mt5000-defaults, kmod-rtl8366ub for swconfig)
```

The `gen-config.sh` script merges the layers via `scripts/merge-config.py` (a custom
implementation, because upstream removed the `diffconfig.sh -m` mode in 2026), and then
runs `make defconfig`, which resolves dependencies and drops unknown symbols.
Unknown symbols (for example, `luci-app-openvpn` in the new LuCI, where it was renamed
to `luci-proto-openvpn`) are ignored with a warning — which is why both spellings are
kept in the fragments.

### 4.2 Your own package set

Create a file, for example `config/fragments/60-my.config`:

```
CONFIG_PACKAGE_luci-app-tailscale-community=y
CONFIG_PACKAGE_kmod-dummy=y
```

and pass it in:

```bash
./scripts/build.sh --workdir build --source upstream --ref main --profile custom \
                    --fragment config/fragments/60-my.config
```

Or simply put it into `config/fragments/` — with `--profile full` all files are picked up.

### 4.3 A "minimal" image

```bash
./scripts/build.sh ... --profile minimal
```

Only the target + mandatory packages remain (dnsmasq, firewall4, LuCI, basic kmods).

## 5. The `swconfig` mode
```bash
./scripts/build.sh ... --switch-driver swconfig
```

The `apply-patches.sh` script clones `https://github.com/gl-inet/gl-rtl8366ub` into
`package/kernel/rtl8366ub` and strips the installation of the diagnostic script from
its Makefile (that file does not exist in the upstream repository, the build would
fail on `INSTALL_BIN`).

The runtime configuration then comes from `config/runtime/swconfig/` — it reproduces
the switch layout of the stock GL.iNet 4.9.0 firmware:

```
switch0:  port 0 → LAN1, port 1 → LAN2, port 17 (CPU) → eth0
LAN:      eth0.1 (switch CPU port)
WAN:      eth1 (internal PHY)
```

This layout is written into `board.d/02_network` (patch `0003s-...-swconfig.patch`),
so in `swconfig` mode no extra uci-defaults for the switch are needed.

> ⚠️ The out-of-tree driver was written for older kernels; on kernel 6.18 it may fail
> to build. In that case use `--switch-driver dsa` on a kernel-6.18 branch.
> The opposite situation is also possible: the driver does not build on 6.12 —
> then you need `dsa` and a kernel-6.18 branch.

## 6. Regenerating the patch series

If upstream moved on and the patches no longer apply:

```bash
./tools/regen-patches.sh
git diff patches/vanilla/
```

The script re-downloads the base (`openwrt/openwrt@main`) and the changes
(`GLiNet-Tech/openwrt@mt5000`) and rebuilds `patches/vanilla/*.patch`.

### 6.1. Kernel patches (RTL8366UB driver)

Kernel patches are applied by the kernel build with `patch -p1`: if the branch's kernel
was updated, their context stops matching and the build dies in
`toolchain/kernel-headers`. To avoid waiting for that:

* **before the build** a preflight check runs
  (`scripts/verify-kernel-patches.sh`, invoked by `scripts/build.sh` after
  `make download`): it unpacks the kernel, applies the OpenWrt kernel patches that
  touch our files, and checks our patches against the result. The check takes a few
  minutes and saves hours of building; disable it with `--skip-verify`;
* **regenerate** the patch for a new kernel:

```bash
# the kernel tarball must be present in the OpenWrt tree: make download
./tools/regen-kernel-patches.sh --tree /path/to/openwrt
git diff patches/vanilla/kernel/
```

The script determines the kernel version itself (`target/linux/generic/kernel-<series>`),
applies the OpenWrt kernel patches and our `990-01`/`990-02`, and then regenerates
`990-03` (the race-condition fix in `mtk_eth_soc.c`) against the current kernel code.
If the fix has already been merged into the upstream kernel (as of linux 6.18.60), the
script deletes the local `990-03` instead — its entry then has to be removed from
`patches/vanilla/series`.

> The `990-xx` numbers are chosen with headroom: kernel patches are applied in
> alphabetical order, and ours must come **after** all regular OpenWrt patches
> (currently the highest number in `pending-6.18` is 936, in `backport-6.18` — 942).

## 6.2. Releases and file names

Every build gets an identifier (it is also the GitHub release tag and the file-name prefix):

```
mt5000-<source>-<branch/tag>-<switch driver>-<YYYYMMDD-HHMM UTC>
```

For example:

```
mt5000-upstream-main-dsa-20261021-1432
mt5000-glinet-mt5000-swconfig-20261021-1432
```

The timestamp can be set manually (otherwise the current UTC time is used):

```bash
./scripts/build.sh --workdir build --source upstream --ref main --stamp 20261021-1432
```

The output directory contains:

| File | Contents |
|---|---|
| `mt5000-…-<stamp>-openwrt-…-sysupgrade.bin` | sysupgrade image |
| `mt5000-…-<stamp>-openwrt-…-factory.bin` | full image for U-Boot |
| `mt5000-…-<stamp>.config` / `.config.buildinfo` | build configuration |
| `build-info.txt` | summary: source, ref, commit, driver, kernel, date |
| `release.md` | release description (parameter table) |
| `release.json` | release tag, name and parameters in machine-readable form |
| `SHA256SUMS` | checksums |

Create the same release locally (with GitHub CLI):

```bash
gh release create "$(python3 -c "import json;print(json.load(open('build/out/release.json'))['tag'])")" \
    build/out/* --title "..." --notes-file build/out/release.md
```

## 7. Debugging
```bash
# apply the patches manually to a local tree
./scripts/apply-patches.sh --tree /path/to/openwrt --series patches/vanilla/series --strict

# see exactly what changed
cd /path/to/openwrt && git status && git diff

# rebuild only the configuration
cd /path/to/openwrt && make defconfig && \
  python3 ../scripts/merge-config.py --config .config \
          --merge ../config/buildinfo/vanilla.config.buildinfo && \
  make defconfig
```

Common problems:

| Symptom | Cause |
|---|---|
| `the MT5000 device is not selected in .config` | another profile is still selected in `.config`: target/subtarget/device are members of a Kconfig `choice`, and `make defconfig` keeps the old choice member. `scripts/merge-config.py` deselects the other members automatically (`--kconfig tmp/.config-target.in`), but if the generated Kconfig file is missing, deselect the old symbol manually: `# CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one is not set` |
| `patch does not apply` | upstream changed the context — run `tools/regen-patches.sh` |
| `Patch failed! Please fix .../990-0x-...` | the kernel was updated and the kernel-patch context no longer matches: for `990-03` — `tools/regen-kernel-patches.sh --tree <openwrt>` (see §6.1; it also deletes `990-03` when the fix is already in the kernel); for `990-01`/`990-02` — rebase the hunks onto the new main manually (`include/net/dsa.h` and `mtk_ppe_offload.c` change most often); caught upfront by `scripts/verify-kernel-patches.sh` |
| `kernel series mismatch` | the branch is not 6.18 — you need `--switch-driver swconfig` (for `dsa` the error looks like `... needs kernel 6.18, but the tree uses 6.12`) |
| `unknown package` in `filogic.mk` | the branch has no `mt7987-2p5g-phy-firmware` — use `main` |
| `kmod-rtl8366ub` fails to build | the out-of-tree driver is incompatible with the new kernel → use `dsa` |
| `luci-app-*` did not appear | the package was renamed, see `config/fragments/40-luci.config` |
| the `glinet-mt5000-defaults` package was not created | `package/glinet-mt5000-defaults/Makefile` is missing `include $(INCLUDE_DIR)/package.mk` |
| `Package/glinet-mt5000-defaults is missing the VERSION field` | OpenWrt 2026 (built via `apk`) requires the package to have `TITLE`, `CATEGORY`, `SECTION` and `VERSION` fields — they are set in `scripts/install-runtime.sh` |
| `No targets specified and no makefile found` (in `build_dir/...//.built`) | `PKG_NAME`/`PKG_VERSION` must be set **before** `include $(INCLUDE_DIR)/package.mk`: `include/package.mk` computes `PKG_BUILD_DIR` at include time. A package without sources must also declare an empty `Build/Compile` and `Build/Prepare` (like `package/base-files`) |
| `label '...' defined but not used [-Werror=unused-label]` | a label nobody jumps to was left in a kernel patch — regenerate the patch (`tools/regen-kernel-patches.sh`) |
