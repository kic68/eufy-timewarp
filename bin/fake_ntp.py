#!/usr/bin/env python3
"""Minimal fake NTP server.

Answers every NTP request with a configurable date instead of the real time,
so a client that syncs from it believes it is that date. Reads config from the
environment (see the eufy-fake-ntp systemd unit / /etc/default/eufy-fake-ntp):

    FAKE_DATE  the date to serve, "YYYY-MM-DD HH:MM:SS", interpreted as UTC
    BIND       address to listen on (default 0.0.0.0)
    PORT       UDP port (default 123)

The served time advances in real time from FAKE_DATE. It never touches the host
clock. The critical detail is echoing the client's transmit timestamp back into
the originate field, or NTP clients discard the reply.
"""
import socket, struct, time, os

NTP_EPOCH = 2208988800
FAKE_DATE = os.environ.get("FAKE_DATE", "2026-05-04 00:00:00")
PORT = int(os.environ.get("PORT", "123"))
BIND = os.environ.get("BIND", "0.0.0.0")

fake_base = time.mktime(time.strptime(FAKE_DATE, "%Y-%m-%d %H:%M:%S"))
real_base = time.time()


def to_ntp(ts):
    n = ts + NTP_EPOCH
    s = int(n)
    return s, int((n - s) * (2 ** 32))


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((BIND, PORT))
print(f"fake ntp: serving base={FAKE_DATE} on {BIND}:{PORT}", flush=True)

while True:
    data, addr = sock.recvfrom(1024)
    if len(data) < 48:
        continue
    fake_now = fake_base + (time.time() - real_base)
    print(f"[{time.strftime('%H:%M:%S')}] request from {addr[0]}:{addr[1]}"
          f" -> serving {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(fake_now))}",
          flush=True)
    header = struct.pack("!BBBb", 0x24, 1, 4, -20)   # LI=0 VN=4 mode=4, stratum 1
    root = struct.pack("!II", 0, 0)
    refid = b"LOCL"
    rs, rf = to_ntp(fake_now - 1)
    rcs, rcf = to_ntp(fake_now)
    txs, txf = to_ntp(fake_now)
    pkt = (header + root + refid + struct.pack("!II", rs, rf)
           + data[40:48]                              # originate echo -- required
           + struct.pack("!II", rcs, rcf)
           + struct.pack("!II", txs, txf))
    sock.sendto(pkt, addr)
