[**Русский**](README.md) · **English**

# openwrt-gl-mt5000-builder

A repository for building **OpenWrt** firmware for the **GL.iNet GL-MT5000 (Brume 3)** router.

Two GitHub Actions pipelines:

| Pipeline | File | Source | Notes |
|---|---|---|---|
| **vanilla** | `.github/workflows/build-vanilla.yml` | `openwrt/openwrt` (any branch or tag of your choice) | the full MT5000 support patch set is applied to bare upstream, including **all Realtek RTL8366UB switch patches** (in-tree DSA driver) |
| **glinet** | `.github/workflows/build-glinet.yml` | `GLiNet-Tech/openwrt`, branch `mt5000` | uses GL.iNet's own MT5000-enabled branch, only the GL.iNet-style runtime configuration is added |

---

## 1. What the device is

| | |
|---|---|
| Model | GL.iNet GL-MT5000 (Brume 3) |
| SoC | MediaTek MT7987A (4× A53 @2.0 GHz), Filogic 830 |
| RAM / Flash | 1 GiB DDR4 / 8 GiB eMMC |
| Ethernet | 3 × 2.5 GbE: **LAN1**, **LAN2** — ports of the **Realtek RTL8366UB** switch; **WAN** — the SoC's built-in PHY (`eth1`) |
| Wi-Fi | **none** (wired device) |
| LEDs | blue "run" (power), white "system", white "vpn" |
| Partitions | GPT, u-boot-env, factory, fip, cfg, log, kernel, rootfs |
| MAC | base MAC in `factory` @ `0x4000`; `gmac1` (WAN) = base-2, `gmac0` (LAN) = base-1 |

There is no official upstream OpenWrt support yet — PR [openwrt/openwrt#24237](https://github.com/openwrt/openwrt/pull/24237) is in progress.
That is exactly why the "vanilla" pipeline carries the patches, while the "glinet" pipeline uses the ready `mt5000` branch.

---

## 2. Quick start

### 2.1 vanilla (upstream OpenWrt, branch/tag of your choice)

```bash
git clone https://github.com/<owner>/openwrt-gl-mt5000-builder.git
cd openwrt-gl-mt5000-builder

./scripts/build.sh \
    --workdir /tmp/mt5000 \
    --source upstream \
    --ref main \                 # or openwrt-25.12, v24.10.5, ...
    --switch-driver dsa \
    --profile full
```

Finished images: `/tmp/mt5000/out/`.

### 2.2 glinet (`mt5000` branch)

```bash
./scripts/build.sh \
    --workdir /tmp/mt5000-gl \
    --source glinet \
    --ref mt5000 \
    --switch-driver dsa \
    --profile full
```

### 2.3 GitHub Actions

* **Actions → Build (vanilla OpenWrt) → Run workflow** — fields `ref` (OpenWrt branch/tag), `switch_driver`, `profile`, `jobs`.
* **Actions → Build (GL.iNet mt5000) → Run workflow** — fields `ref` (default `mt5000`), `switch_driver`, `profile`, `jobs`.

Artifacts are collected into `artifacts/` and uploaded to GitHub Actions as `openwrt-vanilla-<ref>-<driver>` / `openwrt-glinet-<ref>-<driver>`.

---

## 2.4. Releases

Every successful build creates a **GitHub release** whose name shows how the image was built:

| Pipeline | Tag (and release name) |
|---|---|
| vanilla, branch `main`, `dsa` | `mt5000-upstream-main-dsa-20261021-1432` |
| vanilla, tag `v25.12.6`, `swconfig` | `mt5000-upstream-v25.12.6-swconfig-20261021-1432` |
| GL.iNet, branch `mt5000`, `dsa` | `mt5000-glinet-mt5000-dsa-20261021-1432` |

Tag format: `mt5000-<source>-<branch/tag>-<switch driver>-<UTC date and time>`.

The file names inside the release carry the same prefix, so the file name always tells
you the build's origin, with the date at the end:

```
mt5000-upstream-main-dsa-20261021-1432-openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin
mt5000-upstream-main-dsa-20261021-1432-openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-factory.bin
mt5000-upstream-main-dsa-20261021-1432.config
mt5000-upstream-main-dsa-20261021-1432.config.buildinfo
SHA256SUMS
build-info.txt
```

The release description (`release.md`) contains a table: source, branch/tag, commit,
switch driver, kernel version, profile, build date and the configuration used.

---

## 3. What is in the repository

The full description is in **[docs/en/REPO-LAYOUT.md](docs/en/REPO-LAYOUT.md)**. In short:

```
.
├── .github/workflows/
│   ├── build-vanilla.yml          # pipeline 1: upstream OpenWrt (branch/tag of your choice) + MT5000/RTL8366UB patches
│   └── build-glinet.yml           # pipeline 2: GLiNet-Tech/openwrt, branch mt5000
├── scripts/
│   ├── common.sh                  # shared helpers (logging, kernel-version detection, etc.)
│   ├── fetch-source.sh            # clones the sources (upstream or gl-inet) by ref
│   ├── apply-patches.sh           # applies the patch series + installs kernel patches
│   ├── install-runtime.sh         # installs the GL.iNet runtime-configuration package
│   ├── gen-config.sh              # builds .config from buildinfo + fragments
│   ├── verify-kernel-patches.sh   # preflight check of the kernel patches
│   ├── merge-config.py            # merges config fragments into .config
│   ├── build.sh                   # orchestrates the whole process
│   └── collect-artifacts.sh       # collects images, config.buildinfo, SHA256
├── patches/
│   ├── vanilla/                   # patch series for upstream (see patches/vanilla/series)
│   │   ├── series                 # series manifest
│   │   ├── 0001-...-mt5000.patch  # DTS
│   │   ├── 0002-...-mt5000.patch  # image definition (image/filogic.mk)
│   │   ├── 0003-...-mt5000.patch  # board.d/02_network
│   │   ├── 0004-...-mt5000.patch  # upgrade/platform.sh
│   │   ├── 0005-...-rtl8366ub.patch  # kernel config (config-6.18)
│   │   └── kernel/                # kernel patches (installed into pending-<version>/)
│   │       ├── 990-01-net-dsa-realtek-add-rtl8366ub.patch
│   │       └── 990-02-net-mediatek-rtl8366ub-ppe-offload.patch
│   └── glinet/series              # the GL.iNet branch needs no patches (manifest is empty)
├── config/
│   ├── buildinfo/                 # mandatory part of the build configuration
│   │   ├── vanilla.config.buildinfo
│   │   └── glinet.config.buildinfo
│   ├── fragments/                 # optional package sets
│   │   ├── 00-target.config
│   │   ├── 10-network.config
│   │   ├── 20-storage.config
│   │   ├── 30-vpn.config
│   │   ├── 40-luci.config
│   │   └── 50-services.config
│   └── runtime/                   # runtime configuration (GL.iNet style)
│       ├── dsa/                   # variant with the in-tree DSA switch driver
│       └── swconfig/              # variant with the out-of-tree driver (like stock GL.iNet)
├── tools/
│   ├── regen-patches.sh           # rebuilds the patch series from upstream + the GL.iNet branch
│   ├── regen-kernel-patches.sh    # rebuilds the kernel patch for a new kernel
│   └── extract-stock-defaults.sh  # unpacks the stock GL.iNet firmware (reference defaults)
├── docs/
│   ├── REPO-LAYOUT.md             # Russian: where everything is and why
│   ├── BUILD.md                   # Russian: local build, customization
│   ├── FLASHING.md                # Russian: flashing and rollback
│   ├── GLINET-DEFAULTS.md         # Russian: which GL.iNet defaults are reproduced
│   └── en/                        # English versions of all of the above
│       ├── REPO-LAYOUT.md
│       ├── BUILD.md
│       ├── FLASHING.md
│       └── GLINET-DEFAULTS.md
├── README.md                      # Russian version (default)
└── README.en.md                   # this file
```

---

## 4. The Realtek RTL8366UB switch — two modes

| Mode | Driver | Ports | When to use |
|---|---|---|---|
| `dsa` (default) | in-tree `NET_DSA_REALTEK_RTL8366UB` (Linux 6.18, patches `990-01`/`990-02`) | `lan1`, `lan2` (DSA), WAN — `eth1` | OpenWrt branches with kernel 6.18 (`main`), the GL.iNet `mt5000` branch |
| `swconfig` | out-of-tree `kmod-rtl8366ub` from [gl-inet/gl-rtl8366ub](https://github.com/gl-inet/gl-rtl8366ub) — the same driver as in the stock GL.iNet firmware | swconfig switch `switch0` (ports 0,1, CPU 17@eth0), LAN — `eth0.1` | older OpenWrt branches (25.12 etc.) without the in-tree DSA driver yet; experimental |

`dsa` is the recommended mode: it is what the `mt5000` branch and upstream PR #24237 use.
`swconfig` is wired up automatically when the corresponding `--switch-driver` is selected
(`package/kernel/rtl8366ub` is added to the tree, and the DSA patches and the "kernel 6.18"
requirement are turned off).

---

## 5. Configurations

* **Build configuration** — `config/buildinfo/*.config.buildinfo` (mandatory) + `config/fragments/*.config` (optional).
  Assembled into `.config` by `scripts/gen-config.sh` via `scripts/merge-config.py`.
* **Runtime configuration** — `config/runtime/<variant>/`: the `glinet-mt5000-defaults` package,
  which on first boot sets the GL.iNet defaults: router IP `192.168.8.1/24`, DHCP pool
  `192.168.8.100–249`, hostname `GL-MT5000`, IPv6 on WAN disabled, `console.gl-inet.com`
  → router IP, WAN zone with `input DROP` and no ICMP echo, white "system" LED on.
  Details and sources — in [docs/en/GLINET-DEFAULTS.md](docs/en/GLINET-DEFAULTS.md).

---

## 6. Documentation

* [docs/en/REPO-LAYOUT.md](docs/en/REPO-LAYOUT.md) — repository map: what lives where and why.
* [docs/en/BUILD.md](docs/en/BUILD.md) — local build, caching, tricks, adding packages.
* [docs/en/FLASHING.md](docs/en/FLASHING.md) — flashing via the web UI and UART, rollback.
* [docs/en/GLINET-DEFAULTS.md](docs/en/GLINET-DEFAULTS.md) — "GL.iNet default → how we do it" table.
