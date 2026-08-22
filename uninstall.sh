#!/usr/bin/env bash
# Remove eufy-timewarp and return the machine to a plain host. Does not uninstall the
# hostapd/dnsmasq packages (apt remove them yourself if you want).
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo: sudo ./uninstall.sh"; exit 1; }

echo "==> stopping services"
systemctl disable --now eufy-fake-ntp eufy-keepalive hostapd dnsmasq 2>/dev/null || true

echo "==> removing files"
rm -f /etc/systemd/system/eufy-fake-ntp.service /etc/systemd/system/eufy-keepalive.service
rm -f /etc/default/eufy-fake-ntp /etc/dnsmasq.d/eufy-timewarp.conf
rm -f /etc/systemd/network/20-eufy-ap.network
rm -f /etc/NetworkManager/conf.d/99-eufy-unmanaged.conf
rm -f /etc/cron.d/eufy-fake-date /etc/sysctl.d/99-eufy-timewarp.conf
rm -f /etc/hostapd/hostapd.conf
rm -rf /usr/local/lib/eufy-timewarp /usr/local/bin/set-fake-date

echo "==> flushing firewall + forwarding"
nft flush ruleset 2>/dev/null || true
: > /etc/nftables.conf 2>/dev/null || true
sysctl -q -w net.ipv4.ip_forward=0 2>/dev/null || true

systemctl daemon-reload
systemctl reload NetworkManager 2>/dev/null || true
systemctl restart systemd-networkd 2>/dev/null || true
echo "Done. Re-run ./install.sh to bring it back."
