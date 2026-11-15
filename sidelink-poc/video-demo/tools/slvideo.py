#!/usr/bin/env python3
"""Send a file over the NR sidelink and verify it arrives intact.

  sender  (Jetson, 10.0.0.1):  slvideo.py send FILE --rate 2000k
  receiver (PC,    10.0.0.2):  slvideo.py recv OUTFILE [--play]

Data goes Jetson -> PC as paced UDP chunks (seq number + CRC32 each). The receiver sends NACKs back
over the sidelink; the sender retransmits until the receiver confirms the SHA-256 of the whole file.
With --play the receiver feeds the in-order bytes to a GStreamer player while they arrive, then plays
the verified file in a loop at normal speed.
"""
import argparse, hashlib, os, random, socket, struct, subprocess, sys, time, zlib

MAGIC = b"SLV1"
HDR = struct.Struct("!4sIIII")          # magic, file id, seq, total chunks, crc32(payload)
META_SEQ = 0xFFFFFFFF
DATA_PORT, FB_PORT = 5600, 5601
CHUNK = 1200
SRC_IP = os.environ.get("SLV_SRC", "10.0.0.1")   # sender (Jetson) sidelink address
DST_IP = os.environ.get("SLV_DST", "10.0.0.2")   # receiver (PC) sidelink address
TEST_DROP = float(os.environ.get("SLV_TEST_DROP", "0"))  # testing only: drop this fraction of sends


def fmt_rate(bits_per_s):
    return f"{bits_per_s/1e6:.2f} Mbit/s" if bits_per_s >= 1e6 else f"{bits_per_s/1e3:.0f} kbit/s"


def parse_rate(s):
    s = s.lower().rstrip("bit/s").rstrip("b")
    mult = {"k": 1e3, "m": 1e6}.get(s[-1], 1)
    return float(s[:-1] if s[-1] in "km" else s) * mult


# ----------------------------------------------------------------------------------------- sender
def send(a):
    data = open(a.file, "rb").read()
    total = (len(data) + CHUNK - 1) // CHUNK
    sha = hashlib.sha256(data).digest()
    fid = zlib.crc32(sha) & 0xFFFFFFFF
    chunks = [data[i * CHUNK:(i + 1) * CHUNK] for i in range(total)]
    meta = struct.pack("!Q32s", len(data), sha) + os.path.basename(a.file).encode()[:200]

    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.bind((SRC_IP, 0))
    fb = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fb.bind((SRC_IP, FB_PORT))
    fb.setblocking(False)

    rate = parse_rate(a.rate)
    gap = (HDR.size + CHUNK + 28) * 8 / rate          # seconds per packet incl. UDP/IP headers
    print(f"Sending {a.file}: {len(data)} bytes, {total} chunks, sha256 {sha.hex()[:16]}..., "
          f"pace {fmt_rate(rate)} -> {DST_IP}:{DATA_PORT}", flush=True)

    def pkt(seq):
        if seq == META_SEQ:
            return HDR.pack(MAGIC, fid, META_SEQ, total, zlib.crc32(meta)) + meta
        return HDR.pack(MAGIC, fid, seq, total, zlib.crc32(chunks[seq])) + chunks[seq]

    queue = [META_SEQ] + list(range(total))
    sent = resent = 0
    t0 = time.time(); nxt = t0; last_meta = t0; last_print = t0; last_fb = t0
    done = None
    while done is None:
        # feedback from receiver
        while True:
            try:
                msg, _ = fb.recvfrom(65535)
            except BlockingIOError:
                break
            last_fb = time.time()
            if msg.startswith(b"DONE"):
                done = msg[4:5] == b"1"
                break
            if msg.startswith(b"NACK"):
                nfid, contig, rcvd = struct.unpack("!III", msg[4:16])
                if nfid != fid:
                    continue
                miss = struct.unpack(f"!{(len(msg) - 16) // 4}I", msg[16:])
                # Retransmissions go to the FRONT of the queue so the receiver's in-order stream (and its
                # live display) keeps advancing instead of waiting for the whole first pass to finish.
                front = set(queue[:len(miss) + 400])
                redo = [m for m in miss if m < total and m not in front]
                queue[0:0] = redo; resent += len(redo)
        if done is not None:
            break
        now = time.time()
        if now - last_meta > 2:
            queue.insert(0, META_SEQ); last_meta = now
        if queue and now >= nxt:
            q = queue.pop(0)
            if not (TEST_DROP and q != META_SEQ and random.random() < TEST_DROP):
                tx.sendto(pkt(q), (DST_IP, DATA_PORT))
            sent += 1
            nxt = max(nxt + gap, now - 0.05)
        elif not queue:
            # all sent once; poke the receiver so it reports what is missing
            if now - nxt > 1.0:
                tx.sendto(pkt(META_SEQ), (DST_IP, DATA_PORT)); nxt = now
            time.sleep(0.01)
        else:
            time.sleep(min(0.002, max(0, nxt - now)))
        if now - last_print > 2:
            el = now - t0
            print(f"  t={el:5.1f}s sent {sent} pkts ({resent} retransmits), queue {len(queue)}", flush=True)
            last_print = now
        if now - last_fb > a.timeout:
            print(f"No feedback from receiver for {a.timeout}s; giving up.", flush=True)
            return 2
    el = time.time() - t0
    print(f"Receiver reports {'SHA-256 MATCH' if done else 'SHA-256 MISMATCH'}. {len(data)} bytes in {el:.1f}s "
          f"= {fmt_rate(len(data) * 8 / el)} goodput; {sent} packets sent, {resent} retransmitted.", flush=True)
    return 0 if done else 1


# --------------------------------------------------------------------------------------- receiver
class FMP4Frames:
    """Incrementally parse a fragmented MP4 byte stream (moov first) and return H.264 access units as
    soon as their bytes have arrived. qtdemux holds frames until the stream ends when fed from a pipe,
    so the receiver extracts the frames itself and feeds them to the decoder through appsrc."""

    def __init__(self):
        self.buf = bytearray(); self.base = 0       # absolute stream offset of buf[0]
        self.codec_data = None; self.default_size = 0
        self.samples = []                           # pending (abs_offset, size) from the last moof
        self.mdat_end = 0

    def _boxes(self, data, start, end):
        while start + 8 <= end:
            sz, typ = struct.unpack_from(">I4s", data, start)
            hdr = 8
            if sz == 1:
                sz = struct.unpack_from(">Q", data, start + 8)[0]; hdr = 16
            if sz < hdr:
                return
            yield typ, start, start + hdr, start + sz
            start += sz

    def _find(self, data, start, end, path):
        for typ, s, p, e in self._boxes(data, start, end):
            if typ == path[0]:
                if len(path) == 1:
                    return s, p, e
                skip = {b"stsd": 8, b"avc1": 78}.get(typ, 0)
                r = self._find(data, p + skip, e, path[1:])
                if r:
                    return r
        return None

    def _moov(self, d):
        r = self._find(d, 0, len(d), [b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stsd", b"avc1", b"avcC"])
        if r:
            self.codec_data = bytes(d[r[1]:r[2]])
        r = self._find(d, 0, len(d), [b"moov", b"mvex", b"trex"])
        if r:
            self.default_size = struct.unpack_from(">I", d, r[1] + 16)[0]

    def _moof(self, d, moof_abs):
        traf = self._find(d, 0, len(d), [b"moof", b"traf"])
        if not traf:
            return
        size_default = self.default_size; base = moof_abs
        for typ, s, p, e in self._boxes(d, traf[1], traf[2]):
            if typ == b"tfhd":
                flags = struct.unpack_from(">I", d, p)[0] & 0xFFFFFF; q = p + 8
                if flags & 0x1:
                    base = struct.unpack_from(">Q", d, q)[0]; q += 8
                if flags & 0x2: q += 4
                if flags & 0x8: q += 4
                if flags & 0x10:
                    size_default = struct.unpack_from(">I", d, q)[0]
            elif typ == b"trun":
                flags = struct.unpack_from(">I", d, p)[0] & 0xFFFFFF
                n = struct.unpack_from(">I", d, p + 4)[0]; q = p + 8; off = 0
                if flags & 0x1:
                    off = struct.unpack_from(">i", d, q)[0]; q += 4
                if flags & 0x4: q += 4
                pos = base + off
                for _ in range(n):
                    if flags & 0x100: q += 4
                    sz = size_default
                    if flags & 0x200:
                        sz = struct.unpack_from(">I", d, q)[0]; q += 4
                    if flags & 0x400: q += 4
                    if flags & 0x800: q += 4
                    self.samples.append((pos, sz)); pos += sz

    def feed(self, data):
        """Add in-order bytes; return the list of complete frames now available."""
        self.buf += data; out = []
        while True:
            end = self.base + len(self.buf)
            if self.samples and self.mdat_end > self.base:   # inside an mdat: hand out finished frames
                pos, sz = self.samples[0]
                if pos < self.base:                  # frame before our window (should not happen)
                    self.samples.pop(0); continue
                if pos + sz > end:
                    cut = pos - self.base            # drop bytes before the pending frame
                    if cut > 0:
                        del self.buf[:cut]; self.base += cut
                    break
                out.append(bytes(self.buf[pos - self.base:pos - self.base + sz])); self.samples.pop(0)
                continue
            if self.mdat_end > self.base:            # rest of an mdat with no more known frames
                cut = min(self.mdat_end, end) - self.base
                del self.buf[:cut]; self.base += cut
                if self.base < self.mdat_end:
                    break
                continue
            if len(self.buf) < 16:
                break
            sz, typ = struct.unpack_from(">I4s", self.buf, 0)
            if sz == 1:
                sz = struct.unpack_from(">Q", self.buf, 8)[0]
            if typ == b"mdat":
                self.mdat_end = self.base + sz        # frames (from the last moof) are inside
                hdr = 16 if struct.unpack_from(">I", self.buf, 0)[0] == 1 else 8
                del self.buf[:hdr]; self.base += hdr
                continue
            if len(self.buf) < sz:
                break
            box = bytes(self.buf[:sz])
            if typ == b"moov":
                self._moov(box)
            elif typ == b"moof":
                self._moof(box, self.base)
            del self.buf[:sz]; self.base += sz
        return out


class LivePlayer:
    """Shows frames on screen as they arrive (appsrc -> avdec_h264 -> glimagesink, no clock sync)."""

    def __init__(self, title):
        import gi
        gi.require_version("Gst", "1.0"); gi.require_version("GstApp", "1.0")
        from gi.repository import Gst
        Gst.init(None)
        self.Gst = Gst; self.title = title
        self.parser = FMP4Frames(); self.pipe = None; self.src = None; self.n = 0

    def _start(self):
        Gst = self.Gst
        caps = f"video/x-h264,stream-format=avc,alignment=au,codec_data=(buffer){self.parser.codec_data.hex()}"
        self.pipe = Gst.parse_launch(
            f'appsrc name=src format=time caps="{caps}" ! avdec_h264 ! videoconvert ! '
            f'textoverlay name=ov valignment=top halignment=left font-desc="Sans 26" text="{self.title}" ! '
            f'videoconvert ! glimagesink name=sink sync=false')
        self.src = self.pipe.get_by_name("src"); self.ov = self.pipe.get_by_name("ov")
        self.pipe.set_state(Gst.State.PLAYING)
        print("Live player started (first frame received).", flush=True)

    def check(self):
        """Print any pipeline error (e.g. no display) instead of failing silently."""
        if self.pipe is None:
            return
        msg = self.pipe.get_bus().pop_filtered(self.Gst.MessageType.ERROR | self.Gst.MessageType.WARNING)
        if msg:
            err, dbg = msg.parse_error() if msg.type == self.Gst.MessageType.ERROR else msg.parse_warning()
            print(f"  player {msg.type.first_value_nick}: {err.message}", flush=True)

    def feed(self, data, status=""):
        self.check()
        for fr in self.parser.feed(data):
            if self.pipe is None:
                if self.parser.codec_data is None:
                    continue
                self._start()
            b = self.Gst.Buffer.new_wrapped(fr)
            b.pts = self.n * 20_000_000; b.duration = 20_000_000; self.n += 1
            self.src.emit("push-buffer", b)
        if self.pipe is not None and status:
            self.ov.set_property("text", f"{self.title}\n{status}")

    def finish(self, status):
        if self.pipe is None:
            return
        self.ov.set_property("text", f"{self.title}\n{status}")
        self.src.emit("end-of-stream")
        self.pipe.get_bus().timed_pop_filtered(10 * self.Gst.SECOND,
                                              self.Gst.MessageType.EOS | self.Gst.MessageType.ERROR)
        time.sleep(4)
        self.pipe.set_state(self.Gst.State.NULL)


def recv(a):
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    rx.bind((DST_IP, DATA_PORT))
    rx.settimeout(0.2)
    fb = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    fb.bind((DST_IP, 0))

    fid = total = size = None; sha = b""; name = "?"
    got = {}; contig = 0; written = 0
    crc_bad = dup = pkts = 0; first_pass_missing = set(); nacked = {}
    t_first = None; last_fb = 0; last_print = time.time()
    play = LivePlayer("RECEIVED OVER NR SIDELINK - live, frames shown as they arrive") if a.play else None
    print(f"Listening on {DST_IP}:{DATA_PORT} ...", flush=True)
    while True:
        try:
            p, addr = rx.recvfrom(65535)
        except socket.timeout:
            p = None
        now = time.time()
        if p and len(p) >= HDR.size:
            magic, pfid, seq, ptotal, crc = HDR.unpack_from(p)
            body = p[HDR.size:]
            if magic != MAGIC:
                continue
            pkts += 1
            if t_first is None:
                t_first = now
            if zlib.crc32(body) & 0xFFFFFFFF != crc:
                crc_bad += 1
                continue
            if fid is not None and pfid != fid:   # new transfer started: reset
                print("New transfer id; resetting.", flush=True)
                fid = None; got = {}; contig = 0; written = 0; nacked = {}; first_pass_missing = set()
            fid = pfid; total = ptotal
            if seq == META_SEQ:
                size, sha = struct.unpack_from("!Q32s", body)
                name = body[40:].decode(errors="replace")
            elif seq < total:
                if seq in got:
                    dup += 1
                else:
                    got[seq] = body
                    if seq > contig:
                        first_pass_missing.update(s for s in range(contig, seq) if s not in got)
                fresh = []
                while contig in got:
                    fresh.append(got[contig]); written += len(got[contig]); contig += 1
                if play and fresh:
                    el = now - t_first
                    play.feed(b"".join(fresh), f"{written/1e6:.1f} / {(size or 0)/1e6:.1f} MB  "
                              f"{fmt_rate(written*8/max(el,1e-3))}  CRC errors {crc_bad}")
        # feedback / NACK every 0.3 s
        if fid is not None and now - last_fb > 0.3:
            if size is not None and contig == total:
                data = b"".join(got[i] for i in range(total))[:size]
                ok = hashlib.sha256(data).digest() == sha
                for _ in range(5):
                    fb.sendto(b"DONE" + (b"1" if ok else b"0"), (SRC_IP, FB_PORT)); time.sleep(0.05)
                break
            hi = max(got) if got else -1
            cand = [s for s in range(contig, hi + 1) if s not in got]
            # tail never arrived: when the sender has gone quiet, ask for it too
            if p is None and contig > hi and hi < total - 1:
                cand = list(range(hi + 1, total))
            # re-ask for the same chunk at most every 1.5 s (a retransmission may still be in flight)
            miss = [s for s in cand if now - nacked.get(s, 0) > 1.5][:300]
            for s in miss:
                nacked[s] = now
            fb.sendto(b"NACK" + struct.pack(f"!III{len(miss)}I", fid, contig, len(got), *miss), (SRC_IP, FB_PORT))
            last_fb = now
        if now - last_print > 2 and total:
            el = now - (t_first or now)
            print(f"  t={el:5.1f}s {len(got)}/{total} chunks ({100*len(got)/total:5.1f}%), in-order {written} B, "
                  f"rate {fmt_rate(written*8/max(el,1e-3))}, crc errors {crc_bad}, dups {dup}", flush=True)
            last_print = now
    el = time.time() - t_first
    open(a.outfile, "wb").write(data)
    fp_loss = len(first_pass_missing)
    print("=" * 70)
    print(f"File       : {name} -> {a.outfile}")
    print(f"Size       : {len(data)} bytes in {total} chunks, {el:.1f} s, goodput {fmt_rate(len(data)*8/el)}")
    print(f"First pass : {fp_loss} chunks lost ({100*fp_loss/total:.2f}%), recovered by retransmission")
    print(f"Integrity  : {crc_bad} corrupted packets (CRC32) discarded, {dup} duplicates")
    print(f"SHA-256    : {hashlib.sha256(data).hexdigest()}  {'MATCH - file received intact' if ok else 'MISMATCH'}")
    print("=" * 70, flush=True)
    if play:
        play.finish(f"COMPLETE: {len(data)/1e6:.2f} MB in {el:.1f} s, SHA-256 {'MATCH' if ok else 'MISMATCH'}, "
                    f"first-pass loss {100*fp_loss/total:.2f}%, CRC errors {crc_bad}")
    if a.play and ok:
        print("Playing the received file at normal speed (loop). Ctrl+C to stop.", flush=True)
        try:
            while True:
                subprocess.run(["gst-launch-1.0", "-q", "filesrc", f"location={a.outfile}", "!", "qtdemux", "!",
                                "avdec_h264", "!", "videoconvert", "!", "textoverlay",
                                "text=RECEIVED OVER SIDELINK - SHA-256 verified", "valignment=top",
                                "font-desc=Sans 28", "!", "videoconvert", "!", "glimagesink"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if a.once:
                    break
        except KeyboardInterrupt:
            pass
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("send"); s.add_argument("file"); s.add_argument("--rate", default="1000k")
    s.add_argument("--timeout", type=float, default=60)
    r = sp.add_parser("recv"); r.add_argument("outfile"); r.add_argument("--play", action="store_true")
    r.add_argument("--once", action="store_true", help="play the verified file once, not in a loop")
    a = ap.parse_args()
    sys.exit(send(a) if a.cmd == "send" else recv(a))


if __name__ == "__main__":
    main()
