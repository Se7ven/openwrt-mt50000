# Локальная сборка

## 1. Требования

* Linux (проверено на Ubuntu 22.04/24.04), ~100 ГБ свободного места, 8 ГБ RAM;
* тулчейн для сборки OpenWrt ставится автоматически, дополнительно нужен только host-компилятор.

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    build-essential clang flex bison g++ gawk gcc-multilib \
    gettext git libncurses-dev libssl-dev python3 python3-setuptools \
    rsync swig unzip zlib1g-dev file wget
```

## 2. Сборка

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

`--ref` принимает ветку, тег или SHA. Для веток, где ядро не 6.18, in-tree DSA-драйвер
не применится — используйте `--switch-driver swconfig` (см. ниже) или ветку `main`.

### 2.2 GL.iNet (ветка `mt5000`)

```bash
./scripts/build.sh \
    --workdir "$PWD/build-gl" \
    --source glinet \
    --ref mt5000 \
    --switch-driver dsa \
    --profile full \
    --jobs "$(nproc)"
```

### 2.3 Повторная сборка (кэш)

`scripts/build.sh` переиспользует каталог `--workdir`: дерево OpenWrt, `dl/` (исходники пакетов)
и toolchain остаются на месте. Для полной пересборки:

```bash
rm -rf build/openwrt/{staging_dir,build_dir,tmp}   # сбросить только сборочные каталоги
rm -rf build/openwrt/.config                         # сбросить конфиг
```

Полная очистка: `rm -rf build`.

## 3. Что делает `scripts/build.sh`

1. **fetch** — клонирует исходники (`--source`, `--ref`).
2. **patches** — применяет серию из `patches/<flavour>/series`:
   * `apply` — патч к дереву (`git apply` → `git apply -3` → `patch --fuzz=3`);
   * `pending` — kernel-патч копируется в `target/linux/generic/pending-<версия ядра>/`,
     имя каталога определяется автоматически по дереву;
   * `require-series` — проверяет, что версия ядра дерева совпадает с требуемой
     (сейчас 6.18). При несовпадении в строгом режиме сборка падает с понятным сообщением.
3. **runtime** — добавляет пакет `glinet-mt5000-defaults` с дефолтами GL.iNet.
4. **feeds** — `scripts/feeds update -a && scripts/feeds install -a`.
5. **config** — `scripts/gen-config.sh`: `make defconfig` + merge buildinfo/фрагментов + `make defconfig`.
6. **build** — `make download -jN` и `make -jN V=s`.
7. **artifacts** — `scripts/collect-artifacts.sh` складывает образы в `<workdir>/out/`.

## 4. Конфигурация сборки

### 4.1 Слои

```
config/buildinfo/<flavour>.config.buildinfo   # обязательное
config/fragments/*.config                     # опциональное (алфавитный порядок)
+ рантайм-добавки (glinet-mt5000-defaults, kmod-rtl8366ub для swconfig)
```

Скрипт `gen-config.sh` мержит слои через `scripts/merge-config.py` (собственная реализация,
потому что в upstream в 2026 году убрали режим `diffconfig.sh -m`), а затем запускает
`make defconfig`, который разруливает зависимости и отбрасывает неизвестные символы.
Неизвестные символы (например, `luci-app-openvpn` в новом LuCI, где его переименовали
в `luci-proto-openvpn`) игнорируются с предупреждением — поэтому в фрагментах оставлены
оба варианта написания.

### 4.2 Свой набор пакетов

Создайте файл, например `config/fragments/60-my.config`:

```
CONFIG_PACKAGE_luci-app-tailscale-community=y
CONFIG_PACKAGE_kmod-dummy=y
```

и подключите его:

```bash
./scripts/build.sh --workdir build --source upstream --ref main --profile custom \
                    --fragment config/fragments/60-my.config
```

Либо просто добавьте его в `config/fragments/` — при `--profile full` подхватятся все файлы.

### 4.3 «Минимальный» образ

```bash
./scripts/build.sh ... --profile minimal
```

Остаётся только target + обязательные пакеты (dnsmasq, firewall4, LuCI, базовые kmod).

## 5. Режим `swconfig`
```bash
./scripts/build.sh ... --switch-driver swconfig
```

Скрипт `apply-patches.sh` клонирует `https://github.com/gl-inet/gl-rtl8366ub` в
`package/kernel/rtl8366ub` и вырезает из его Makefile установку диагностического скрипта
(в upstream-репозитории этого файла нет, сборка падала бы на `INSTALL_BIN`).

Рантайм-конфиг при этом берётся из `config/runtime/swconfig/` — он повторяет раскладку
коммутатора из стоковой прошивки GL.iNet 4.9.0:

```
switch0:  порт 0 → LAN1, порт 1 → LAN2, порт 17 (CPU) → eth0
LAN:      eth0.1 (CPU-порт коммутатора)
WAN:      eth1 (внутренний PHY)
```

Эта раскладка прописывается в `board.d/02_network` (патч `0003s-...-swconfig.patch`),
поэтому в режиме `swconfig` дополнительных uci-defaults для коммутатора не требуется.

> ⚠️ Out-of-tree драйвер написан под старые ядра; на ядре 6.18 он может не собраться.
> В таком случае используйте `--switch-driver dsa` на ветке с ядром 6.18.
> Обратная ситуация тоже возможна: драйвер не собирается на 6.12 —
> тогда нужен `dsa` и ветка с ядром 6.18.

## 6. Пересборка серии патчей

Если upstream обновился и патчи перестали применяться:

```bash
./tools/regen-patches.sh
git diff patches/vanilla/
```

Скрипт заново скачивает базу (`openwrt/openwrt@main`) и изменения
(`GLiNet-Tech/openwrt@mt5000`) и пересобирает `patches/vanilla/*.patch`.

### 6.1. Kernel-патчи (драйвер RTL8366UB)

Kernel-патчи применяются сборкой ядра командой `patch -p1`: если ядро в ветке
обновилось, их контекст перестаёт совпадать и сборка падает в
`toolchain/kernel-headers`. Чтобы этого не ждать:

* **до сборки** выполняется предполётная проверка
  (`scripts/verify-kernel-patches.sh`, вызывается из `scripts/build.sh` после
  `make download`): она распаковывает ядро, применяет относящиеся к нашим
  файлам kernel-патчи OpenWrt и проверяет наши патчи. Проверка занимает
  несколько минут и экономит часы сборки; отключается `--skip-verify`;
* **перегенерировать** патч под новое ядро:

```bash
# в дереве OpenWrt должен лежать тарбол ядра: make download
./tools/regen-kernel-patches.sh --tree /path/to/openwrt
git diff patches/vanilla/kernel/
```

Скрипт сам определяет версию ядра (`target/linux/generic/kernel-<series>`),
применяет kernel-патчи OpenWrt и наши `990-01`/`990-02`, после чего
пересобирает `990-03` (фикс гонки в `mtk_eth_soc.c`) под актуальный код ядра.

> Номера `990-xx` выбраны с запасом: kernel-патчи применяются в алфавитном
> порядке, и наши должны идти **после** всех штатных патчей OpenWrt
> (сейчас максимальный номер в `pending-6.18` — 936, в `backport-6.18` — 942).

## 6.2. Релизы и имена файлов

Каждый билд получает идентификатор (он же тег GitHub-релиза и префикс имён файлов):

```
mt5000-<источник>-<ветка/тег>-<драйвер свитча>-<YYYYMMDD-HHMM UTC>
```

Например:

```
mt5000-upstream-main-dsa-20261021-1432
mt5000-glinet-mt5000-swconfig-20261021-1432
```

Штамп времени можно задать вручную (иначе берётся текущее время UTC):

```bash
./scripts/build.sh --workdir build --source upstream --ref main --stamp 20261021-1432
```

В каталоге вывода появляются:

| Файл | Содержимое |
|---|---|
| `mt5000-…-<stamp>-openwrt-…-sysupgrade.bin` | образ для sysupgrade |
| `mt5000-…-<stamp>-openwrt-…-factory.bin` | полный образ для U-Boot |
| `mt5000-…-<stamp>.config` / `.config.buildinfo` | конфигурация сборки |
| `build-info.txt` | сводка: источник, ref, коммит, драйвер, ядро, дата |
| `release.md` | описание релиза (таблица параметров) |
| `release.json` | тег, имя и параметры релиза в машинном виде |
| `SHA256SUMS` | контрольные суммы |

Создать такой же релиз локально (в GitHub CLI):

```bash
gh release create "$(python3 -c "import json;print(json.load(open('build/out/release.json'))['tag'])")" \
    build/out/* --title "..." --notes-file build/out/release.md
```

## 7. Отладка
```bash
# применить патчи вручную к локальному дереву
./scripts/apply-patches.sh --tree /path/to/openwrt --series patches/vanilla/series --strict

# посмотреть, что именно изменилось
cd /path/to/openwrt && git status && git diff

# пересобрать только конфиг
cd /path/to/openwrt && make defconfig && \
  python3 ../scripts/merge-config.py --config .config \
          --merge ../config/buildinfo/vanilla.config.buildinfo && \
  make defconfig
```

Частые проблемы:

| Симптом | Причина |
|---|---|
| `the MT5000 device is not selected in .config` | в `.config` остался выбранным другой профиль: target/subtarget/устройство — члены Kconfig-`choice`, и `make defconfig` сохраняет старого члена choice. `scripts/merge-config.py` снимает остальных членов автоматически (`--kconfig tmp/.config-target.in`), но если файл сгенерированной Kconfig отсутствует — снимите старый символ вручную: `# CONFIG_TARGET_mediatek_filogic_DEVICE_openwrt_one is not set` |
| `patch does not apply` | upstream изменил контекст — прогоните `tools/regen-patches.sh` |
| `Patch failed! Please fix .../990-03-...` | ядро обновилось и контекст kernel-патча не совпал — `tools/regen-kernel-patches.sh --tree <openwrt>` (см. §6.1); предварительно ловится проверкой `scripts/verify-kernel-patches.sh` |
| `kernel series mismatch` | ветка не 6.18 — нужен `--switch-driver swconfig` (для `dsa` ошибка выглядит как `... needs kernel 6.18, but the tree uses 6.12`) |
| `unknown package` в `filogic.mk` | в ветке нет `mt7987-2p5g-phy-firmware` — берите `main` |
| не собирается `kmod-rtl8366ub` | out-of-tree драйвер не совместим с новым ядром → `dsa` |
| `luci-app-*` не появился | пакет переименован, см. `config/fragments/40-luci.config` |
| пакет `glinet-mt5000-defaults` не создан | в `package/glinet-mt5000-defaults/Makefile` не хватает `include $(INCLUDE_DIR)/package.mk` |
| `Package/glinet-mt5000-defaults is missing the VERSION field` | OpenWrt 2026 (сборка через `apk`) требует у пакета поля `TITLE`, `CATEGORY`, `SECTION` и `VERSION` — они задаются в `scripts/install-runtime.sh` |
| `No targets specified and no makefile found` (в `build_dir/...//.built`) | `PKG_NAME`/`PKG_VERSION` должны быть заданы **до** `include $(INCLUDE_DIR)/package.mk`: `include/package.mk` вычисляет `PKG_BUILD_DIR` в момент включения. Пакет без исходников также должен объявлять пустой `Build/Compile` и `Build/Prepare` (как `package/base-files`) |
| `label '...' defined but not used [-Werror=unused-label]` | в kernel-патче осталась метка, на которую никто не переходит — перегенерируйте патч (`tools/regen-kernel-patches.sh`) |
