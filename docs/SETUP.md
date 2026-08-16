# Setup guide

## 0. What you need

- A Linux host (Raspberry Pi recommended) with:
  - a **WiFi interface** that supports AP mode → becomes the isolated AP (`AP_IFACE`, e.g. `wlan0`),
  - a separate interface **with real internet** → provides NAT for your control device (`UPLINK_IFACE`, e.g. `eth0`).
- Your **printer's WiFi MAC address** (in the printer's network menu, or read it off the AP once it joins).
- A **fake date** that is *before* your cartridge's expiry.

## 1. Configure

```bash
cp config.env.example config.env
nano config.env
```

Set at least: `AP_IFACE`, `UPLINK_IFACE`, `AP_SSID`, `AP_PASSPHRASE`,
`AP_COUNTRY` (your regulatory domain), `PRINTER_MAC`, and `FAKE_DATE`. The IP/DHCP
defaults (`192.168.50.0/24`) are fine unless they clash with your uplink network —
if your uplink is also `192.168.50.x`, change `AP_IP`/`AP_SUBNET`/`DHCP_*`.

## 2. Install

```bash
sudo ./install.sh
```

It renders every config from `config.env`, installs the services, brings up the
AP, and starts serving the fake clock.

## 3. Join the printer

Put the printer onto the `AP_SSID` WiFi (via the printer's setup / the eufyMake
app's "add device" flow). It will get the fixed `PRINTER_IP` and immediately sync
the fake date. Watch it happen:

```bash
journalctl -u eufy-fake-ntp -f      # you should see it request time, served your FAKE_DATE
sudo iw dev <AP_IFACE> station dump  # confirm it is associated and stays associated
```

If the printer's ink now reads OK in the app, the clock bypass is working.

## 4. Join your control device (phone / laptop) to the SAME WiFi

This is the important bit: **the app only drives the printer locally when the
control device is on the same WiFi as the printer.** On this AP the device still
has internet (via NAT), but the app is nudged into offline/LAN mode, so it reaches
the printer directly over the LAN — which is what makes printing and the
plate-camera snapshot work despite the faked clock.

## Changing the fake date

```bash
sudo set-fake-date "2026-05-04 12:00:00"   # or: sudo set-fake-date 2026-05-04
sudo set-fake-date                         # show current
```

A daily cron (`/etc/cron.d/eufy-fake-date`) resets it to your configured
`FAKE_DATE` so it never drifts forward toward the real expiry.

**Rule:** never serve the real/current time while relying on a cartridge — a
forward jump makes the printer read it as expired within a minute. It is fully
reversible (roll the date back and restart hostapd to force an immediate re-sync),
but avoid it.

## How it works (one paragraph)

`hostapd` runs the AP; `dnsmasq` gives out DHCP and answers DNS. Every NTP
hostname resolves to this box, where `fake_ntp.py` serves your chosen date.
`nftables` isolates the printer (a MAC-scoped drop of all its internet traffic)
while answering its ping/DNS/NTP locally and redirecting its cloud TLS ports to a
dead-end sink (`keepalive.py`) so it still believes it is online and stays
connected. Other clients on the AP are NAT'd out the uplink normally. The vendor
cloud domains are both DNS-sinkholed and firewall-dropped. The app is pushed to
LAN mode because its connectivity-check domains also resolve to this box.

## Verify

```bash
# printer served the fake date, and stays associated:
journalctl -u eufy-fake-ntp -f
sudo iw dev <AP_IFACE> station dump | grep -A2 <PRINTER_MAC>

# printer is truly isolated (this counter climbs = its internet is being dropped):
sudo nft list chain inet eufy_iso forward | grep printer_out_drop

# NTP hostnames resolve to the box, cloud is sinkholed:
dig +short @<AP_IP> pool.ntp.org        # -> <AP_IP>
dig +short @<AP_IP> ankermake.com       # -> 0.0.0.0
```

## Troubleshooting

- **Printer drops off after ~30-60s.** Its keepalive isn't satisfied. Check
  `eufy-keepalive` is running and that the nft `printer_cloud_sink` redirect is
  present (`sudo nft list table ip eufy_iso_nat`). Also confirm its reverse-DNS
  works: `dig +short @<AP_IP> -x <AP_IP>` should return a name, not NXDOMAIN.
- **Ink still reads expired.** The printer hasn't re-synced. `sudo systemctl
  restart hostapd` forces it to re-associate and re-poll NTP. Confirm `FAKE_DATE`
  is before the cartridge expiry.
- **App can't find / control the printer.** The control device must be on the
  **same** WiFi (this AP). If it still uses the cloud path, it may not have
  dropped to LAN mode — see note below.
- **Control device's browsing partly broken.** The connectivity-check domains
  (`www.google.com`, `www.microsoft.com`, ...) are redirected to this box on
  purpose (that's what forces the app offline). General browsing works; those
  specific domains don't while on this AP. If your app drops to LAN mode without
  them, you can remove those `address=/www.../` lines from
  `/etc/dnsmasq.d/eufy-iso.conf` and `sudo systemctl restart dnsmasq` — untested,
  varies by app version.

## Uninstall

```bash
sudo ./uninstall.sh
```
