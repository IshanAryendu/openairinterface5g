#!/usr/bin/env python3
"""Live (real-time) H.264 video over the NR sidelink, with automatic MCS / bitrate adaptation.

  sender   (Jetson, 10.0.0.1):  sllive.py send --ladder clips/ladder [--local]      adaptive
                                sllive.py send FILE [--local]                       one clip, fixed MCS
  receiver (PC,     10.0.0.2):  sllive.py recv

Every frame is sent once, at its real playback time, as UDP datagrams (best effort: a lost packet is a
lost frame), and the clip loops forever. The receiver plays each frame at its due time (first arrival +
--delay), counts the frames that did not arrive in time, and reports its counters back to the sender four
times a second (UDP port 5603).

ADAPTATION (sender, --ladder DIR). DIR/ladder.txt lists one encoding of the same clip per MCS:
"MCS FILE" lines, lowest first, each encoded at the bitrate that MCS can carry (tools/make-ladder.sh).
A level = one MCS + its encoding. The sender sets the modem's MCS through /dev/shm/sl-mcs-ctl
(oai-patches/runtime-mcs-patch.sh) and switches encoding at a keyframe. The rule (class Adapt):
  * the limit: frames lost in the last --window seconds (10) must stay <= --target percent (1 %);
  * the search is top-down: start at the highest level and, each time the frames lost at the current
    level exceed the limit, drop to the next level down, until a level holds a full clean window;
  * after any later failure, and after every clean window, go back to the highest level that is not
    waiting out a failure, and drop again from there (on this modem some middle MCS fail while higher
    ones work, so climbing one level at a time would get stuck below them);
  * a level that fails within its first window (the try itself failed) is not tried again for
    --first-wait seconds (30), then twice as long each time, up to --max-hold. A level that had already
    held a full window and then fails (an ordinary loss burst) may be tried again after one window;
  * no report from the receiver for 2.5 s, or reports that show no frame arriving, count as a failure;
  * a level is first tried with the LOWEST encoding (the new MCS, little data) and only gets its own
    bitrate once --probe frames have arrived intact. A level whose MCS does not decode then costs a second
    of low-rate video instead of four HARQ rounds of everything, which would overload the sender's CPU;
  * --tx-limit caps the modem's transmissions per second (same reason: overload takes the whole link down).
So the stream sits at the highest level the link carries within the limit, and re-probes the next one.
Each second the sender writes a row to --trace (CSV) with the level, the loss window, the receiver's
bitrate and queueing delay, and the modem's own HARQ counters.
"""
import argparse, collections, heapq, os, random, signal, socket, struct, sys, time

MAGIC = b"SLL2"
# magic, stream id, packet number, loop, frame index, frames per loop, fragment index, fragment count,
# flags (bit 0 = keyframe), level, MCS (255 = not set by the sender), frame duration (us), send time (ms)
HDR = struct.Struct("!4sIIHHHBBBBBII")
REP_MAGIC = b"SLR2"
# magic, stream id, report number, playhead (frames judged so far, as loop * frames per loop + index),
# frames shown, frames lost, packets received, highest packet number, kbit/s in the last second,
# queueing delay (ms above the smallest one-way delay seen in the last minute)
REP = struct.Struct("!4sIIIIIIIHH")
INFO = 0xFFFE                     # frame index of the information packet (payload = text for the receiver's window)
PORT = 5602
FB_PORT = 5603
FRAG = 1100
SRC_IP = os.environ.get("SLL_SRC", "10.0.0.1")
DST_IP = os.environ.get("SLL_DST", "10.0.0.2")
TEST_DROP = os.environ.get("SLL_TEST_DROP", "")   # testing only: "0.02" or "9:0.03,11:1" = drop fraction (per MCS)

CTL_PATH = os.environ.get("SL_MCS_CTL", "/dev/shm/sl-mcs-ctl")
CTL = struct.Struct("<IiiiiI6Q")
CTL_MAGIC = 0x314D4C53

# gtksink draws into an ordinary GTK window (title bar: movable, resizable, maximizable); the statistics go
# in a text line under the video. (glimagesink opens a bare Wayland surface that GNOME cannot move or resize.)
PC_SINK = 'avdec_h264 ! videoconvert ! gtksink name=vsink sync=false'
JETSON_SINK = ('h264parse ! nvv4l2decoder ! nvvidconv ! video/x-raw(memory:NVMM),width=1280,height=720 ! '
               'nv3dsink sync=false')


def modulation(mcs):
    return "QPSK" if mcs <= 9 else "16QAM" if mcs <= 16 else "64QAM"


# --------------------------------------------------------------------------------- modem MCS control
def ctl_read():
    """Status of the running modem (see oai-patches/runtime-mcs-patch.sh), or None."""
    try:
        fd = os.open(CTL_PATH, os.O_RDONLY)
    except OSError:
        return None
    try:
        b = os.pread(fd, CTL.size, 0)
    except OSError:
        return None
    finally:
        os.close(fd)
    if len(b) < CTL.size:
        return None
    magic, force, in_use, modem, cqi, count, r0, r1, r2, r3, errors, total = CTL.unpack(b)
    if magic != CTL_MAGIC:
        return None
    return {"force": force, "mcs": in_use, "modem": modem, "cqi": cqi, "count": count,
            "new": r0, "retx": r1 + r2 + r3, "fail": errors, "bytes": total}


def ctl_write(offset, value):
    try:
        fd = os.open(CTL_PATH, os.O_RDWR)
    except OSError:
        return False
    try:
        os.pwrite(fd, struct.pack("<i", value), offset)
    except OSError:
        return False
    finally:
        os.close(fd)
    return True


def ctl_force(mcs):
    """Tell the modem which MCS to use (-1 = its own choice). False when the control file is not there."""
    return ctl_write(4, mcs)


def ctl_limit(per_second):
    """Cap the modem's PSSCH transmissions per second (0 = no cap)."""
    return ctl_write(72, per_second)


# ------------------------------------------------------------------------------------------ MP4
def parse_mp4(path):
    """Return (avcC codec data, [(frame bytes, dts seconds, is keyframe)], mean frame duration seconds)."""
    d = open(path, "rb").read()

    def boxes(start, end):
        while start + 8 <= end:
            sz, typ = struct.unpack_from(">I4s", d, start); hdr = 8
            if sz == 1:
                sz = struct.unpack_from(">Q", d, start + 8)[0]; hdr = 16
            elif sz == 0:
                sz = end - start
            if sz < hdr:
                return
            yield typ, start + hdr, start + sz
            start += sz

    def child(rng, typ):
        for t, p, e in boxes(*rng):
            if t == typ:
                return p, e
        return None

    moov = child((0, len(d)), b"moov")
    if not moov:
        sys.exit(f"{path}: no moov box: not an MP4 file")
    for t, p, e in boxes(*moov):
        if t != b"trak":
            continue
        mdia = child((p, e), b"mdia"); hdlr = child(mdia, b"hdlr")
        if d[hdlr[0] + 8:hdlr[0] + 12] != b"vide":
            continue
        mdhd = child(mdia, b"mdhd")
        timescale = struct.unpack_from(">I", d, mdhd[0] + (20 if d[mdhd[0]] == 1 else 12))[0]
        stbl = child(child(mdia, b"minf"), b"stbl")
        stsd = child(stbl, b"stsd")
        esz, fmt = struct.unpack_from(">I4s", d, stsd[0] + 8)
        if fmt not in (b"avc1", b"avc3"):
            sys.exit(f"{path}: video codec {fmt.decode()} is not H.264")
        avcc = child((stsd[0] + 16 + 78, stsd[0] + 8 + esz), b"avcC")
        codec = d[avcc[0]:avcc[1]]
        stsz = child(stbl, b"stsz")
        fixed, n = struct.unpack_from(">II", d, stsz[0] + 4)
        if n == 0:
            sys.exit(f"{path}: no sample table (fragmented MP4): re-encode it with tools/prepare-clip.sh")
        sizes = [fixed] * n if fixed else list(struct.unpack_from(f">{n}I", d, stsz[0] + 12))
        co = child(stbl, b"stco"); fmt_co = "I"
        if not co:
            co = child(stbl, b"co64"); fmt_co = "Q"
        nco = struct.unpack_from(">I", d, co[0] + 4)[0]
        chunk_off = struct.unpack_from(f">{nco}{fmt_co}", d, co[0] + 8)
        stsc = child(stbl, b"stsc"); nsc = struct.unpack_from(">I", d, stsc[0] + 4)[0]
        sc = [struct.unpack_from(">III", d, stsc[0] + 8 + 12 * i) for i in range(nsc)]
        stts = child(stbl, b"stts"); ntt = struct.unpack_from(">I", d, stts[0] + 4)[0]
        deltas = []
        for i in range(ntt):
            c, dl = struct.unpack_from(">II", d, stts[0] + 8 + 8 * i); deltas += [dl] * c
        stss = child(stbl, b"stss"); keys = None
        if stss:
            nk = struct.unpack_from(">I", d, stss[0] + 4)[0]
            keys = set(struct.unpack_from(f">{nk}I", d, stss[0] + 8))
        frames = []; si = 0; dts = 0; k = 0
        for ci in range(nco):
            while k + 1 < nsc and sc[k + 1][0] <= ci + 1:
                k += 1
            o = chunk_off[ci]
            for _ in range(sc[k][1]):
                if si >= n:
                    break
                frames.append((d[o:o + sizes[si]], dts / timescale, keys is None or (si + 1) in keys))
                o += sizes[si]; dts += deltas[si] if si < len(deltas) else deltas[-1]; si += 1
        return codec, frames, dts / timescale / len(frames)
    sys.exit(f"{path}: no video track")


def annexb(codec, frames):
    """MP4 samples (length-prefixed NAL units) -> Annex-B access units with SPS/PPS in front of every
    keyframe, so a decoder can start, or follow a change of encoding, at any keyframe."""
    nls = (codec[4] & 3) + 1
    sc = bytes((0, 0, 0, 1)); ps = b""; p = 6
    for _ in range(codec[5] & 31):
        n = struct.unpack_from(">H", codec, p)[0]; ps += sc + codec[p + 2:p + 2 + n]; p += 2 + n
    npps = codec[p]; p += 1
    for _ in range(npps):
        n = struct.unpack_from(">H", codec, p)[0]; ps += sc + codec[p + 2:p + 2 + n]; p += 2 + n
    out = []
    for data, dts, key in frames:
        aud = b""; body = b""; q = 0
        while q + nls <= len(data):
            n = int.from_bytes(data[q:q + nls], "big"); q += nls
            nal = data[q:q + n]; q += n
            if not nal:
                continue
            typ = nal[0] & 31
            if typ == 9:
                aud = sc + nal                    # access unit delimiter stays first
            elif typ not in (6, 7, 8):            # SEI dropped; SPS/PPS are added below
                body += sc + nal
        out.append((aud + (ps if key else b"") + body, dts, key))
    return out


def load_levels(a):
    """The ladder: a list of {mcs, name, kbps, frames} from lowest to highest."""
    todo = []
    if a.ladder:
        lst = os.path.join(a.ladder, "ladder.txt")
        if not os.path.isfile(lst):
            sys.exit(f"{lst} not found (make the ladder with tools/make-ladder.sh)")
        for ln in open(lst):
            f = ln.split("#")[0].split()
            if len(f) >= 2 and a.min_mcs <= int(f[0]) <= a.max_mcs:
                todo.append((int(f[0]), os.path.join(a.ladder, f[1])))
        todo.sort()
        if not todo:
            sys.exit(f"{lst}: no level between MCS {a.min_mcs} and {a.max_mcs}")
    else:
        todo.append((None, a.file))
    levels = []; ref = None
    for mcs, path in todo:
        codec, frames, dur = parse_mp4(path)
        total = frames[-1][1] + dur
        shape = (len(frames), [f[2] for f in frames])
        if ref is None:
            ref = shape
        elif shape != ref:
            sys.exit(f"{path}: frame count or keyframe positions differ from the first level "
                     f"(all levels must be encoded from the same clip with the same keyframe interval)")
        levels.append({"mcs": mcs, "name": os.path.basename(path), "frames": annexb(codec, frames), "dur": dur,
                       "total": total, "kbps": sum(len(f[0]) for f in frames) * 8 / total / 1e3})
    return levels


# --------------------------------------------------------------------------------------- display
class Player:
    """appsrc -> decoder -> screen; frames are shown as soon as they are pushed (no clock sync)."""

    def __init__(self, desc, title=""):
        import gi
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
        Gst.init(None)
        self.Gst = Gst; self.desc = desc; self.title = title; self.pipe = None; self.n = 0
        self.Gtk = None; self.label = None; self.win = None; self.closing = False

    def start(self):
        caps = "video/x-h264,stream-format=byte-stream,alignment=au"
        desc = self.desc
        if "h264parse" not in desc and self.Gst.ElementFactory.find("h264parse"):
            desc = "h264parse ! " + desc                       # (gstreamer1.0-plugins-bad) tidier stream for the decoder
        self.pipe = self.Gst.parse_launch(f'appsrc name=src format=time is-live=true caps="{caps}" ! {desc}')
        self.src = self.pipe.get_by_name("src")
        vsink = self.pipe.get_by_name("vsink")
        if vsink is not None:                      # embed the video in a normal, decorated window
            import gi
            gi.require_version("Gtk", "3.0")
            from gi.repository import Gtk
            self.Gtk = Gtk
            self.win = Gtk.Window(title=self.title or "Sidelink video")
            self.win.set_default_size(1280, 840)
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            box.pack_start(vsink.props.widget, True, True, 0)
            self.label = Gtk.Label(); self.label.set_line_wrap(True); self.label.set_xalign(0.02)
            box.pack_start(self.label, False, False, 8)
            self.win.add(box)
            self.win.connect("destroy", lambda *_: None if self.closing else os._exit(0))
            self.win.show_all()
        self.pipe.set_state(self.Gst.State.PLAYING)
        print("Player started.", flush=True)

    def push(self, frame, dur):
        b = self.Gst.Buffer.new_wrapped(frame)
        b.pts = int(self.n * dur * 1e9); b.duration = int(dur * 1e9); self.n += 1
        self.src.emit("push-buffer", b)

    def stop(self):
        if self.pipe is None:
            return
        self.closing = True
        self.pipe.set_state(self.Gst.State.NULL)
        if self.win is not None:
            self.win.destroy(); self.pump()
        self.pipe = None; self.win = None; self.label = None; self.closing = False; self.n = 0

    def pump(self):
        """Run pending window events (the program has no GLib main loop of its own)."""
        if self.Gtk is not None:
            while self.Gtk.events_pending():
                self.Gtk.main_iteration_do(False)

    def text(self, s):
        if self.label is not None:
            from gi.repository import GLib
            self.label.set_markup('<span font="14">' + GLib.markup_escape_text(s) + '</span>')

    def check(self):
        if self.pipe is None:
            return
        msg = self.pipe.get_bus().pop_filtered(self.Gst.MessageType.ERROR | self.Gst.MessageType.WARNING)
        if msg:
            err, _ = msg.parse_error() if msg.type == self.Gst.MessageType.ERROR else msg.parse_warning()
            print(f"  player {msg.type.first_value_nick}: {err.message}", flush=True)


# ------------------------------------------------------------------------------------ adaptation
class Adapt:
    """Decides when to change level, from the receiver's reports (see the file header).

    Top-down search: start at the highest level and drop one level at a time until a level holds a full
    clean window. After any later failure, and after every clean window, go back to the highest level that
    is not waiting out a failure and drop again from there. The ladder need not be monotonic (on this modem
    some MCS in the middle fail while higher ones work), which is why the search comes from the top.
    Exploration is paid for with a growing wait: a level that fails as soon as it is tried waits 2x longer
    each time (up to max_hold), so no level is given up for good and none is retried too often."""
    FB_TIMEOUT = 2.5      # seconds without a report, or without the receiver's playhead moving = failure

    def __init__(self, nlev, start, fps, window, target, max_hold, first_wait=30.0):
        self.n = nlev; self.lv = start; self.fps = fps; self.first_wait = float(first_wait)
        self.win = max(1, int(round(window * fps)))            # frames in the loss window
        self.allow = int(self.win * target / 100.0)            # lost frames the window may hold
        self.base_hold = float(window)
        self.max_hold = max(float(window), float(max_hold))
        self.hold = [self.base_hold] * nlev                    # seconds to wait after level i failed before trying it again
        self.failed_at = [None] * nlev                         # time when level i last failed
        self.good = [False] * nlev                             # level i has held a full clean window
        self.epoch = 0                                         # first frame (absolute index) sent at this level
        self.rep = collections.deque(maxlen=4000)              # (playhead, frames lost, frames shown)
        now = time.time()
        self.last_rx = None; self.t_start = now; self.moved_t = now + 2 * self.FB_TIMEOUT
        self.rx_kbps = 0; self.qdelay = 0

    def report(self, playhead, ok, lost, kbps, qdelay, now):
        if self.rep and (lost < self.rep[-1][1] or playhead < self.rep[-1][0]):
            self.rep.clear()                                   # the receiver restarted (or the loop counter wrapped)
        if not self.rep or playhead > self.rep[-1][0]:
            self.moved_t = max(self.moved_t, now)              # the receiver is judging frames
        self.rep.append((playhead, lost, ok))
        self.last_rx = now; self.rx_kbps = kbps; self.qdelay = qdelay

    def switched(self, level, frame, now):
        """The sender started sending `level` at absolute frame index `frame`."""
        self.lv = level; self.epoch = frame
        self.moved_t = max(self.moved_t, now + 1.0)            # the playhead needs a moment to reach the new level

    def stats(self):
        """(frames judged at this level, frames in the loss window, frames lost in it)."""
        base = None
        for r in self.rep:
            if r[0] >= self.epoch:
                base = r; break
        if base is None:
            return 0, 0, 0
        head, lost, _ = self.rep[-1]
        wb = base
        for r in self.rep:
            if r[0] < base[0]:
                continue
            if r[0] <= head - self.win:
                wb = r
            else:
                break
        return head - base[0], head - wb[0], lost - wb[1]

    def wait_for(self, i, now):
        """Seconds still to wait before level i may be tried again."""
        if self.failed_at[i] is None:
            return 0.0
        return max(0.0, self.hold[i] - (now - self.failed_at[i]))

    def fail(self, now, judged, why):
        """The current level failed: note it and choose where to go."""
        if self.last_rx is None:                               # the receiver has never been heard: it is probably
            self.hold[self.lv] = self.base_hold                # not running yet, so do not hold it against the level
        elif judged < self.win:                                # failed in its first window: the try itself failed,
            self.hold[self.lv] = min(max(self.hold[self.lv] * 2, self.first_wait), self.max_hold)   # wait longer each time
            self.good[self.lv] = False
        else:                                                  # it had held a full window: an ordinary loss burst
            self.hold[self.lv] = self.base_hold
        self.failed_at[self.lv] = now
        self.moved_t = now + 1.0
        free = [i for i in range(self.n) if i != self.lv and self.wait_for(i, now) == 0]
        above = [i for i in free if i > self.lv]; below = [i for i in free if i < self.lv]
        if above:
            return above[-1], why                              # back to the top, then down again
        if below:
            return below[-1], why                              # next level down
        return (self.lv - 1, why) if self.lv > 0 else None

    def decide(self, now):
        """Return (new level, reason) or None."""
        judged, wframes, wlost = self.stats()
        if now - self.moved_t > self.FB_TIMEOUT:               # no reports, or reports but no frame judged
            silent = self.last_rx is None or now - self.last_rx > self.FB_TIMEOUT
            return self.fail(now, judged, "no report from the receiver" if silent else "no frames arriving")
        if not self.rep:
            return None
        if wlost > self.allow:
            return self.fail(now, judged, f"{wlost} of {wframes} frames lost")
        if judged >= self.win and wframes >= self.win:         # a full clean window at this level
            self.good[self.lv] = True
            for i in range(self.n - 1, self.lv, -1):           # highest level whose waiting time is over
                if self.wait_for(i, now) == 0:
                    return i, f"{wlost} of {wframes} frames lost in the last {self.win / self.fps:.0f} s"
        return None

    def up_in(self, now):
        """(seconds until the next try of a higher level, that level) or None at the top."""
        if self.lv + 1 >= self.n:
            return None
        need = max(0, self.win - self.stats()[0]) / self.fps
        best = min(range(self.lv + 1, self.n), key=lambda i: (max(need, self.wait_for(i, now)), -i))
        return max(need, self.wait_for(best, now)), best


def parse_drop(spec):
    table = {}
    for item in filter(None, spec.split(",")):
        k, _, v = item.rpartition(":")
        table[int(k) if k else None] = float(v)
    return table


# ----------------------------------------------------------------------------------------- sender
def send(a):
    levels = load_levels(a)
    nfr = len(levels[0]["frames"]); dur = levels[0]["dur"]; total = levels[0]["total"]; fps = 1 / dur
    dts = [f[1] for f in levels[0]["frames"]]; keyf = [f[2] for f in levels[0]["frames"]]
    adaptive = len(levels) > 1
    sid = random.getrandbits(32)
    drop = parse_drop(TEST_DROP)
    print(f"Clip: {nfr} frames, {total:.2f} s, {fps:.1f} fps, {sum(keyf)} keyframes -> {DST_IP}:{PORT}", flush=True)
    for i, L in enumerate(levels):
        print(f"  level {i + 1}: " + (f"MCS {L['mcs']:2d} ({modulation(L['mcs'])}), " if L["mcs"] is not None else "")
              + f"{L['name']}, {L['kbps']:.0f} kbit/s", flush=True)
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); tx.bind((SRC_IP, 0))
    fb = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); fb.bind((SRC_IP, FB_PORT)); fb.setblocking(False)
    player = None
    if a.local:
        player = Player(a.sink or JETSON_SINK); player.start()

    lv = 0
    if adaptive:
        lv = min(range(len(levels)), key=lambda i: (abs(levels[i]["mcs"] - a.start_mcs), i))
    ctl = Adapt(len(levels), lv, fps, a.window, a.target, a.max_hold, a.first_wait) if adaptive else None
    can_force = levels[lv]["mcs"] is not None and ctl_force(levels[lv]["mcs"])
    if can_force and a.tx_limit:
        ctl_limit(a.tx_limit)
    enc = 0 if adaptive and a.probe > 0 else lv               # encoding in use: the lowest one while a level is on trial
    if enc != lv:
        print(f"  t=   0.0s trying MCS {levels[lv]['mcs']} with the {levels[enc]['kbps']:.0f} kbit/s encoding first", flush=True)
    if adaptive and not can_force:
        print("WARNING: no modem MCS control file (/dev/shm/sl-mcs-ctl): the MCS stays at the modem's launch "
              "setting and only the video bitrate adapts. See oai-patches/README.txt", flush=True)
    trace = None
    if a.trace:
        trace = open(a.trace, "w")
        trace.write("time,elapsed_s,level,mcs,video_kbps,event,frames_at_level,window_frames,window_lost,"
                    "rx_kbps,queue_delay_ms,modem_mcs,cqi,tb_new,tb_retx,tb_failed\n")

    heap = []; order = 0; seq = 0; sent = 0
    loop = 0; i = 0; t0 = time.time() + 0.5                    # start time of the current pass of the clip
    pending = None; event = ""; last_event = "starting"; t_event = time.time(); t_start = time.time()
    next_tick = time.time() + 1.0; next_decide = 0.0; prev_m = ctl_read(); switches = 0

    def status(now):
        L = levels[lv]
        if not adaptive:
            return f"Clip: {L['name']}, {fps:.0f} fps, {L['kbps']:.0f} kbit/s; each frame sent once (best effort)"
        s = (f"ADAPTIVE: MCS {L['mcs']} ({modulation(L['mcs'])}), video {levels[enc]['kbps']:.0f} kbit/s"
             + (f" while on trial (then {L['kbps']:.0f})" if enc != lv else "")
             + f" (level {lv + 1} of {len(levels)}); {last_event} {now - t_event:.0f} s ago")
        if ctl.last_rx is None:
            return s + "; waiting for the receiver's reports"
        if now - ctl.last_rx > ctl.FB_TIMEOUT:
            return s + "; NO REPORTS from the receiver"
        _, wf, wl = ctl.stats(); up = ctl.up_in(now)
        s += f"|Limit {a.target:g} % of frames lost in {a.window:g} s; at this level: {wl} lost of {wf}"
        if up is None:
            s += "; top level"
        else:
            nxt = levels[up[1]]
            s += f"; next try: MCS {nxt['mcs']} ({nxt['kbps']:.0f} kbit/s) in {up[0]:.0f} s"
        return s

    try:
        while True:
            now = time.time()
            # ---- reports from the receiver
            if ctl:
                while True:
                    try:
                        p, _ = fb.recvfrom(2048)
                    except (BlockingIOError, InterruptedError):
                        break
                    except OSError:
                        break
                    if len(p) >= REP.size and p[:4] == REP_MAGIC:
                        _, rsid, _, head, ok, lost, _, _, kbps, qd = REP.unpack_from(p)
                        if rsid == sid:
                            ctl.report(head, ok, lost, kbps, qd, now)
            # ---- the next frame of the clip
            tf = t0 + dts[i]
            if now >= tf:
                if keyf[i] and pending is not None:
                    lv = pending; pending = None; switches += 1
                    ctl.switched(lv, (loop & 0xFFFF) * nfr + i, now)
                    if can_force:
                        ctl_force(levels[lv]["mcs"])
                    enc = 0 if a.probe > 0 else lv             # new level: on trial with the lowest encoding
                elif keyf[i] and enc != lv and pending is None and ctl is not None:
                    judged, _, wlost = ctl.stats()
                    if judged >= a.probe and wlost <= ctl.allow:
                        enc = lv                               # the MCS decodes: now its own bitrate
                        print(f"  t={now - t_start:6.1f}s MCS {levels[lv]['mcs']} decodes: bitrate up to {levels[lv]['kbps']:.0f} kbit/s", flush=True)
                L = levels[lv]; fr = levels[enc]["frames"][i][0]
                nk = max(1, -(-len(fr) // FRAG))
                for k in range(nk):
                    heapq.heappush(heap, (tf + k * 0.0004, order, (loop, i, k, nk, keyf[i], lv, fr[k * FRAG:(k + 1) * FRAG])))
                    order += 1
                if player:
                    heapq.heappush(heap, (tf + a.delay, order, fr)); order += 1
                i += 1
                if i >= nfr:
                    i = 0; loop += 1; t0 += total
                    if a.loops and loop >= a.loops:
                        break
                continue
            # ---- packets and local frames that are due
            if heap and heap[0][0] <= now:
                _, _, item = heapq.heappop(heap)
                if isinstance(item, tuple):
                    lp, idx, k, nk, key, plv, body = item
                    mcs = levels[plv]["mcs"]
                    pkt = HDR.pack(MAGIC, sid, seq & 0xFFFFFFFF, lp & 0xFFFF, idx, nfr, k, nk, 1 if key else 0, plv,
                                   255 if mcs is None else mcs, int(dur * 1e6), int(now * 1000) & 0xFFFFFFFF) + body
                    seq += 1
                    p_drop = drop.get(mcs, drop.get(None, 0.0)) if drop else 0.0
                    if not (p_drop and random.random() < p_drop):
                        try:
                            tx.sendto(pkt, (DST_IP, PORT))
                        except OSError as e:
                            print(f"  send error: {e}", flush=True); time.sleep(0.2)
                    sent += 1
                else:
                    player.push(item, dur); player.check()
                continue
            # ---- adaptation decision (4 times a second, never while a switch is waiting for its keyframe)
            if ctl and pending is None and now >= next_decide:
                next_decide = now + 0.25
                d = ctl.decide(now)
                if d:
                    new, why = d
                    going = "UP" if new > lv else "DOWN"
                    event = f"{going} MCS {levels[lv]['mcs']}->{levels[new]['mcs']} ({why})"
                    last_event = f"stepped {going} from MCS {levels[lv]['mcs']} ({why})"; t_event = now
                    extra = ""
                    if new < lv:
                        extra = f"; MCS {levels[lv]['mcs']} is not tried again for {ctl.hold[lv]:.0f} s"
                    print(f"  t={now - t_start:6.1f}s {event}{extra}", flush=True)
                    pending = new
            # ---- once a second: information packet for the receiver's window, console line, trace row
            if now >= next_tick:
                next_tick += 1.0
                st = status(now)
                text = ((a.info + "|") if a.info else "") + st
                try:
                    tx.sendto(HDR.pack(MAGIC, sid, seq & 0xFFFFFFFF, loop & 0xFFFF, INFO, nfr, 0, 1, 0, lv, 255,
                                       int(dur * 1e6), int(now * 1000) & 0xFFFFFFFF) + text.encode()[:1000], (DST_IP, PORT))
                except OSError:
                    pass
                m = ctl_read()
                if can_force and m is not None and m["force"] != levels[lv]["mcs"]:
                    ctl_force(levels[lv]["mcs"])               # the modem restarted: set the MCS again
                el = now - t_start
                if int(el) % 5 == 0:
                    print(f"  t={el:6.1f}s {st.replace('|', ' | ')} | {sent} packets sent", flush=True)
                if trace:
                    judged, wf, wl = ctl.stats() if ctl else (0, 0, 0)
                    dm = [0, 0, 0]
                    if m and prev_m and m["new"] >= prev_m["new"]:
                        dm = [m["new"] - prev_m["new"], m["retx"] - prev_m["retx"], m["fail"] - prev_m["fail"]]
                    L = levels[lv]; quoted = chr(34) + event + chr(34); vk = levels[enc]["kbps"]
                    trace.write(f"{time.strftime('%H:%M:%S')},{el:.1f},{lv + 1},{'' if L['mcs'] is None else L['mcs']},"
                                f"{vk:.0f},{quoted},{judged},{wf},{wl},{ctl.rx_kbps if ctl else ''},"
                                f"{ctl.qdelay if ctl else ''},{m['mcs'] if m else ''},{m['cqi'] if m else ''},"
                                f"{dm[0]},{dm[1]},{dm[2]}\n")
                    trace.flush(); event = ""
                prev_m = m
            # ---- sleep until the next thing is due
            nxt = min(t0 + dts[i], heap[0][0] if heap else now + 1, next_tick, next_decide if ctl else now + 1)
            time.sleep(max(0.0, min(nxt - time.time(), 0.02)))
    finally:
        if can_force:
            ctl_force(-1)                                      # give the MCS back to the modem
            ctl_limit(0)
        if trace:
            trace.close()
        print(f"Sender stopped: {sent} packets sent, {switches} level changes.", flush=True)
    return 0


# --------------------------------------------------------------------------------------- receiver
def recv(a):
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    rx.bind((DST_IP, PORT)); rx.settimeout(0.005)
    player = None
    if not a.no_play:
        player = Player(a.sink or PC_SINK, "LIVE over NR sidelink (Jetson -> PC) - best effort")
        player.start(); player.text("Waiting for the sender ...")
    sid = None; info = ""; loops = {}; cur = None; n = 0; finished = -1; synced = False; cnt_last = 0
    ok = lost = pk = dup = nbytes = burst = 0; hseq = 0; t0 = last_print = time.time(); win = []   # win: (time, ok?) last 10 s
    peer = None; rep_no = 0; next_rep = 0.0; mcs_now = None; lv_now = None
    recent = collections.deque()                 # (time, bytes) of the last second
    dmin = None; dhist = collections.deque()     # smallest one-way delay per report interval, last minute
    print(f"Listening on {DST_IP}:{PORT} ...", flush=True)
    while True:
        try:
            p, addr = rx.recvfrom(65535)
        except socket.timeout:
            p = None
        except OSError:
            p = None
        now = time.time()
        if player:
            player.pump()
        if p and len(p) >= HDR.size and p[:4] == MAGIC:
            _, psid, seq, loop, idx, cnt, k, nk, flags, lv, mcs, dur_us, ts = HDR.unpack_from(p)
            body = p[HDR.size:]
            if psid != sid:                              # a new sender run: start again
                if sid is not None:
                    print("New stream; resetting.", flush=True)
                sid = psid; loops = {}; cur = None; n = 0; finished = -1; synced = False
                ok = lost = pk = dup = nbytes = burst = 0; hseq = 0; t0 = now; win = []; dhist.clear(); dmin = None
            pk += 1; nbytes += len(p); hseq = max(hseq, seq); peer = addr[0]; cnt_last = cnt
            recent.append((now, len(p)))
            d = (int(now * 1000) - ts) & 0xFFFFFFFF
            if d >= 1 << 31:
                d -= 1 << 32
            dmin = d if dmin is None else min(dmin, d)
            if idx == INFO:
                info = body.decode(errors="replace").replace("|", chr(10))
            elif loop > finished:
                if mcs != mcs_now or lv != lv_now:
                    if mcs != 255:
                        print(f"  t={now - t0:6.1f}s sender now at level {lv + 1}, MCS {mcs} ({modulation(mcs)})", flush=True)
                    mcs_now = mcs; lv_now = lv
                L = loops.setdefault(loop, {"base": None, "cnt": cnt, "dur": dur_us / 1e6, "fr": {}, "nk": {}, "key": {}})
                est = now - idx * L["dur"] - k * 0.0004
                L["base"] = est if L["base"] is None else min(L["base"], est)
                fr = L["fr"].setdefault(idx, {})
                if k in fr:
                    dup += 1
                else:
                    fr[k] = body; L["nk"][idx] = nk; L["key"][idx] = flags & 1
        # playout: frame n of the current loop is due at base + n * dur + delay
        while True:
            if cur is None:
                if not loops:
                    break
                cur = min(loops); n = 0
                if finished < 0 and loops[cur]["fr"]:    # joined mid-clip: start at the first frame we heard
                    n = min(loops[cur]["fr"])
            L = loops[cur]
            due = L["base"] + n * L["dur"] + a.delay
            if now < due:
                break
            fr = L["fr"].get(n)
            if fr is not None and len(fr) == L["nk"][n]:
                ok += 1; win.append((now, 1))
                if burst:
                    print(f"  loss burst: {burst} frames ({burst*L['dur']:.2f} s) ending {time.strftime('%H:%M:%S')}"
                          f".{int(now*1000)%1000:03d} (frames were due {a.delay:.1f} s earlier)", flush=True)
                    burst = 0
                if L["key"][n]:
                    synced = True                        # the decoder can start at a keyframe (it carries SPS/PPS)
                if player and synced:
                    player.push(b"".join(fr[j] for j in range(len(fr))), L["dur"])
            else:
                lost += 1; burst += 1; win.append((now, 0))
            L["fr"].pop(n, None); n += 1
            if n >= L["cnt"]:
                del loops[cur]; finished = cur; cur = None
        # report to the sender, four times a second
        if peer and now >= next_rep:
            next_rep = now + 0.25
            while recent and now - recent[0][0] > 1.0:
                recent.popleft()
            kbps = sum(b for _, b in recent) * 8 // 1000
            if dmin is not None:
                dhist.append((now, dmin)); dmin = None
            while dhist and now - dhist[0][0] > 60:
                dhist.popleft()
            qd = (dhist[-1][1] - min(x[1] for x in dhist)) if dhist else 0
            head = (cur * cnt_last + n) if cur is not None else (finished + 1) * cnt_last
            try:
                rx.sendto(REP.pack(REP_MAGIC, sid, rep_no & 0xFFFFFFFF, head & 0xFFFFFFFF, ok & 0xFFFFFFFF,
                                   lost & 0xFFFFFFFF, pk & 0xFFFFFFFF, hseq, min(kbps, 65535), max(0, min(qd, 65535))),
                          (peer, FB_PORT))
            except OSError:
                pass
            rep_no += 1
        if now - last_print > 1:
            win = [w for w in win if now - w[0] < 10]
            wl = sum(1 for w in win if not w[1])
            if sid is not None:
                s = (f"frames shown {ok}, lost {lost} ({100*lost/max(ok+lost,1):.2f}%), last 10 s: {wl} lost of {len(win)}"
                     f" ({100*wl/max(len(win),1):.1f}%); {sum(b for _, b in recent)*8/1e3:.0f} kbit/s now, "
                     f"{nbytes*8/max(now-t0,1e-3)/1e3:.0f} kbit/s average")
                if player:
                    player.text((info + chr(10) if info else "") + s); player.check()
                if int(now - t0) % 5 == 0:
                    print(f"  t={now-t0:6.1f}s {s}" + (f"; MCS {mcs_now}" if mcs_now not in (None, 255) else ""), flush=True)
            last_print = now


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    s = sp.add_parser("send"); s.add_argument("file", nargs="?", help="one clip (no adaptation)")
    s.add_argument("--ladder", default="", help="directory with ladder.txt: adapt MCS and bitrate")
    s.add_argument("--start-mcs", type=int, default=28, help="default: the highest level")
    s.add_argument("--min-mcs", type=int, default=0)
    s.add_argument("--max-mcs", type=int, default=28)
    s.add_argument("--target", type=float, default=1.0, help="highest frame loss allowed in the window, percent")
    s.add_argument("--window", type=float, default=10.0, help="loss window, seconds")
    s.add_argument("--max-hold", type=float, default=300.0, help="longest wait before a failed level is retried, seconds")
    s.add_argument("--first-wait", type=float, default=30.0, help="wait after a level fails its first try, seconds (then doubled)")
    s.add_argument("--probe", type=int, default=25, help="frames a new level must deliver at the lowest bitrate "
                   "before it gets its own bitrate (0 = no trial phase)")
    s.add_argument("--tx-limit", type=int, default=0, help="cap on the modem's transmissions per second (0 = none)")
    s.add_argument("--trace", default="", help="CSV file: one row per second")
    s.add_argument("--loops", type=int, default=0, help="0 = forever")
    s.add_argument("--local", action="store_true", help="also show the frames on this machine's screen")
    s.add_argument("--delay", type=float, default=0.5, help="local display delay (= receiver playout delay)")
    s.add_argument("--sink", default="", help="override the local decoder/sink pipeline description")
    s.add_argument("--info", default="", help="text about the radio link to show in the receiver's window")
    r = sp.add_parser("recv"); r.add_argument("--delay", type=float, default=0.5)
    r.add_argument("--no-play", action="store_true"); r.add_argument("--sink", default="")
    a = ap.parse_args()
    if a.cmd == "send" and not a.ladder and not a.file:
        ap.error("send needs a FILE or --ladder DIR")

    def stop(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, stop)       # also when started in the background, where SIGINT arrives ignored
    signal.signal(signal.SIGTERM, stop)
    try:
        sys.exit(send(a) if a.cmd == "send" else recv(a))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
