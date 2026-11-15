#!/usr/bin/env python3
"""One-way UDP link test over the sidelink (no control channel).
  sink BIND_IP PORT SECS            -> prints packets/bytes received, loss from sequence numbers, goodput
  src  SRC_IP DST_IP PORT KBPS SECS [SIZE]
"""
import socket, struct, sys, time
mode = sys.argv[1]
if mode == "sink":
    ip, port, secs = sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    s.bind((ip, port)); s.settimeout(0.5)
    n = nbytes = dup = 0; hi = -1; seen = set(); t_first = t_last = None; end = time.time() + secs
    while time.time() < end:
        try:
            d, _ = s.recvfrom(4096)
        except socket.timeout:
            continue
        if len(d) < 8: continue
        seq, = struct.unpack("!Q", d[:8]); now = time.time()
        if seq in seen: dup += 1; continue
        seen.add(seq); n += 1; nbytes += len(d); hi = max(hi, seq)
        t_first = t_first or now; t_last = now
    span = (t_last - t_first) if n > 1 else 0
    sent = hi + 1
    print("sink: got %d of >=%d pkts (loss %.1f%%), dup %d, %d bytes, goodput %.0f kbit/s over %.1fs" % (
        n, sent, 100.0 * (sent - n) / sent if sent else 100.0, dup, nbytes, nbytes * 8 / span / 1000 if span else 0, span))
else:
    src, dst, port, kbps, secs = sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
    size = int(sys.argv[7]) if len(sys.argv) > 7 else 1200
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((src, 0))
    gap = size * 8 / (kbps * 1000.0); pad = bytes(size - 8)
    t0 = time.time(); seq = 0
    while True:
        due = t0 + seq * gap; now = time.time()
        if now - t0 >= secs: break
        if due > now: time.sleep(due - now)
        try:
            s.sendto(struct.pack("!Q", seq) + pad, (dst, port)); seq += 1
        except OSError:
            time.sleep(0.002)
    print("src: sent %d pkts of %d B at %.0f kbit/s for %.0fs" % (seq, size, kbps, secs))
