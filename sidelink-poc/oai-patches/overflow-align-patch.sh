#!/bin/bash
# Idempotent PoC patch v2 (replaces the stitching in short-read-patch.sh): keep slot timing locked to the
# radio clock across RX overflows.
#
# Problem: on an RX overflow ("O", "received N samples out of M") the B210 drops D samples. The old patch
# appended the post-gap samples straight after the pre-gap ones, so from then on every slot boundary - and
# therefore every TX timestamp - sat D samples (~90 us) late. When the SyncRef (role a) does that, the peer
# loses PSBCH for good and the link is dead until both modems restart.
#
# Fix: (1) trx_usrp_read reports the timestamp of the FIRST sample it returns (it reported the metadata of
# the last recv() call). (2) rfdevice_trx reads through ue_aligned_read(): samples are placed at their real
# position in the slot, the hole is zero-filled, and samples already consumed beyond the slot end become a
# "deficit" that the following reads zero-fill. One overflow now costs one damaged slot, not the link.
set -e
cd ~/nr-sl-release-poc/oai
U=radio/USRP/usrp_lib.cpp; C=executables/nr-ue.c
python3 - "$U" "$C" <<'PY'
import sys
u, c = sys.argv[1], sys.argv[2]

s = open(u).read()
if "PoC patch v2" not in s:
    old_single = """      samples_received += s->rx_stream->recv((void*)((int32_t*)buff_tmp[0]+samples_received),
                                             nsamps-samples_received, s->rx_md);
    }"""
    new_single = """      samples_received += s->rx_stream->recv((void*)((int32_t*)buff_tmp[0]+samples_received),
                                             nsamps-samples_received, s->rx_md);
    }
    // Local PoC patch v2: remember the time of the first returned sample (see overflow-align-patch.sh).
    if (!have_first_ts && samples_received > 0 && s->rx_md.has_time_spec) {
      first_ts = s->rx_md.time_spec.to_ticks(s->sample_rate);
      have_first_ts = true;
    }"""
    assert s.count(old_single) == 1, "usrp anchor 1"
    s = s.replace(old_single, new_single)
    old_init = "  samples_received=0;\n  while (samples_received != nsamps) {"
    assert s.count(old_init) == 1, "usrp anchor 2"
    s = s.replace(old_init, "  samples_received=0;\n  bool have_first_ts = false;\n  openair0_timestamp first_ts = 0;\n  while (samples_received != nsamps) {")
    old_ts = "  s->rx_timestamp = s->rx_md.time_spec.to_ticks(s->sample_rate);\n  *ptimestamp = s->rx_timestamp;"
    assert s.count(old_ts) == 1, "usrp anchor 3"
    s = s.replace(old_ts, "  s->rx_timestamp = have_first_ts ? first_ts : s->rx_md.time_spec.to_ticks(s->sample_rate);\n  *ptimestamp = s->rx_timestamp;")
    open(u, "w").write(s)

t = open(c).read()
if "ue_aligned_read" not in t:
    helper = r'''
// Local PoC patch v2 (overflow-align-patch.sh): read n samples whose slot timing stays locked to the radio
// clock. A gap in the hardware timestamps (RX overflow) is zero-filled at its real position instead of being
// stitched over, and hardware samples consumed past the end of the block become a deficit that the next
// reads zero-fill. *ts is the radio time of buf[..][0]. k selects the state (0 = Uu, 1 = PC5).
static int ue_aligned_read(openair0_device *dev, int k, openair0_timestamp *ts, void **buf, int n, int nant)
{
  static int64_t deficit[2];
  static openair0_timestamp next_ts[2];
  openair0_timestamp w0 = 0;
  bool have_w0 = false;
  int pos = 0;
  if (deficit[k] > 0) {
    w0 = next_ts[k];
    have_w0 = true;
  }
  for (int tries = 0; pos < n; tries++) {
    AssertFatal(tries < 16, "PoC patch v2: RF read stuck at %d of %d samples\n", pos, n);
    if (deficit[k] > 0) {
      int z = deficit[k] < n - pos ? (int)deficit[k] : n - pos;
      for (int a = 0; a < nant; a++)
        memset((c16_t *)buf[a] + pos, 0, z * sizeof(c16_t));
      pos += z;
      deficit[k] -= z;
      continue;
    }
    void *p[NB_ANTENNAS_RX];
    for (int a = 0; a < nant; a++)
      p[a] = (c16_t *)buf[a] + pos;
    openair0_timestamp tr;
    int r = dev->trx_read_func(dev, &tr, p, n - pos, nant);
    if (r < 0)
      return r;
    if (r == 0)
      continue;
    if (!have_w0) {
      w0 = tr - pos;
      have_w0 = true;
    }
    int64_t gap = (int64_t)(tr - (w0 + pos));
    if (gap == 0) {
      pos += r;
      continue;
    }
    if (gap < 0) {
      LOG_E(PHY, "PoC patch v2: RF timestamp went back by %ld samples, ignoring\n", (long)-gap);
      pos += r;
      continue;
    }
    LOG_W(PHY, "PoC patch v2: RX gap of %ld samples at %d/%d, zero-filled to keep slot timing\n", (long)gap, pos, n);
    if (pos + gap < n) {
      int keep = r < n - pos - gap ? r : (int)(n - pos - gap);
      for (int a = 0; a < nant; a++) {
        memmove((c16_t *)buf[a] + pos + gap, (c16_t *)buf[a] + pos, keep * sizeof(c16_t));
        memset((c16_t *)buf[a] + pos, 0, gap * sizeof(c16_t));
      }
      deficit[k] += pos + gap + r - n > 0 ? pos + gap + r - n : 0;
      pos = pos + gap + r < n ? pos + gap + r : n;
    } else {
      for (int a = 0; a < nant; a++)
        memset((c16_t *)buf[a] + pos, 0, (n - pos) * sizeof(c16_t));
      deficit[k] += pos + gap + r - n;
      pos = n;
    }
  }
  *ts = w0;
  next_ts[k] = w0 + n;
  return n;
}

void rfdevice_trx(PHY_VARS_NR_UE *UE, openair0_device *rfdevice,'''
    anchor = "\nvoid rfdevice_trx(PHY_VARS_NR_UE *UE, openair0_device *rfdevice,"
    assert t.count(anchor) == 1, "nr-ue anchor 1"
    t = t.replace(anchor, helper, 1)

    start = t.index("  // Local PoC patch: a rare USB packet error makes UHD return a short block.")
    end = t.index('  AssertFatal(got == readBlockSize, "RF read returned %d of %d samples\\n", got, readBlockSize);\n')
    end += len('  AssertFatal(got == readBlockSize, "RF read returned %d of %d samples\\n", got, readBlockSize);\n')
    t = t[:start] + (
        "  // Local PoC patch v2: overflow-safe read (see ue_aligned_read).\n"
        "  const int rdk = (intf_type == PC5);\n"
        "  int got = ue_aligned_read(rfdevice, rdk, &timestamp, rxp, readBlockSize, fp->nb_antennas_rx);\n"
        '  AssertFatal(got == readBlockSize, "RF read returned %d of %d samples\\n", got, readBlockSize);\n'
    ) + t[end:]

    old_first = """      AssertFatal(first_symbols ==
                  rfdevice->trx_read_func(rfdevice,
                                          &ignore_timestamp,
                                          (void **)rxdata,
                                          first_symbols,
                                          fp->nb_antennas_rx), "");"""
    assert t.count(old_first) == 1, "nr-ue anchor 3"
    t = t.replace(old_first, """      AssertFatal(first_symbols ==
                  ue_aligned_read(rfdevice, rdk,
                                  &ignore_timestamp,
                                  (void **)rxdata,
                                  first_symbols,
                                  fp->nb_antennas_rx), "");""")
    open(c, "w").write(t)
PY
grep -n "PoC patch v2" $U $C
