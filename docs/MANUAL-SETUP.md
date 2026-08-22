# Manual setup (when `install.sh` won't run)

`install.sh` just renders the templates and starts a few services. If it fails
partway, or your distro isn't close enough to Debian for it to work, you can do
the same steps by hand. This walks through exactly what the installer does, in the
same order, so you can run one line at a time and see where it breaks.

Run everything as root (`sudo -i`), from the repo directory. Fill in `config.env`
first, the same as the scripted path.

## 1. Load your config and a render helper

The templates use `@VAR@` placeholders. Source your config, then define the same
substitution the installer uses so you can render each file with one command.

```bash
set -a; source ./config.env; set +a

# dotted-decimal netmask from AP_CIDR (used by dnsmasq)
AP_NETMASK=$(( 0xffffffff ^ ((1 << (32 - AP_CIDR)) - 1) ))
AP_NETMASK="$(( (AP_NETMASK>>24)&255 )).$(( (AP_NETMASK>>16)&255 )).$(( (AP_NETMASK>>8)&255 )).$(( AP_NETMASK&255 ))"

render() {   # render <template> <dest> [mode]
    sed -e "s|@AP_IFACE@|$AP_IFACE|g" -e "s|@UPLINK_IFACE@|$UPLINK_IFACE|g" \
        -e "s|@AP_SSID@|$AP_SSID|g" -e "s|@AP_PASSPHRASE@|$AP_PASSPHRASE|g" \
        -e "s|@AP_COUNTRY@|$AP_COUNTRY|g" -e "s|@AP_CHANNEL@|$AP_CHANNEL|g" \
        -e "s|@AP_IP@|$AP_IP|g" -e "s|@AP_CIDR@|$AP_CIDR|g" -e "s|@AP_SUBNET@|$AP_SUBNET|g" \
        -e "s|@AP_NETMASK@|$AP_NETMASK|g" \
        -e "s|@DHCP_START@|$DHCP_START|g" -e "s|@DHCP_END@|$DHCP_END|g" \
        -e "s|@PRINTER_MAC@|$PRINTER_MAC|g" -e "s|@PRINTER_IP@|$PRINTER_IP|g" \
        -e "s|@FAKE_DATE@|$FAKE_DATE|g" "$1" > "$2"
    [[ -n "${3:-}" ]] && chmod "$3" "$2"
}
```

If you'd rather not use the helper, you can open each template, replace the
`@VAR@` names with your values by hand, and save it to the destination path shown
below. The helper just does that for you.

## 2. Packages

```bash
apt-get update
apt-get install -y hostapd dnsmasq python3 nftables
```

Not on Debian/apt? Install the same four packages with your package manager
(`hostapd`, `dnsmasq`, `python3`, `nftables`).

## 3. The scripts

```bash
install -d /usr/local/lib/eufy-timewarp
install -m 755 bin/fake_ntp.py   /usr/local/lib/eufy-timewarp/fake_ntp.py
install -m 755 bin/keepalive.py  /usr/local/lib/eufy-timewarp/keepalive.py
install -m 755 bin/set-fake-date /usr/local/bin/set-fake-date
```

## 4. Access point (hostapd)

```bash
install -d /etc/hostapd
render templates/hostapd.conf.tmpl /etc/hostapd/hostapd.conf 600
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd
```

## 5. AP interface IP (systemd-networkd)

```bash
install -d /etc/systemd/network
render templates/ap.network.tmpl /etc/systemd/network/20-eufy-ap.network 644
systemctl enable systemd-networkd
```

If NetworkManager is running, keep it off the AP interface, otherwise it fights
hostapd and the static IP:

```bash
install -d /etc/NetworkManager/conf.d
render templates/nm-unmanaged.conf.tmpl /etc/NetworkManager/conf.d/99-eufy-unmanaged.conf 644
```

## 6. DHCP + DNS (dnsmasq)

```bash
render templates/dnsmasq-eufy.conf.tmpl /etc/dnsmasq.d/eufy-timewarp.conf 644
```

## 7. Fake NTP + keepalive services

```bash
render templates/eufy-fake-ntp.default.tmpl /etc/default/eufy-fake-ntp 644
install -m 644 systemd/eufy-fake-ntp.service  /etc/systemd/system/eufy-fake-ntp.service
install -m 644 systemd/eufy-keepalive.service /etc/systemd/system/eufy-keepalive.service
```

## 8. Monthly fake-date reset (cron)

```bash
render templates/eufy-fake-date.cron.tmpl /etc/cron.d/eufy-fake-date 644
```

## 9. Firewall / NAT (nftables) + IP forwarding

```bash
render templates/eufy.nft.tmpl /etc/nftables.conf 755
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-eufy-timewarp.conf
sysctl -w net.ipv4.ip_forward=1
nft -c -f /etc/nftables.conf      # syntax check; should print nothing
```

## 10. Enable and start everything

```bash
systemctl daemon-reload
systemctl enable nftables
systemctl restart systemd-networkd
nft -f /etc/nftables.conf
ip addr replace "$AP_IP/$AP_CIDR" dev "$AP_IFACE"
systemctl enable --now eufy-fake-ntp eufy-keepalive
systemctl enable hostapd
systemctl restart hostapd
systemctl restart dnsmasq
```

## 11. Check it came up

```bash
systemctl is-active hostapd dnsmasq eufy-fake-ntp eufy-keepalive   # all "active"
ip addr show "$AP_IFACE" | grep "$AP_IP"                           # the AP has its IP
journalctl -u eufy-fake-ntp -f                                     # serves FAKE_DATE
```

From here, follow [SETUP.md](SETUP.md) from step 3 (join the printer) onward. The
verify and troubleshooting sections there apply the same whether you installed by
hand or with the script.

## Undo

The same manual removal as `uninstall.sh`: stop and disable the services, delete
the files listed above, flush nftables (`nft flush ruleset`), and set
`net.ipv4.ip_forward=0`. Or just run `sudo ./uninstall.sh` if that part works.
