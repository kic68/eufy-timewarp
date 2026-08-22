#!/usr/bin/env bash
# eufy-timewarp installer. Reads config.env, renders the templates, installs
# everything, and starts the isolated AP. Re-runnable (idempotent-ish).
#
# NOTE: if this script fails partway, or your distro isn't Debian-ish enough for
# it to work, you can do every step by hand. docs/MANUAL-SETUP.md walks through
# the exact same steps in the same order, one command at a time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo ./install.sh"; exit 1; }
[[ -f "$HERE/config.env" ]] || { echo "Missing config.env. Copy config.env.example to config.env and edit it."; exit 1; }
set -a; # shellcheck disable=SC1091
source "$HERE/config.env"; set +a

# --- validate ---------------------------------------------------------------
for v in AP_IFACE UPLINK_IFACE AP_SSID AP_PASSPHRASE AP_COUNTRY AP_CHANNEL \
         AP_IP AP_CIDR AP_SUBNET DHCP_START DHCP_END PRINTER_MAC PRINTER_IP FAKE_DATE; do
    [[ -n "${!v:-}" ]] || { echo "config.env: $v is not set"; exit 1; }
done
[[ ${#AP_PASSPHRASE} -ge 8 && ${#AP_PASSPHRASE} -le 63 ]] || { echo "AP_PASSPHRASE must be 8-63 chars"; exit 1; }
[[ "$PRINTER_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || { echo "PRINTER_MAC looks wrong: $PRINTER_MAC"; exit 1; }
ip link show "$AP_IFACE" >/dev/null 2>&1 || { echo "AP_IFACE '$AP_IFACE' not found"; exit 1; }
ip link show "$UPLINK_IFACE" >/dev/null 2>&1 || { echo "UPLINK_IFACE '$UPLINK_IFACE' not found"; exit 1; }

# derive the dotted-decimal netmask from AP_CIDR (for dnsmasq's dhcp-range)
[[ "$AP_CIDR" =~ ^[0-9]+$ && "$AP_CIDR" -ge 1 && "$AP_CIDR" -le 32 ]] || { echo "AP_CIDR must be 1-32: $AP_CIDR"; exit 1; }
AP_NETMASK=$(( 0xffffffff ^ ((1 << (32 - AP_CIDR)) - 1) ))
AP_NETMASK="$(( (AP_NETMASK >> 24) & 255 )).$(( (AP_NETMASK >> 16) & 255 )).$(( (AP_NETMASK >> 8) & 255 )).$(( AP_NETMASK & 255 ))"

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

echo "==> packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq hostapd dnsmasq python3 >/dev/null

echo "==> scripts"
install -d /usr/local/lib/eufy-timewarp
install -m 755 "$HERE/bin/fake_ntp.py"  /usr/local/lib/eufy-timewarp/fake_ntp.py
install -m 755 "$HERE/bin/keepalive.py" /usr/local/lib/eufy-timewarp/keepalive.py
install -m 755 "$HERE/bin/set-fake-date" /usr/local/bin/set-fake-date

echo "==> access point (hostapd)"
install -d /etc/hostapd
render "$HERE/templates/hostapd.conf.tmpl" /etc/hostapd/hostapd.conf 600
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
systemctl unmask hostapd >/dev/null 2>&1 || true

echo "==> AP interface IP (systemd-networkd)"
install -d /etc/systemd/network
render "$HERE/templates/ap.network.tmpl" /etc/systemd/network/20-eufy-ap.network 644
systemctl enable systemd-networkd >/dev/null 2>&1 || true
# if NetworkManager is present, keep it off the AP interface
if systemctl list-unit-files | grep -q '^NetworkManager\.service'; then
    install -d /etc/NetworkManager/conf.d
    render "$HERE/templates/nm-unmanaged.conf.tmpl" /etc/NetworkManager/conf.d/99-eufy-unmanaged.conf 644
    echo "   NetworkManager detected -> AP interface set unmanaged"
fi

echo "==> DHCP + DNS (dnsmasq)"
render "$HERE/templates/dnsmasq-eufy.conf.tmpl" /etc/dnsmasq.d/eufy-timewarp.conf 644

echo "==> fake NTP + keepalive services"
render "$HERE/templates/eufy-fake-ntp.default.tmpl" /etc/default/eufy-fake-ntp 644
install -m 644 "$HERE/systemd/eufy-fake-ntp.service"  /etc/systemd/system/eufy-fake-ntp.service
install -m 644 "$HERE/systemd/eufy-keepalive.service" /etc/systemd/system/eufy-keepalive.service

echo "==> daily fake-date reset (cron)"
render "$HERE/templates/eufy-fake-date.cron.tmpl" /etc/cron.d/eufy-fake-date 644

echo "==> firewall/NAT (nftables) + IP forwarding"
render "$HERE/templates/eufy.nft.tmpl" /etc/nftables.conf 755
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-eufy-timewarp.conf
sysctl -q -w net.ipv4.ip_forward=1
nft -c -f /etc/nftables.conf

echo "==> enable + start everything"
systemctl daemon-reload
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart systemd-networkd
nft -f /etc/nftables.conf
ip addr replace "$AP_IP/$AP_CIDR" dev "$AP_IFACE" 2>/dev/null || true
systemctl enable --now eufy-fake-ntp eufy-keepalive >/dev/null
systemctl enable hostapd >/dev/null 2>&1 || true
systemctl restart hostapd
systemctl restart dnsmasq

echo
echo "Done. SSID '$AP_SSID' is up on $AP_IFACE ($AP_IP)."
echo "  fake date : $FAKE_DATE   (change: sudo set-fake-date \"YYYY-MM-DD HH:MM:SS\")"
echo "  watch NTP : journalctl -u eufy-fake-ntp -f"
echo "  printer   : pinned to $PRINTER_IP (MAC $PRINTER_MAC)"
echo "Join the printer AND your control device to '$AP_SSID'. See docs/SETUP.md."
