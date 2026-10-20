# Карта репозитория: что где лежит

Ниже — полный список файлов репозитория с назначением. Пути указаны от корня репозитория.

---

## 1. GitHub Actions — `.github/workflows/`

### `build-vanilla.yml` — пайплайн 1 (vanilla OpenWrt)

Собирает прошивку из **чистого upstream** `https://github.com/openwrt/openwrt`.

Входные параметры (`workflow_dispatch`):

| Параметр | По умолчанию | Назначение |
|---|---|---|
| `ref` | `main` | ветка или тег OpenWrt (`main`, `openwrt-25.12`, `v24.10.5`, любой SHA) |
| `switch_driver` | `dsa` | `dsa` — in-tree драйвер RTL8366UB; `swconfig` — out-of-tree драйвер Realtek |
| `profile` | `full` | `full` — все фрагменты из `config/fragments/`; `minimal` — только target |
| `jobs` | `8` | количество параллельных задач сборки |
| `strict_patches` | `true` | валить сборку, если какой-либо патч не применился |

Триггеры: ручной запуск, `push` в `main` (по изменениям в `patches/`, `config/`, `scripts/`), ежедневный `schedule`.

Шаги: установка зависимостей → освобождение диска → кэш `dl/` и ccache → `scripts/build.sh --source upstream` → сборка артефактов → `actions/upload-artifact`.

### `build-glinet.yml` — пайплайн 2 (GL.iNet)

Собирает прошивку из **форка GL.iNet** `https://github.com/GLiNet-Tech/openwrt`, ветка `mt5000`.
Набор входных параметров тот же, но `ref` по умолчанию — `mt5000`.

Отличие от vanilla: патчи поддержки MT5000 не накладываются (они уже в ветке), добавляется только рантайм-конфигурация GL.iNet.

---

## 2. Скрипты сборки — `scripts/`

| Файл | Назначение |
|---|---|
| `common.sh` | общие функции: логирование, определение версии ядра дерева (`kernel_series`), поиск каталога kernel-патчей (`pending_dir`), мелкие утилиты. Подключается через `.` всеми остальными скриптами. |
| `fetch-source.sh` | клонирование исходников: `--source upstream|glinet`, `--ref <branch|tag|sha>`, `--dest <dir>`. При повторном запуске использует существующий checkout и делает `git fetch`. |
| `apply-patches.sh` | применение серии патчей из `patches/<flavour>/series`. Директивы: `require-series`, `apply`, `pending`. Есть каскад `git apply` → `git apply -3` → `patch -p1 --fuzz=3`. Режимы `--strict`/`--no-strict`. Дополнительно ставит out-of-tree драйвер `package/kernel/rtl8366ub` при `--switch-driver swconfig`. |
| `install-runtime.sh` | создаёт в дереве пакет `package/glinet-mt5000-defaults` с файлами из `config/runtime/<variant>/`. Файлы `uci-defaults` и `init.d` становятся частью образа. |
| `gen-config.sh` | генерация `.config`: `make defconfig` → merge `config/buildinfo/<flavour>.config.buildinfo` → merge фрагментов `config/fragments/*.config` → merge рантайм-добавок (пакет `glinet-mt5000-defaults`, `kmod-rtl8366ub` для swconfig) → финальный `make defconfig`. |
| `merge-config.py` | слияние конфиг-фрагментов с `.config` (в upstream в 2026 году убрали режим `diffconfig.sh -m`, поэтому merger свой). |
| `build.sh` | главный оркестратор: fetch → patches → runtime → feeds → config → `make download` → `make` → collect. |
| `collect-artifacts.sh` | копирование готовых образов (`*gl-mt5000*`), `.config`, `config.buildinfo` в каталог вывода + `SHA256SUMS` + `build-info.txt`. |

Все скрипты — POSIX/bash, запускаются из корня репозитория, путь к репозиторию определяется автоматически (`BUILDER_ROOT`).

---

## 3. Патчи — `patches/`

### `patches/vanilla/series`

Манифест серии (формат: `<директива> <аргумент>`):

```
require-series 6.18      # kernel-патчи ниже рассчитаны на ядро 6.18
apply   0001-...patch     # патч применяется к дереву OpenWrt
pending kernel/940-...    # патч копируется в target/linux/generic/pending-<версия>/
```

### `patches/vanilla/*.patch` (применяются к дереву)

| Файл | Что делает | Источник |
|---|---|---|
| `0001-mediatek-dts-add-mt7987a-gl-mt5000.patch` | добавляет `target/linux/mediatek/dts/mt7987a-gl-mt5000.dts` | ветка `mt5000` GL.iNet |
| `0002-mediatek-image-add-glinet-gl-mt5000.patch` | добавляет определение образа `Device/glinet_gl-mt5000` в `target/linux/mediatek/image/filogic.mk` | ветка `mt5000` GL.iNet |
| `0003-mediatek-filogic-base-files-add-mt5000-network.patch` | `board.d/02_network`: LAN = `lan1 lan2` (порты DSA-свитча), WAN = `eth1` | ветка `mt5000` GL.iNet |
| `0004-mediatek-filogic-base-files-add-mt5000-upgrade.patch` | `upgrade/platform.sh`: разрешает sysupgrade на MT5000 | ветка `mt5000` GL.iNet |
| `0005-mediatek-filogic-kconfig-enable-rtl8366ub.patch` | `target/linux/mediatek/filogic/config-6.18`: `CONFIG_NET_DSA_REALTEK{,_MDIO,_RTL8366UB}=y` | ветка `mt5000` GL.iNet |

### `patches/vanilla/kernel/*.patch` (kernel-патчи, ставятся в `pending-<версия>/`)

| Файл | Что делает | Оригинал GL.iNet |
|---|---|---|
| `940-01-net-dsa-realtek-add-rtl8366ub.patch` | **in-tree DSA-драйвер RTL8366UB** (`drivers/net/dsa/realtek/rtl8366ub_*`, Kconfig `NET_DSA_REALTEK_RTL8366UB`) | `795-10-net-dsa-realtek-add-rtl8366ub.patch` |
| `940-02-net-dsa-rtl8366ub-8021q-ppe-offload.patch` | теггер `NET_DSA_TAG_RTL8366UB_8021Q` + поддержка offload в `mtk_ppe_offload` (без него PPE не видит EtherType и не работает WAN→LAN offload) | `795-11-net-dsa-rtl8366ub-8021q-ppe-offload.patch` |
| `940-03-net-mediatek-init-dummy-napi-before-netdev-registration.patch` | фикс гонки в `mtk_eth_soc.c` (dummy NAPI device) — нужен, чтобы сеть поднималась без ошибок | `795-12-net-mediatek-init-dummy-napi-before-netdev-registration.patch` |

Номера переименованы с `795-xx` на `940-xx`, чтобы патчи применялись **после** всех штатных патчей
текущего `target/linux/generic/pending-6.18/` (в upstream есть `936-...`).

### `patches/glinet/series`

Пустой манифест: ветка GL.iNet `mt5000` уже содержит DTS, образ, board-скрипты и kernel-патчи.
Место для локальных правок.

### `tools/regen-patches.sh`

Пересобирает всю серию `patches/vanilla/` из двух источников:
`openwrt/openwrt@main` (база) и `GLiNet-Tech/openwrt@mt5000` (изменения).
Используется, когда upstream обновился и контекст патчей «поехал».

---

## 4. Конфигурация сборки — `config/`

### `config/buildinfo/*.config.buildinfo`

Обязательная часть конфига в синтаксисе `diffconfig`. Содержит цель, устройство, rootfs и пакеты,
без которых роутер не работает.

* `vanilla.config.buildinfo` — для сборки из upstream.
* `glinet.config.buildinfo` — для сборки из ветки GL.iNet (отличия помечены комментариями).

### `config/fragments/*.config`

Опциональные наборы, добавляются поверх buildinfo (в алфавитном порядке):

| Файл | Содержимое |
|---|---|
| `00-target.config` | target/subtarget/device, тип rootfs и его размер |
| `10-network.config` | dnsmasq/firewall4, инструменты, offload MediaTek (PPE/HNAT) |
| `20-storage.config` | USB 3.0, файловые системы (ext4/vfat/f2fs/ntfs/exfat), mount-utils |
| `30-vpn.config` | OpenVPN, WireGuard, Tailscale, ZeroTier + их LuCI-протоколы |
| `40-luci.config` | LuCI и модули (в т.ч. русский язык) |
| `50-services.config` | chrony, AdGuardHome, SmartDNS, mwan3, SQM, утилиты |

### `config/runtime/<variant>/`

Рантайм-конфигурация, устанавливаемая в образ пакетом `glinet-mt5000-defaults`.

```
config/runtime/dsa/files/etc/
├── init.d/gl-mt5000-led            # белый LED "system" включается при старте
└── uci-defaults/99_gl-mt5000-defaults   # IP, DHCP, hostname, IPv6, firewall, console.gl-inet.com
config/runtime/swconfig/files/etc/
├── init.d/gl-mt5000-led
└── uci-defaults/
    ├── 98_gl-mt5000-switch         # swconfig-коммутатор switch0 (порты 0,1, CPU 17@eth0)
    └── 99_gl-mt5000-defaults
```

Важно: `/etc/config/*` **не** переопределяются пакетами (иначе конфликт с `dnsmasq`/`firewall4`),
всё применяется через `uci-defaults` — ровно так же, как это делает стоковая прошивка GL.iNet.

---

## 5. Документация — `docs/`

| Файл | Содержимое |
|---|---|
| `REPO-LAYOUT.md` | этот файл |
| `BUILD.md` | локальная сборка, кэш и ccache, добавление фич, отладка |
| `FLASHING.md` | прошивка через web-UI и по UART, восстановление стоковой прошивки |
| `GLINET-DEFAULTS.md` | таблица соответствия дефолтов GL.iNet (4.9.0) и нашей конфигурации |

---

## 6. Прочее

| Файл | Назначение |
|---|---|
| `.gitignore` | исключает рабочие каталоги сборки (`build/`, `.work/`, `.patchgen/`) |
| `LICENSE` | MIT |
