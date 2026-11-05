[**Русский**](../FLASHING.md) · **English**

# Flashing the GL-MT5000

## 1. What gets built

`build/…/out/` contains:

| File | Purpose |
|---|---|
| `openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin` | regular upgrade via the web UI / `sysupgrade` |
| `openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-factory.bin` | full image for U-Boot recovery (written to eMMC) |
| `config-*.config`, `config-*.config.buildinfo`, `SHA256SUMS`, `build-info.txt` | build configuration and metadata |

Integrity check:

```bash
cd build/out && sha256sum -c SHA256SUMS
```

## 2. Upgrading from the stock GL.iNet firmware

The stock firmware (4.x) and OpenWrt use **different** upgrade mechanisms, so:

1. Download the stock GL.iNet firmware for MT5000 (4.9.0) from
   [dl.gl-inet.com/router/mt5000/stable](https://dl.gl-inet.com/router/mt5000/stable).
2. Flash it through the GL.iNet web UI (**mandatory** step — it brings the eMMC
   partition layout and U-Boot to the scheme OpenWrt expects).
3. After the reboot, flash the OpenWrt image: web UI → **System → Upgrade**, or over SSH:

```bash
scp openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin root@192.168.8.1:/tmp/
ssh root@192.168.8.1
cd /tmp && sysupgrade -n openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin
```

> The `-n` flag (do not save configuration) is mandatory when moving from the stock
> firmware: the `/etc/config` formats differ, and a carried-over configuration may bring
> up the wrong network.

## 3. Upgrading from OpenWrt to OpenWrt

```bash
sysupgrade openwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin
```

The configuration is preserved, but when switching the switch variant
(`dsa` ↔ `swconfig`) it is better to reset it: `sysupgrade -n`.

## 4. Recovery via U-Boot (factory image)

Connect UART (3.3 V TTL, 115200 8N1: GND-TX-RX) and drop into U-Boot:

```
=> setenv bootargs console=ttyS0,115200n8 root=PARTLABEL=rootfs rootwait rootfstype=squashfs,f2fs
=> mmc write 0x60000000 0x400000 0x...
```

The easiest route is `factory.bin`: it contains a kernel and rootfs ready to be written
to eMMC. The partition layout is described in
`target/linux/mediatek/dts/mt7987a-glinet-gl-mt5000.dts` (in the `partitions` node):

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

## 5. First power-on

| Parameter | Value |
|---|---|
| Router IP | `192.168.8.1/24` |
| DHCP | `192.168.8.100 – 192.168.8.249` |
| User / password | `root` / (empty) — until first setup, same as stock GL.iNet |
| Hostname | `GL-MT5000` |
| WAN | DHCP client, IPv6 disabled (enable it manually) |

Ports in LuCI: `lan1`, `lan2` (RTL8366UB switch) and `eth1` (WAN, internal PHY).

## 6. Checks after flashing

```bash
ssh root@192.168.8.1
ubus call system board                 # model and version
ip -br addr show br-lan                # 192.168.8.1/24
ip -br link show lan1 lan2 eth1        # ports are up
dmesg | grep -iE "rtl8366|dsa"        # switch driver
ls /sys/class/net | grep -E "lan[12]" # DSA netdevs
```

If `lan1`/`lan2` did not appear, look at `dmesg | grep -i dsa`: most likely
`990-01-net-dsa-realtek-add-rtl8366ub.patch` was not applied (a kernel-6.18 branch is
required) or the wrong switch variant was selected.
