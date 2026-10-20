# Дефолты GL.iNet: что мы воспроизводим

Источник истины — **официальная стоковая прошивка GL.iNet для MT5000**:
`mt5000-4.9.0_release1-1053-0708-1783477013.bin`
(SHA256 `e69e440c2715122793e2a4229d1acab3fbcfd193532e9167cd2f4d57bfbfe2d9`,
загрузка с `fw.gl-inet.com/firmware/mt5000/release/`).

Распаковать и посмотреть дефолты можно скриптом:

```bash
./tools/extract-stock-defaults.sh --version 4.9.0
```

Он распаковывает squashfs из образа и печатает `/etc/board.d/*`, `/etc/uci-defaults/*`,
`/etc/config/{dhcp,firewall,glconfig,gl_led}` и список установленных пакетов.

---

## 1. Что важно понимать про стоковую прошивку

* Стоковая прошивка 4.x — это **не** OpenWrt в чистом виде: там собственный UI (gl-sdk4),
  свой репозиторий пакетов, swconfig-драйвер свитча и куча собственных скриптов.
  Мы берём из неё **поведение и значения по умолчанию**, а не код.
* `/etc/config/network` и `/etc/config/wireless` в стоке **отсутствуют** как файлы:
  они генерируются при первом запуске (`board.d/*` + `uci-defaults/*`).
  Ровно поэтому и мы не тащим свои `/etc/config/*` (иначе — конфликт файлов с пакетами
  `dnsmasq`/`firewall4`), а применяем настройки через `uci-defaults`.
* Сток использует **swconfig**-драйвер RTL8366UB (`kmod-rtl8366ub` из `feeds/glinet`),
  тогда как ветка GL.iNet `mt5000` и upstream PR #24237 используют **in-tree DSA**.
  Поэтому в репозитории два варианта рантайм-конфига: `config/runtime/dsa` и
  `config/runtime/swconfig`.

---

## 2. Таблица соответствия

### Сеть

| Параметр | Сток GL.iNet 4.9.0 | Наша конфигурация | Где |
|---|---|---|---|
| IP роутера (LAN) | `192.168.8.1/24` | то же | `config/runtime/*/files/etc/uci-defaults/99_gl-mt5000-defaults` |
| Маска LAN | `255.255.255.0` | то же | там же |
| Пул DHCP | `start=100 limit=150` → `.100–.249` | то же | там же |
| Lease time | `12h` | то же | там же |
| `rebind_protection` | `0` (сток меняет дефолт OpenWrt `1` на `0`) | то же | там же |
| `domain` / `localise_queries` / `local` | `lan` / `1` / `/lan/` | то же | там же |
| `console.gl-inet.com` | резолвится в IP роутера (IPv4 и `::ffff:<ipv4>`) | то же | там же |
| WAN | `proto=dhcp`, `ipv6=0` | то же | там же |
| WAN6 | `disabled=1` | то же | там же |
| Хостнейм | `GL-MT5000` (`ucidef_set_hostname "GL-$model"`) | то же | там же |
| Часовой пояс | `UTC` / `zonename=UTC` | то же | там же |
| `ttylogin` | `1` | то же | там же |

### Порты и коммутатор

| Параметр | Сток (swconfig) | Наш вариант `dsa` | Наш вариант `swconfig` |
|---|---|---|---|
| LAN1 | `switch0` порт `0` | `lan1` (DSA) | `switch0` порт `0` |
| LAN2 | `switch0` порт `1` | `lan2` (DSA) | `switch0` порт `1` |
| CPU-порт | `17@eth0` | `cpu` (DSA, `gmac0`) | `17@eth0` |
| LAN-интерфейс | `eth0.1` | `br-lan` ← `lan1`,`lan2` | `br-lan` ← `eth0.1` |
| WAN | `eth1` (внутренний PHY 2.5G) | `eth1` | `eth1` |
| `enable_vlan` | `1` (в реальности драйвер не поддерживает VLAN) | — (DSA) | `1` |
| `reset` | `0` | — | `1` |

### MAC-адреса

| | Значение | Источник |
|---|---|---|
| базовый MAC | `factory` @ `0x4000` | `nvmem-layout` в DTS, `board.d/02_network` |
| WAN (`gmac1`) | base − 2 | там же |
| LAN (`gmac0`) | base − 1 | там же |

### Firewall

| Правило/зона | Сток | Наша конфигурация |
|---|---|---|
| `defaults` | `input=ACCEPT output=ACCEPT forward=REJECT syn_flood=1` | наследуется от `firewall4` |
| зона `lan` | `input/output/forward=ACCEPT` | наследуется |
| зона `wan` | `input=REJECT` → меняется на `DROP` в `uci-defaults` | `input=DROP` |
| `masq` / `mtu_fix` | `1` / `1` | наследуется |
| forwarding | `lan → wan` | наследуется |
| `Allow-DHCP-Renew`, `Allow-IGMP`, `Allow-DHCPv6`, `Allow-MLD` | есть | наследуется |
| `Allow-Ping` | **удаляется** стоком | удаляется |
| `Allow-ICMPv6-Input/Forward` | из списка icmp_type вычищаются `echo-request`/`echo-reply` | наследуется (echo разрешён) |
| `Allow-IPSec-ESP`, `Allow-ISAKMP` | есть | наследуется |
| `Support-UDP-Traceroute` | есть, `enabled=false` | наследуется |

### Светодиоды

| LED | Сток | У нас |
|---|---|---|
| синий `run` (питание) | горит | горит (DTS `default-state=on`) + дублируется в `init.d/gl-mt5000-led` |
| белый `system` | горит после загрузки | включается скриптом `init.d/gl-mt5000-led` |
| белый `vpn` | гаснет/горится от VPN-клиента | в базовой сборке не управляется (нужен `luci-app-*`/скрипт) |

### Пакеты

Стоковая 4.9.0 ставит ~484 пакета, из них:

* **сеть**: `kmod-swconfig`, `kmod-rtl8366ub`, `kmod-mediatek_hnat`, `kmod-ovpn-dco-v2`, `kmod-ipt-*`, `kmod-nft-*`;
* **VPN**: `openvpn-openssl`, `wireguard-tools`, `amneziawg-tools`, `tailscale`, `zerotier`, `kmod-ovpn-dco-v2`;
* **GL.iNet**: ~100 пакетов `gl-sdk4-*` (UI, cloud, parental control, DPI, SQM, …);
* **прочее**: `chrony`, `adguardhome`, `sqm`, `samba4`, `mptun`, `minidlna`, `dnsmasq` (полная версия).

Мы берём из этого списка то, что есть в upstream-фидах (см. `config/fragments/`),
и не тащим `gl-sdk4-*` — их нет в публичных фидах, вместо них используется LuCI.

---

## 3. Где в коде это реализовано

| Что | Файл |
|---|---|
| IP/DHCP/hostname/firewall/console.gl-inet.com | `config/runtime/dsa/files/etc/uci-defaults/99_gl-mt5000-defaults` |
| то же для swconfig | `config/runtime/swconfig/files/etc/uci-defaults/99_gl-mt5000-defaults` |
| раскладка коммутатора (swconfig) | `config/runtime/swconfig/files/etc/uci-defaults/98_gl-mt5000-switch` |
| LED | `config/runtime/*/files/etc/init.d/gl-mt5000-led` |
| порты LAN/WAN (DSA) | `patches/vanilla/0003-mediatek-filogic-base-files-add-mt5000-network.patch` |
| порты LAN/WAN (GL.iNet) | `board.d/02_network` в ветке `mt5000` |
| пакет с рантайм-конфигом | `scripts/install-runtime.sh` (создаёт `package/glinet-mt5000-defaults`) |
