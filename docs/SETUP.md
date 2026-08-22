# Setup guide

## 0. What you need

- A Linux host (a Raspberry Pi is easiest) with:
  - a WiFi interface that supports AP mode, which becomes the isolated AP
    (`AP_IFACE`, e.g. `wlan0`),
  - a separate interface with real internet, which provides NAT for your control
    device (`UPLINK_IFACE`, e.g. `eth0`).
- Your printer's WiFi MAC address (in the printer's network menu, or read it off
  the AP once it joins).
- A fake date that is before your cartridge's expiry.

## 1. Configure

```bash
cp config.env.example config.env
vi config.env
```

Set at least `AP_IFACE`, `UPLINK_IFACE`, `AP_SSID`, `AP_PASSPHRASE`, `AP_COUNTRY`
(your regulatory domain), `PRINTER_MAC`, and `FAKE_DATE`. The IP and DHCP defaults
(`192.168.50.0/24`) are fine unless they clash with your uplink network. If your
uplink is also `192.168.50.x`, change `AP_IP`, `AP_SUBNET`, and `DHCP_*`.

## 2. Install

```bash
sudo ./install.sh
```

It renders every config from `config.env`, installs the services, brings up the
AP, and starts serving the fake clock.

If the script fails partway, or your distro isn't Debian-ish enough for it to run,
do the same steps by hand with [MANUAL-SETUP.md](MANUAL-SETUP.md).

## 3. Join the printer

Put the printer onto the `AP_SSID` WiFi, via the printer's setup or the eufyMake
app's "add device" flow. It gets the fixed `PRINTER_IP` and syncs the fake date
right away. Watch it happen:

```bash
journalctl -u eufy-fake-ntp -f      # you should see it request time, served your FAKE_DATE
sudo iw dev <AP_IFACE> station dump  # confirm it is associated and stays associated
```

If the printer's ink now reads OK in the app, the clock bypass is working.

A few things I ran into doing this:

- **Do the switch from the mobile app.** I couldn't find any way to change the
  printer's WiFi from the Windows or Mac desktop app. Only the mobile app exposes
  it, under the printer's settings. Use the phone.
- **Make sure the Pi is fully ready first.** The AP, `dnsmasq`, and the fake-NTP
  service all need to be up before you switch, or the printer joins a network that
  can't answer it yet. After `install.sh` finishes, check the service is running
  (`sudo set-fake-date` shows `service: active`) before you point the printer at
  the new SSID.
- **Give it time, and reboot if it's stubborn.** The printer doesn't always take
  the new time right away. It may only re-poll NTP on its own schedule. If the ink
  still reads expired a few minutes after a successful switch, reboot the printer.
  On the fresh boot it re-syncs from our fake NTP and picks up the date.

## 4. Join your control device (phone / laptop) to the SAME WiFi

This is the part that matters: the app only drives the printer locally when the
control device is on the same WiFi as the printer. On this AP the device still has
internet (via NAT), but the app is nudged into offline/LAN mode, so it reaches the
printer directly over the LAN. That's what makes printing and the plate-camera
snapshot work despite the faked clock.

## Changing the fake date

```bash
sudo set-fake-date "2026-05-04 12:00:00"   # or: sudo set-fake-date 2026-05-04
sudo set-fake-date                         # show current
```

A monthly cron (`/etc/cron.d/eufy-fake-date`) resets it back to your configured
`FAKE_DATE`. Between resets the served time advances in real time, so the printer
sees up to ~1 month of elapsed time. That keeps the date short of the real expiry
while still letting scheduled printer maintenance (head cleaning, etc.) come due,
which a daily reset would prevent by pinning the clock to a single day.

One rule: never serve the real, current time while relying on a cartridge. A
forward jump makes the printer read it as expired within a minute. It's fully
reversible (roll the date back and restart hostapd to force an immediate re-sync),
but don't do it in the first place.

## How it works (one paragraph)

`hostapd` runs the AP. `dnsmasq` gives out DHCP and answers DNS. Every NTP
hostname resolves to this box, where `fake_ntp.py` serves your chosen date.
`nftables` isolates the printer with a MAC-scoped drop of all its internet
traffic, while answering its ping, DNS, and NTP locally and redirecting its cloud
TLS ports to a dead-end sink (`keepalive.py`) so it still believes it's online and
stays connected. Other clients on the AP are NAT'd out the uplink normally. The
vendor cloud domains are both DNS-sinkholed and firewall-dropped. And the app
drops to LAN mode because its connectivity-check domains also resolve to this box.

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

## Getting the printer back to normal (factory reset)

If anything goes sideways, factory-reset the printer. It's the reliable way out.

The catch is that once the printer is on the fake WiFi, the mobile app may not be
able to reach it to change the network back, since the app expects the printer to
be online in the usual way. A factory reset clears the stored WiFi and unbinds the
device, so you can add it again from scratch, either back onto your normal network
or onto this AP.

Use this any time you want to undo the switch, hand the printer to someone else,
or you're just stuck. Steps from eufy:
https://support.eufymake.com/s/article/eufyMake-UV-Printer-E1-Device-Unbinding-Factory-Reset

## Troubleshooting

- **Printer drops off after 30–60s.** Its keepalive isn't satisfied. Check that
  `eufy-keepalive` is running and that the nft `printer_cloud_sink` redirect is
  present (`sudo nft list table ip eufy_iso_nat`). Also confirm its reverse-DNS
  works: `dig +short @<AP_IP> -x <AP_IP>` should return a name, not NXDOMAIN.
- **Ink still reads expired.** The printer hasn't re-synced. `sudo systemctl
  restart hostapd` forces it to re-associate and re-poll NTP. Confirm `FAKE_DATE`
  is before the cartridge expiry.
- **App can't find or control the printer.** The control device has to be on the
  same WiFi (this AP). If it's still using the cloud path, it may not have dropped
  to LAN mode. See the note below.
- **Control device's browsing is partly broken.** The connectivity-check domains
  (`www.google.com`, `www.microsoft.com`, and so on) are redirected to this box on
  purpose, since that's what forces the app offline. General browsing works, those
  specific domains don't while you're on this AP. If your app drops to LAN mode
  without them, you can remove those `address=/www.../` lines from
  `/etc/dnsmasq.d/eufy-timewarp.conf` and run `sudo systemctl restart dnsmasq`. Untested
  though, and it varies by app version.

## Uninstall

```bash
sudo ./uninstall.sh
```
