#!/bin/bash
# Idempotent PoC patch: survive a short RF read (UHD "bad vrt header or packet fragment") in rfdevice_trx()
# by reading the missing samples instead of AssertFatal. Rare USB glitch on PC-A otherwise kills the modem.
set -e
cd ~/nr-sl-release-poc/oai
F=executables/nr-ue.c
python3 - "$F" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
old = """  AssertFatal(readBlockSize ==
              rfdevice->trx_read_func(rfdevice,
                                      &timestamp,
                                      rxp,
                                      readBlockSize,
                                      fp->nb_antennas_rx), "");
  if(slot_nr == (nb_slot_frame - 1)) {"""
new = """  // Local PoC patch: a rare USB packet error makes UHD return a short block. Read the missing
  // samples instead of aborting; the slot keeps the first read's timestamp, so TX timing is unaffected.
  int got = rfdevice->trx_read_func(rfdevice, &timestamp, rxp, readBlockSize, fp->nb_antennas_rx);
  for (int tries = 0; got >= 0 && got < readBlockSize && tries < 4; tries++) {
    LOG_W(PHY, "PoC patch: short RF read %d/%d samples in slot %d, reading the remainder\\n", got, readBlockSize, slot_nr);
    void *rxp_rest[NB_ANTENNAS_RX];
    for (int i = 0; i < fp->nb_antennas_rx; i++)
      rxp_rest[i] = (void *)((c16_t *)rxp[i] + got);
    openair0_timestamp ts_rest;
    int r = rfdevice->trx_read_func(rfdevice, &ts_rest, rxp_rest, readBlockSize - got, fp->nb_antennas_rx);
    if (r <= 0)
      break;
    got += r;
  }
  AssertFatal(got == readBlockSize, "RF read returned %d of %d samples\\n", got, readBlockSize);
  if(slot_nr == (nb_slot_frame - 1)) {"""
if "PoC patch: short RF read" not in s:
    assert old in s, "anchor not found"
    s = s.replace(old, new, 1)
    open(f, "w").write(s)
PY
grep -n "PoC patch: short RF read" $F
git diff > ~/nr-sl-release-poc/logs/local-patch-usrp.patch; git diff | sha256sum
