# Прошивка GL-MT5000

## 1. Что собирается

В `build/…/out/` попадают:

| Файл | Назначение |
|---|---|
| `openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin` | обычное обновление через web-UI / `sysupgrade` |
| `openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-factory.bin` | полный образ для восстановления через U-Boot (запись в eMMC) |
| `config-*.config`, `config-*.config.buildinfo`, `SHA256SUMS`, `build-info.txt` | конфигурация и метаданные сборки |

Проверка целостности:

```bash
cd build/out && sha256sum -c SHA256SUMS
```

## 2. Обновление с стоковой прошивки GL.iNet

Стоковая прошивка (4.x) и OpenWrt используют **разные** mechanisms апгрейда, поэтому:

1. Скачайте стоковую прошивку GL.iNet для MT5000 (4.9.0) с
   [dl.gl-inet.com/router/mt5000/stable](https://dl.gl-inet.com/router/mt5000/stable).
2. Прошейте её через web-интерфейс GL.iNet (**обязательный** шаг — он приводит разметку eMMC
   и U-Boot к схеме, которую ожидает OpenWrt).
3. После перезагрузки прошейте OpenWrt-образ: web-UI → **System → Upgrade**, либо по SSH:

```bash
scp openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin root@192.168.8.1:/tmp/
ssh root@192.168.8.1
cd /tmp && sysupgrade -n openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin
```

> Ключ `-n` (не сохранять конфигурацию) — обязателен при переходе со стоковой прошивки:
> форматы `/etc/config` различаются, и перенесённая конфигурация может поднять
> неправильную сеть.

## 3. Обновление с OpenWrt на OpenWrt

```bash
sysupgrade openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin
```

Конфигурация сохраняется, но при смене варианта свитча (`dsa` ↔ `swconfig`) конфигурацию
лучше сбросить: `sysupgrade -n`.

## 4. Восстановление через U-Boot (factory-образ)

Подключите UART (3.3 V TTL, 115200 8N1: GND-TX-RX) и запустите U-Boot:

```
=> setenv bootargs console=ttyS0,115200n8 root=PARTLABEL=rootfs rootwait rootfstype=squashfs,f2fs
=> mmc write 0x60000000 0x400000 0x...
```

Проще всего использовать `factory.bin`: он содержит ядро и rootfs, готовые к записи в eMMC.
Схема разделов описана в `target/linux/mediatek/dts/mt7987a-glinet-gl-mt5000.dts`
(в разделе `partitions`):

```
0x0        GPT
0x400000   u-boot-env
0x480000   factory     (MAC, ART)
0x880000   fip         (ATF + U-Boot)
0xa80000   cfg
0xc80000   log
0xe80000   kernel
0x2e80000  rootfs
```

## 5. Первое включение

| Параметр | Значение |
|---|---|
| IP роутера | `192.168.8.1/24` |
| DHCP | `192.168.8.100 – 192.168.8.249` |
| Пользователь / пароль | `root` / (пусто) — до первой настройки, как в стоке GL.iNet |
| Имя хоста | `GL-MT5000` |
| WAN | DHCP-клиент, IPv6 выключен (включается вручную) |

Порты в LuCI: `lan1`, `lan2` (коммутатор RTL8366UB) и `eth1` (WAN, внутренний PHY).

## 6. Проверка после прошивки

```bash
ssh root@192.168.8.1
ubus call system board                 # модель и версия
ip -br addr show br-lan                # 192.168.8.1/24
ip -br link show lan1 lan2 eth1        # порты подняты
dmesg | grep -iE "rtl8366|dsa"        # драйвер свитча
ls /sys/class/net | grep -E "lan[12]" # netdev'ы DSA
```

Если `lan1`/`lan2` не появились — смотрите `dmesg | grep -i dsa`: вероятно, не применён
`990-01-net-dsa-realtek-add-rtl8366ub.patch` (нужна ветка с ядром 6.18) либо выбран
не тот вариант свитча.
