[**Русский**](../GLINET-DEFAULTS.md) · **English**

# GL.iNet defaults: what we reproduce

The source of truth is the **official stock GL.iNet firmware for MT5000**:
`mt5000-4.9.0_release1-1053-0708-1783477013.bin`
(SHA256 `e69e440c2715122793e2a4229d1acab3fbcfd193532e9167cd2f4d57bfbfe2d9`,
downloaded from `fw.gl-inet.com/firmware/mt5000/release/`).

You can unpack the image and inspect the defaults with the script:

```bash
./tools/extract-stock-defaults.sh --version 4.9.0
```

It unpacks the squashfs from the image and prints `/etc/board.d/*`, `/etc/uci-defaults/*`,
`/etc/config/{dhcp,firewall,glconfig,gl_led}` and the list of installed packages.

---

## 1. What you need to know about the stock firmware

* The stock 4.x firmware is **not** plain OpenWrt: it has its own UI (gl-sdk4), its own
  package repository, a swconfig switch driver and a pile of proprietary scripts.
  We take the **behaviour and default values** from it, not the code.
* `/etc/config/network` and `/etc/config/wireless` **do not exist** as files in the stock
  firmware: they are generated on first boot (`board.d/*` + `uci-defaults/*`).
  For exactly the same reason we do not ship our own `/etc/config/*` either (otherwise —
  file conflicts with the `dnsmasq`/`firewall4` packages), and apply settings via
  `uci-defaults`.
* The stock firmware uses the **swconfig** RTL8366UB driver (`kmod-rtl8366ub` from
  `feeds/glinet`), while the GL.iNet `mt5000` branch and upstream PR #24237 use
  **in-tree DSA**. That is why the repository has two runtime-configuration variants:
  `config/runtime/dsa` and `config/runtime/swconfig`.

---

## 2. Correspondence table

### Network

| Parameter | Stock GL.iNet 4.9.0 | Our configuration | Where |
|---|---|---|---|
| Router IP (LAN) | `192.168.8.1/24` | same | `config/runtime/*/files/etc/uci-defaults/99_gl-mt5000-defaults` |
| LAN netmask | `255.255.255.0` | same | same place |
| DHCP pool | `start=100 limit=150` → `.100–.249` | same | same place |
| Lease time | `12h` | same | same place |
| `rebind_protection` | `0` (stock changes the OpenWrt default `1` to `0`) | same | same place |
| `domain` / `localise_queries` / `local` | `lan` / `1` / `/lan/` | same | same place |
| `console.gl-inet.com` | resolves to the router IP (IPv4 and `::ffff:<ipv4>`) | same | same place |
| WAN | `proto=dhcp`, `ipv6=0` | same | same place |
| WAN6 | `disabled=1` | same | same place |
| Hostname | `GL-MT5000` (`ucidef_set_hostname "GL-$model"`) | same | same place |
| Timezone | `UTC` / `zonename=UTC` | same | same place |
| `ttylogin` | `1` | same | same place |

### Ports and switch

| Parameter | Stock (swconfig) | Our `dsa` variant | Our `swconfig` variant |
|---|---|---|---|
| LAN1 | `switch0` port `0` | `lan1` (DSA) | `switch0` port `0` |
| LAN2 | `switch0` port `1` | `lan2` (DSA) | `switch0` port `1` |
| CPU port | `17@eth0` | `cpu` (DSA, `gmac0`) | `17@eth0` |
| LAN interface | `eth0.1` | `br-lan` ← `lan1`,`lan2` | `br-lan` ← `eth0.1` |
| WAN | `eth1` (internal 2.5G PHY) | `eth1` | `eth1` |
| `enable_vlan` | `1` (the driver does not actually support VLAN) | — (DSA) | `1` |
| `reset` | `0` | — | `1` |

### MAC addresses

| | Value | Source |
|---|---|---|
| base MAC | `factory` @ `0x4000` | `nvmem-layout` in the DTS, `board.d/02_network` |
| WAN (`gmac1`) | base − 2 | same place |
| LAN (`gmac0`) | base − 1 | same place |

### Firewall

| Rule/zone | Stock | Our configuration |
|---|---|---|
| `defaults` | `input=ACCEPT output=ACCEPT forward=REJECT syn_flood=1` | inherited from `firewall4` |
| `lan` zone | `input/output/forward=ACCEPT` | inherited |
| `wan` zone | `input=REJECT` → changed to `DROP` in `uci-defaults` | `input=DROP` |
| `masq` / `mtu_fix` | `1` / `1` | inherited |
| forwarding | `lan → wan` | inherited |
| `Allow-DHCP-Renew`, `Allow-IGMP`, `Allow-DHCPv6`, `Allow-MLD` | present | inherited |
| `Allow-Ping` | **removed** by the stock firmware | removed |
| `Allow-ICMPv6-Input/Forward` | `echo-request`/`echo-reply` are stripped from the icmp_type list | inherited (echo is allowed) |
| `Allow-IPSec-ESP`, `Allow-ISAKMP` | present | inherited |
| `Support-UDP-Traceroute` | present, `enabled=false` | inherited |

### LEDs

| LED | Stock | Ours |
|---|---|---|
| blue `run` (power) | on | on (DTS `default-state=on`) + duplicated by `init.d/gl-mt5000-led` |
| white `system` | on after boot | turned on by the `init.d/gl-mt5000-led` script |
| white `vpn` | off/on driven by the VPN client | not managed in the base build (needs an `luci-app-*`/script) |

### Packages

The stock 4.9.0 installs ~484 packages, among them:

* **network**: `kmod-swconfig`, `kmod-rtl8366ub`, `kmod-mediatek_hnat`, `kmod-ovpn-dco-v2`, `kmod-ipt-*`, `kmod-nft-*`;
* **VPN**: `openvpn-openssl`, `wireguard-tools`, `amneziawg-tools`, `tailscale`, `zerotier`, `kmod-ovpn-dco-v2`;
* **GL.iNet**: ~100 `gl-sdk4-*` packages (UI, cloud, parental control, DPI, SQM, …);
* **other**: `chrony`, `adguardhome`, `sqm`, `samba4`, `mptun`, `minidlna`, `dnsmasq` (full version).

We take from this list what is available in the upstream feeds (see `config/fragments/`),
and do not pull in `gl-sdk4-*` — they are not in the public feeds; LuCI is used instead.

---

## 3. Where this is implemented in code

| What | File |
|---|---|
| IP/DHCP/hostname/firewall/console.gl-inet.com | `config/runtime/{dsa,swconfig}/files/etc/uci-defaults/99_gl-mt5000-defaults` |
| switch layout (swconfig) | `board.d/02_network`, patch `patches/vanilla/0003s-...-network-swconfig.patch` |
| LEDs | `config/runtime/*/files/etc/init.d/gl-mt5000-led` |
| LAN/WAN ports (DSA) | `patches/vanilla/0003-mediatek-filogic-base-files-add-mt5000-network.patch` |
| LAN/WAN ports (GL.iNet) | `board.d/02_network` in the `mt5000` branch |
| the runtime-configuration package | `scripts/install-runtime.sh` (creates `package/glinet-mt5000-defaults`) |
