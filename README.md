# eufy-timewarp: isolated network for a eufyMake E1 UV printer

A small access point you set up on a Raspberry Pi, or any Debian-ish Linux with
a WiFi card. It lets you keep using ink cartridges the printer would otherwise
reject as "expired", by controlling the one thing that check depends on: the
printer's clock.

> For your own device, on your own network. All this does is change what time the
> printer is told, and keep it off the vendor cloud.

**Status:** working proof-of-concept, not an actively maintained project. It runs
on my setup; it's shared so others can build on it. Issues and pull requests are
welcome, see [Status & contributing](#status--contributing).

## Disclaimer

This is documentation of my own research on my own hardware. I am not affiliated
with Anker, eufyMake, or any of their partners. Nothing here is endorsed by them,
and everything here will probably stop working the moment they decide it should.

### The ink itself

This bypasses the expiry check. It does not do anything to the ink.

UV ink is not just dye in a bottle. The pigments settle, the resin can thicken,
and both of those can clog a printhead. White is the worst offender. An expiry
date on UV ink is not purely a business decision; there is real chemistry behind
it, even if the enforcement mechanism is a business decision.

So: shake the cartridge before use, run a nozzle check afterwards, and think twice
about ink that is years rather than weeks past date. A printhead costs
considerably more than a cartridge. My own ink was days past its date when I
tested this, which is a very different situation from ink that has been sitting in
a drawer since 2024.

### Why I'm publishing it anyway

Because I think that decision is mine to make.

Telling me my ink may be past its best is information, and I'd genuinely like to
have it. Preventing my printer from using ink I already paid for is not a safety
feature. It's a business model wearing a safety feature's clothes. A date-based
lockout doesn't measure whether the ink is actually bad. It measures whether a
number has been passed.

I bought the printer. I bought the ink. I'll take the risk, and I'll take the
consequences.

### Which means, plainly

Use this at your own risk. If you clog a printhead, damage your printer, ruin a
print job, or void your warranty, that is on you, not on me. I am not responsible
for any damage, loss, or cost arising from anything in this repository. No
warranty of any kind, express or implied.

If you are not comfortable with that, buy fresh ink. That is a completely
reasonable choice and I won't argue with it.

### What this is not

No cryptography was broken. No cartridge chip was modified, reset, or
reverse-engineered. No firmware was patched. The cartridges in my tests were never
physically touched. This is a network configuration exercise on hardware I own.

## What it does

The E1 decides a cartridge is expired by comparing the cartridge's stored expiry
date against its own system clock, which it sets from NTP at boot. This repo sets
up a WiFi network that becomes the printer's entire world:

- a fake NTP server hands the printer a date you pick, before the expiry, so
  full-but-"expired" cartridges read as valid;
- the printer is cut off from the internet and the vendor cloud, but kept
  "believing it's online" so it stays connected and prints normally;
- any control device you also join to this WiFi keeps its internet and drives the
  printer locally.

## Key findings (from the investigation)

- **The check is just the printer's clock against the cartridge chip.** Roll the
  clock back and the cartridge reads valid. The cloud has no say in the decision.
- **It's a live check, and nothing is written to the cartridge.** Set the clock
  forward and it reads expired. Set it back and it's valid again. A wrong-time
  reading does no permanent damage. So never let the printer see the real time
  while you're relying on a cartridge. A daily cron keeps the fake date pinned.
- **Printing and the plate-camera snapshot work** with the faked clock, as long as
  the control device is on the same WiFi as the printer, so the app talks to it
  locally (LAN mode). Over the cloud the same actions fail, because the faked clock
  breaks the cloud's time-signed requests.
- **The cloud can't be intercepted or spoofed.** The printer validates the cloud's
  TLS cert and the cloud uses mutual TLS, so isolation is done by blocking, not by
  faking a cloud.
- **The printer fights isolation.** It pings `8.8.8.8`, runs HTTP reachability
  probes, and dials cloud IPs it has cached. So isolation is enforced at the
  firewall with a MAC-scoped drop, while its ping, DNS, and NTP are answered
  locally and its cloud TLS ports go to a dead-end sink so it stays associated.

## Quick start

```bash
cp config.env.example config.env
vi config.env          # edit the few flags that matter (see below)
sudo ./install.sh
```

Then join both the printer and your control device to the SSID. Full walkthrough
and how-it-works: **[docs/SETUP.md](docs/SETUP.md)**.

## Configuration: what actually needs changing

On a stock Raspberry Pi (built-in `wlan0` + `eth0`) with a stock E1, almost
everything in `config.env` already works at its default. You really only need to
set three things, plus one you should set for legal reasons:

| Flag | Set it? | Why |
|---|---|---|
| **`AP_PASSPHRASE`** | Required | The WiFi password for the AP. The default is a placeholder, so change it or your printer's network is wide open. 8–63 characters. |
| **`PRINTER_MAC`** | Required | Tells the firewall which client to isolate, so the printer gets cut off and your control device doesn't. Use the printer's own MAC (lowercase, colons). See below for where to find it. |
| **`FAKE_DATE`** | Required | A date before your cartridge's expiry. Keep the quotes. |
| **`AP_COUNTRY`** | Recommended | Your 2-letter regulatory domain (`US`, `DE`, `GB`, `AT`, …). This keeps the WiFi radio's channels and power legal for where you are. Set it to your country. |

Leave the rest alone unless it clashes with your setup:

- **`AP_IFACE` / `UPLINK_IFACE`** default to `wlan0` (the AP) and `eth0` (real
  internet). That's right for a standard Pi. Change them only if your interfaces
  are named differently.
- **`AP_SSID`, `AP_CHANNEL`** are cosmetic and fine at their defaults (`eufy-lab`,
  channel 6).
- **The IP block** (`AP_IP`, `AP_SUBNET`, `DHCP_*`, `PRINTER_IP`) is fine at
  `192.168.50.0/24`, unless your uplink network is also `192.168.50.x`. If it is,
  pick a different subnet to avoid the clash.

### Finding your printer's MAC address (`PRINTER_MAC`)

In the eufyMake app, open your E1, go to the device settings (the gear icon), then
Device Info / Network. The WiFi MAC address is listed there next to the IP.

Can't find it in the app? Read it off the AP after the printer joins instead.
Bring the AP up once with any placeholder MAC, join the printer, then run
`sudo iw dev wlan0 station dump` and note the associated station's MAC. Put that
value into `PRINTER_MAC` and re-run `sudo ./install.sh`.

## Requirements

- A Linux box with two network paths: one WiFi interface for the AP (`AP_IFACE`)
  and one interface with real internet for the control device's NAT
  (`UPLINK_IFACE`). A Raspberry Pi with built-in WiFi and Ethernet is ideal.
- `hostapd`, `dnsmasq`, `python3`, `nftables`. The installer pulls what's missing.
- systemd. Tested on Debian 12 / Raspberry Pi OS.

## Layout

```
config.env.example   all the knobs (copy to config.env)
install.sh           render + install + start
uninstall.sh         remove and revert
templates/           hostapd, dnsmasq, nftables, networkd, cron (with @VARS@)
bin/                 fake_ntp.py, keepalive.py, set-fake-date
systemd/             the two service units
docs/SETUP.md        step-by-step + how it works + verify + troubleshoot
docs/MANUAL-SETUP.md do it by hand if install.sh won't run
```

## Status & contributing

This is a proof-of-concept. It works on my hardware and my network, and I'm
publishing it so other people can use it as a starting point, not because it's a
finished or supported product. Treat it as something to improve, not something
that's already polished.

Issues and pull requests are welcome:

- bug reports, especially with the specific error, your distro, and your hardware
- fixes and improvements to the scripts or docs
- notes on other setups (different Pi models, WiFi adapters, non-Debian Linux)
- new findings about how the printer behaves

Fair warning: I maintain this on a best-effort basis, so replies and reviews may
be slow, and I might not get to everything. If a PR sits for a while, that's the
reason, not a no.

One thing I'll ask: keep it in the same spirit as the rest of the repo. This is
about your own device on your own network, framed as research. Please don't turn
it into anything that targets other people's hardware or breaks something you
don't own.

## License

MIT. See [LICENSE](LICENSE). No warranty; see the disclaimer above for the risks
specific to this project.
