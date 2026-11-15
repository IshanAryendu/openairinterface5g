#!/usr/bin/env python3
"""Read or set the sidelink MCS of the running modem on this machine (needs oai-patches/runtime-mcs-patch.sh).

  tools/mcsctl.py            show the MCS in use and the sender's HARQ counters
  tools/mcsctl.py 7          use MCS 7 from now on (0..28)
  tools/mcsctl.py auto       give the choice back to the modem (its launch setting MAXMCS)
  tools/mcsctl.py watch      print the status once a second
  tools/mcsctl.py limit 240  cap the modem at 240 PSSCH transmissions per second (0 = no cap; 400 is the most
                             this UE can do, and the Jetson falls behind the radio above about 250)

The control file /dev/shm/sl-mcs-ctl appears when the modem makes its first scheduling decision, i.e. once
the link is up. It only affects what THIS machine transmits; the receiver follows automatically.
"""
import os, struct, sys, time

PATH = os.environ.get("SL_MCS_CTL", "/dev/shm/sl-mcs-ctl")
FMT = struct.Struct("<IiiiiI6Q")
MAGIC = 0x314D4C53


def read():
    """Return a dict of the modem's status, or None when the modem (or the patch) is not there."""
    try:
        fd = os.open(PATH, os.O_RDONLY)
    except OSError:
        return None
    try:
        b = os.pread(fd, FMT.size, 0)
    finally:
        os.close(fd)
    if len(b) < FMT.size:
        return None
    magic, force, in_use, modem, cqi, count, r0, r1, r2, r3, errors, total = FMT.unpack(b)
    if magic != MAGIC:
        return None
    return {"force": force, "mcs": in_use, "modem": modem, "cqi": cqi, "count": count,
            "rounds": (r0, r1, r2, r3), "errors": errors, "bytes": total}


def force(mcs):
    """Set the MCS (-1 = modem decides). Returns False when the control file is not there."""
    try:
        fd = os.open(PATH, os.O_RDWR)
    except OSError:
        return False
    try:
        os.pwrite(fd, struct.pack("<i", mcs), 4)
    finally:
        os.close(fd)
    return True


def line(s):
    if s is None:
        return "no control file: modem not running, link not up yet, or modem built without the patch"
    return (f"MCS in use {s['mcs']} ({'forced' if s['force'] >= 0 else 'modem choice'}; modem alone would use "
            f"{s['modem']}), CQI {s['cqi']}, transport blocks per HARQ round {'/'.join(map(str, s['rounds']))}, "
            f"given up {s['errors']}, {s['bytes']} bytes")


if __name__ == "__main__":
    a = sys.argv[1] if len(sys.argv) > 1 else "show"
    if a == "watch":
        while True:
            print(time.strftime("%H:%M:%S"), line(read()), flush=True); time.sleep(1)
    elif a == "limit" and len(sys.argv) > 2 and sys.argv[2].isdigit():
        try:
            fd = os.open(PATH, os.O_RDWR)
        except OSError:
            sys.exit(line(None))
        os.pwrite(fd, struct.pack("<i", int(sys.argv[2])), 72); os.close(fd)
        print("transmission cap:", sys.argv[2], "per second" if int(sys.argv[2]) else "(none)")
    elif a == "show":
        print(line(read()))
    elif a == "auto" or a.lstrip("-").isdigit():
        v = -1 if a == "auto" else int(a)
        if not -1 <= v <= 28:
            sys.exit("MCS must be 0..28 (or auto)")
        if not force(v):
            sys.exit(line(None))
        time.sleep(0.3); print(line(read()))
    else:
        sys.exit(__doc__)
