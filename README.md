# eufy-iso — isolated network for a eufyMake E1 UV printer

A small, self-contained access point (built on a Raspberry Pi / any Debian-ish
Linux with a WiFi interface) that lets you keep using ink cartridges the printer
would otherwise reject as "expired", by controlling the one thing that check
depends on: **the printer's clock**.

> For your own device, on your own network. This just changes what time the
> printer is told and keeps it off the vendor cloud.

## What it does

The E1 decides a cartridge is expired by comparing the cartridge's stored expiry
date against **its own system clock**, which it sets from NTP at boot. This repo
stands up a WiFi network that is the printer's entire world:

- a **fake NTP server** hands the printer a date you choose (before the expiry),
  so full-but-"expired" cartridges read as valid;
- the printer is **fully isolated** from the internet/vendor cloud, but kept
  "believing it is online" so it stays connected and prints normally;
- **any control device you also join to this WiFi keeps its internet** and drives
  the printer locally.

## Key findings (from the investigation)

- **The expiry check is purely the printer's clock vs. the cartridge chip.** Roll
  the clock back → the cartridge reads valid. No cloud involved in the decision.
- **It is a live check, fully reversible — nothing is written to the cartridge.**
  Set the clock forward → it reads expired; set it back → valid again. A wrong-time
  reading does no permanent damage. (So: never let the printer see the *real* time
  while relying on a cartridge — a daily cron keeps the fake date pinned.)
- **Printing and the plate-camera snapshot work** with the faked clock — as long
  as the **control device is on the same WiFi** as the printer, so the app talks
  to it **locally** (LAN mode). Over the cloud the same actions fail, because the
  faked clock breaks the cloud's time-signed requests.
- **The cloud can't be intercepted or spoofed:** the printer validates the cloud's
  TLS cert and the cloud uses mutual TLS, so isolation is done by *blocking*, not
  by faking a cloud.
- **The printer fights isolation** — it pings `8.8.8.8`, does HTTP reachability
  probes, and dials cloud IPs it has cached — so isolation is enforced at the
  firewall (a MAC-scoped drop), with its ping/DNS/NTP answered locally and its
  cloud TLS ports sent to a dead-end sink so it stays associated.

## Quick start

```bash
cp config.env.example config.env
nano config.env          # set your interfaces, SSID/passphrase, printer MAC, fake date
sudo ./install.sh
```

Then join **both** the printer and your control device to the SSID. Full
walkthrough and how-it-works: **[docs/SETUP.md](docs/SETUP.md)**.

## Requirements

- A Linux box with **two network paths**: one WiFi interface for the AP
  (`AP_IFACE`) and one interface with real internet for the control device's NAT
  (`UPLINK_IFACE`). A Raspberry Pi with built-in WiFi + Ethernet is ideal.
- `hostapd`, `dnsmasq`, `python3`, `nftables` (the installer pulls what's missing).
- systemd. Debian 12 / Raspberry Pi OS tested.

## Layout

```
config.env.example   all the knobs (copy to config.env)
install.sh           render + install + start
uninstall.sh         remove and revert
templates/           hostapd, dnsmasq, nftables, networkd, cron (with @VARS@)
bin/                 fake_ntp.py, keepalive.py, set-fake-date
systemd/             the two service units
docs/SETUP.md        step-by-step + how it works + verify + troubleshoot
```

Nothing here is committed with real values — `config.env` is git-ignored.
