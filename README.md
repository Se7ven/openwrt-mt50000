# openwrt-gl-mt5000-builder

Репозиторий для сборки прошивки **OpenWrt** для роутера **GL.iNet GL-MT5000 (Brume 3)**.

Два пайплайна GitHub Actions:

| Пайплайн | Файл | Источник | Особенности |
|---|---|---|---|
| **vanilla** | `.github/workflows/build-vanilla.yml` | `openwrt/openwrt` (любая ветка или тег на выбор) | на голый upstream накладывается полный набор патчей поддержки MT5000, включая **все патчи свитча Realtek RTL8366UB** (in-tree DSA-драйвер) |
| **glinet** | `.github/workflows/build-glinet.yml` | `GLiNet-Tech/openwrt`, ветка `mt5000` | используется «родная» ветка GL.iNet с поддержкой MT5000, добавляется только рантайм-конфигурация в стиле GL.iNet |

---

## 1. Что за устройство

| | |
|---|---|
| Модель | GL.iNet GL-MT5000 (Brume 3) |
| SoC | MediaTek MT7987A (4× A53 @2.0 GHz), Filogic 830 |
| RAM / Flash | 1 GiB DDR4 / 8 GiB eMMC |
| Ethernet | 3 × 2.5 GbE: **LAN1**, **LAN2** — порты коммутатора **Realtek RTL8366UB**; **WAN** — встроенный PHY SoC (`eth1`) |
| Wi-Fi | **нет** (устройство проводное) |
| LEDs | синий «run» (питание), белый «system», белый «vpn» |
| Разделы | GPT, u-boot-env, factory, fip, cfg, log, kernel, rootfs |
| MAC | base MAC в `factory` @ `0x4000`; `gmac1` (WAN) = base-2, `gmac0` (LAN) = base-1 |

Официальной поддержки в upstream OpenWrt пока нет — идёт PR [openwrt/openwrt#24237](https://github.com/openwrt/openwrt/pull/24237).
Именно поэтому «vanilla»-пайплайн везёт с собой патчи, а «glinet»-пайплайн берёт готовую ветку `mt5000`.

---

## 2. Быстрый старт

### 2.1. vanilla (upstream OpenWrt, ветка/тег на выбор)

```bash
git clone https://github.com/<owner>/openwrt-gl-mt5000-builder.git
cd openwrt-gl-mt5000-builder

./scripts/build.sh \
    --workdir /tmp/mt5000 \
    --source upstream \
    --ref main \                 # или openwrt-25.12, v24.10.5, ...
    --switch-driver dsa \
    --profile full
```

Готовые образы: `/tmp/mt5000/out/`.

### 2.2. glinet (ветка `mt5000`)

```bash
./scripts/build.sh \
    --workdir /tmp/mt5000-gl \
    --source glinet \
    --ref mt5000 \
    --switch-driver dsa \
    --profile full
```

### 2.3. GitHub Actions

* **Actions → Build (vanilla OpenWrt) → Run workflow** — поле `ref` (ветка/тег OpenWrt), `switch_driver`, `profile`, `jobs`.
* **Actions → Build (GL.iNet mt5000) → Run workflow** — поле `ref` (по умолчанию `mt5000`), `switch_driver`, `profile`, `jobs`.

Артефакты складываются в `artifacts/` и грузятся в GitHub Actions как `openwrt-vanilla-<ref>-<driver>` / `openwrt-glinet-<ref>-<driver>`.

---

## 3. Что лежит в репозитории

Полное описание — в **[docs/REPO-LAYOUT.md](docs/REPO-LAYOUT.md)**. Коротко:

```
.
├── .github/workflows/
│   ├── build-vanilla.yml          # пайплайн 1: upstream OpenWrt (ветка/тег на выбор) + патчи MT5000/RTL8366UB
│   └── build-glinet.yml           # пайплайн 2: GLiNet-Tech/openwrt, ветка mt5000
├── scripts/
│   ├── common.sh                  # общие хелперы (лог, определение версии ядра и т.п.)
│   ├── fetch-source.sh            # клонирование исходников (upstream или gl-inet) по ref
│   ├── apply-patches.sh           # применение серии патчей + установка kernel-патчей
│   ├── install-runtime.sh         # установка пакета с рантайм-конфигом GL.iNet
│   ├── gen-config.sh              # сборка .config из buildinfo + фрагментов
│   ├── merge-config.py            # слияние конфиг-фрагментов с .config
│   ├── build.sh                   # оркестратор всего процесса
│   └── collect-artifacts.sh       # сборка образов, config.buildinfo, SHA256
├── patches/
│   ├── vanilla/                   # серия патчей для upstream (см. patches/vanilla/series)
│   │   ├── series                 # манифест серии
│   │   ├── 0001-...-mt5000.patch  # DTS
│   │   ├── 0002-...-mt5000.patch  # определение образа (image/filogic.mk)
│   │   ├── 0003-...-mt5000.patch  # board.d/02_network
│   │   ├── 0004-...-mt5000.patch  # upgrade/platform.sh
│   │   ├── 0005-...-rtl8366ub.patch  # kernel config (config-6.18)
│   │   └── kernel/                # kernel-патчи (устанавливаются в pending-<версия>/)
│   │       ├── 940-01-net-dsa-realtek-add-rtl8366ub.patch
│   │       ├── 940-02-net-dsa-rtl8366ub-8021q-ppe-offload.patch
│   │       └── 940-03-net-mediatek-init-dummy-napi-before-netdev-registration.patch
│   └── glinet/series              # для ветки GL.iNet патчи не нужны (манифест пуст)
├── config/
│   ├── buildinfo/                 # обязательная часть конфига сборки
│   │   ├── vanilla.config.buildinfo
│   │   └── glinet.config.buildinfo
│   ├── fragments/                 # опциональные наборы пакетов
│   │   ├── 00-target.config
│   │   ├── 10-network.config
│   │   ├── 20-storage.config
│   │   ├── 30-vpn.config
│   │   ├── 40-luci.config
│   │   └── 50-services.config
│   └── runtime/                   # рантайм-конфигурация (стиль GL.iNet)
│       ├── dsa/                   # вариант с in-tree DSA-драйвером свитча
│       └── swconfig/              # вариант с out-of-tree драйвером (как в стоке GL.iNet)
├── tools/
│   └── regen-patches.sh           # пересборка серии патчей из upstream + ветки GL.iNet
├── docs/
│   ├── REPO-LAYOUT.md             # где что лежит и зачем
│   ├── BUILD.md                   # локальная сборка, кастомизация
│   ├── FLASHING.md                # прошивка и откат
│   └── GLINET-DEFAULTS.md         # какие дефолты GL.iNet воспроизведены
└── README.md
```

---

## 4. Свитч Realtek RTL8366UB — два режима

| Режим | Драйвер | Порты | Когда использовать |
|---|---|---|---|
| `dsa` (по умолчанию) | in-tree `NET_DSA_REALTEK_RTL8366UB` (Linux 6.18, патчи `940-01`/`940-02`) | `lan1`, `lan2` (DSA), WAN — `eth1` | ветки OpenWrt с ядром 6.18 (`main`), ветка GL.iNet `mt5000` |
| `swconfig` | out-of-tree `kmod-rtl8366ub` из [gl-inet/gl-rtl8366ub](https://github.com/gl-inet/gl-rtl8366ub) — тот же драйвер, что в стоковой прошивке GL.iNet | swconfig-коммутатор `switch0` (порты 0,1, CPU 17@eth0) | старые ветки OpenWrt, где in-tree DSA ещё нет; экспериментально |

`dsa` — рекомендуемый режим: он же используется в ветке `mt5000` и в upstream PR #24237.
`swconfig` подключается автоматически, когда выбран соответствующий `--switch-driver`
(в дерево добавляется `package/kernel/rtl8366ub`).

---

## 5. Конфигурации

* **Конфиг сборки** — `config/buildinfo/*.config.buildinfo` (обязательное) + `config/fragments/*.config` (опциональное).
  Собирается в `.config` скриптом `scripts/gen-config.sh` через `scripts/merge-config.py`.
* **Рантайм-конфиг** — `config/runtime/<variant>/`: пакет `glinet-mt5000-defaults`, который на первом запуске
  выставляет дефолты GL.iNet: IP роутера `192.168.8.1/24`, пул DHCP `192.168.8.100–249`,
  hostname `GL-MT5000`, IPv6 на WAN выключен, `console.gl-inet.com` → IP роутера,
  зона WAN с `input DROP` и без ICMP echo, белый LED «system» включён.
  Подробности и источники — в [docs/GLINET-DEFAULTS.md](docs/GLINET-DEFAULTS.md).

---

## 6. Документация

* [docs/REPO-LAYOUT.md](docs/REPO-LAYOUT.md) — карта репозитория: что где лежит и зачем.
* [docs/BUILD.md](docs/BUILD.md) — локальная сборка, кэш, трюки, добавление пакетов.
* [docs/FLASHING.md](docs/FLASHING.md) — прошивка через web-UI и по UART, откат.
* [docs/GLINET-DEFAULTS.md](docs/GLINET-DEFAULTS.md) — таблица «дефолт GL.iNet → как у нас».
