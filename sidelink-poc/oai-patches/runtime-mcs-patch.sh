#!/bin/bash
# Idempotent PoC patch: let a user-space program set the sidelink PSSCH MCS while the modem runs, cap the
# number of PSSCH transmissions per second, and read the sender-side HARQ statistics, through a small shared
# file in RAM: /dev/shm/sl-mcs-ctl
#
# Why: the MCS was a launch setting (--mcs / --sl-max-mcs), so trying another MCS meant restarting the modem
# and waiting for the link. The modem's own BLER loop (get_mcs_from_bler) only ever climbs to that cap:
# its "step down" threshold UPPER_BLER is 5.547 (a percentage compared against a 0..1 fraction).
#
# The modem creates the file at its first scheduling decision (mode 0666, 80 bytes used, little-endian):
#   offset  0  uint32  magic        0x314D4C53 ("SLM1")
#   offset  4  int32   force_mcs    WRITTEN BY THE CONTROLLER: -1 = modem decides (default), 0..28 = use this MCS
#   offset  8  int32   mcs_in_use   MCS of the latest scheduling decision
#   offset 12  int32   mcs_modem    what the modem itself chose (before force_mcs)
#   offset 16  int32   cqi          latest CQI reported by the peer (0 = none yet)
#   offset 20  uint32  sched_count  number of scheduling decisions so far
#   offset 24  uint64  rounds[4]    transport blocks sent in HARQ round 0..3 (round 0 = first transmissions)
#   offset 56  uint64  errors       transport blocks given up after the last round
#   offset 64  uint64  total_bytes
#   offset 72  int32   tx_limit     WRITTEN BY THE CONTROLLER: most PSSCH transmissions per second, 0 = no cap
# By hand: ../tools/mcsctl.py (show / set the MCS / set the cap).
# The receiving side needs nothing: the MCS of each transmission is signalled in its SCI.
#
# tx_limit: this UE has 400 transmit opportunities per second (4 sidelink slots per 10 ms). The Jetson needs
# about 0.9 ms to build a 0.5 ms slot, so beyond roughly 250 transmissions per second it falls behind the
# radio, its samples go out late and BOTH directions of the link collapse (seen 14 Nov 2026 with 1.4 Mbit/s
# at MCS 9, and with any level that needs all 4 HARQ rounds for every block). With a cap the extra data
# waits in the RLC queue instead: the application sees delay and loss, the link stays up. The allowed
# transmissions are spread evenly over the opportunities.
#
# The patch also pins every HARQ retransmission to the MCS of its first transmission.
set -e
cd ~/nr-sl-release-poc/oai
cat > executables/poc_mcs_ctl.h <<'H'
// Local PoC patch (runtime-mcs-patch.sh): run-time MCS control + sender statistics shared with user space.
#ifndef POC_MCS_CTL_H
#define POC_MCS_CTL_H
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define POC_MCS_CTL_PATH "/dev/shm/sl-mcs-ctl"
#define POC_MCS_CTL_MAGIC 0x314D4C53u
typedef struct {
  uint32_t magic;
  volatile int32_t force_mcs; // written by the controller: -1 = modem decides, 0..28 = use this MCS
  int32_t mcs_in_use;
  int32_t mcs_modem;
  int32_t cqi;
  uint32_t sched_count;
  uint64_t rounds[4];
  uint64_t errors;
  uint64_t total_bytes;
  volatile int32_t tx_limit; // written by the controller: most PSSCH transmissions per second, 0 = no cap
  int32_t reserved;
} poc_mcs_ctl_t;
// Include this header in ONE .c file only (nr_slsch_scheduler.c): the mapping is created on first use.
static inline poc_mcs_ctl_t *poc_mcs_ctl(void)
{
  static poc_mcs_ctl_t *p = NULL;
  static int tried = 0;
  if (!tried) {
    tried = 1;
    const char *path = getenv("SL_MCS_CTL") ? getenv("SL_MCS_CTL") : POC_MCS_CTL_PATH;
    unlink(path); // a fresh file per modem run (the old one may belong to another user)
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0666);
    if (fd >= 0) {
      if (fchmod(fd, 0666) == 0 && ftruncate(fd, 4096) == 0) {
        void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (m != MAP_FAILED) {
          p = (poc_mcs_ctl_t *)m;
          p->force_mcs = -1;
          p->magic = POC_MCS_CTL_MAGIC;
        }
      }
      close(fd);
    }
    LOG_I(NR_MAC, "PoC patch: run-time MCS control file %s %s\n", path, p ? "ready" : "NOT available");
  }
  return p;
}
#endif
H
python3 - <<'PY'
f = "openair2/LAYER2/NR_MAC_UE/nr_slsch_scheduler.c"
t = open(f).read()
cap = """  if (sched_pssch->mcs > get_nrUE_params()->sl_max_mcs_cap)
    sched_pssch->mcs = get_nrUE_params()->sl_max_mcs_cap;
"""
block = """
  // Local PoC patch (runtime-mcs-patch.sh): a user-space controller may set the MCS while the modem runs.
  {
    poc_mcs_ctl_t *pc = poc_mcs_ctl();
    if (pc) {
      pc->mcs_modem = sched_pssch->mcs;
      const int force = pc->force_mcs;
      if (force >= 0)
        sched_pssch->mcs = force > max_mcs_table ? max_mcs_table : force;
    }
    // A HARQ retransmission must keep the MCS (and so the transport block size) of its first transmission:
    // re-sending a block with another MCS delivers garbage with a valid CRC, which corrupts the receiver's
    // PDCP counter for good (every later packet is then discarded until the modems restart).
    static uint8_t poc_first_mcs[32];
    const int hp = cur_harq ? cur_harq->sl_harq_pid : -1;
    if (hp >= 0 && hp < 32) {
      if (cur_harq->round == 0)
        poc_first_mcs[hp] = sched_pssch->mcs;
      else
        sched_pssch->mcs = poc_first_mcs[hp];
    }
    if (pc) {
      pc->mcs_in_use = sched_pssch->mcs;
      pc->cqi = cqi;
      pc->sched_count++;
      for (int r = 0; r < 4; r++)
        pc->rounds[r] = stats->rounds[r];
      pc->errors = stats->errors;
      pc->total_bytes = stats->total_bytes;
    }
  }
"""
limiter = """// Local PoC patch (runtime-mcs-patch.sh): optional cap on PSSCH transmissions per second, set by the
// controller in the control file. Called once per transmit opportunity of this UE (400 per second); lets
// tx_limit of every 400 through, evenly spaced.
bool poc_tx_allowed(void)
{
  poc_mcs_ctl_t *pc = poc_mcs_ctl();
  const int limit = pc ? pc->tx_limit : 0;
  if (limit <= 0 || limit >= 400)
    return true;
  static int acc = 0;
  acc += limit;
  if (acc < 400)
    return false;
  acc -= 400;
  return true;
}

"""
changed = False
if "poc_mcs_ctl.h" not in t:
    inc = '#include "NR_MAC_gNB/nr_mac_gNB.h"\n'
    assert t.count(inc) == 1, "include anchor"
    t = t.replace(inc, inc + '#include "executables/poc_mcs_ctl.h"\n'); changed = True
if "poc_first_mcs" not in t:
    if "\n  // Local PoC patch (runtime-mcs-patch.sh)" in t:      # first version of this patch: replace its block
        a = t.index("\n  // Local PoC patch (runtime-mcs-patch.sh)")
        b = t.index("\n  }\n", t.index("pc->total_bytes = stats->total_bytes;", a)) + 5
        t = t[:a] + t[b:]
    assert t.count(cap) == 1, "cap anchor"
    assert "cur_harq" in t[t.index("void nr_schedule_slsch("):t.index(cap)], "cur_harq is not a parameter of nr_schedule_slsch"
    t = t.replace(cap, cap + block); changed = True
if "poc_tx_allowed" not in t:
    a = "void nr_schedule_slsch("
    assert t.count(a) == 1, "nr_schedule_slsch anchor"
    t = t.replace(a, limiter + a); changed = True
if changed:
    open(f, "w").write(t); print("patched:", f)
else:
    print("already patched:", f)

f = "openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c"
t = open(f).read()
if "poc_tx_allowed" in t:
    print("already patched:", f)
else:
    a = "  if (slot < 10 && !get_nrUE_params()->sync_ref) return is_resource_allocated;\n"
    assert t.count(a) == 1, "tx cap anchor"
    t = t.replace(a, a + """
  // Local PoC patch (runtime-mcs-patch.sh): optional cap on PSSCH transmissions per second (overload protection)
  extern bool poc_tx_allowed(void);
  if (!poc_tx_allowed())
    return is_resource_allocated;
""")
    open(f, "w").write(t); print("patched:", f)
PY
grep -n "poc_mcs_ctl\|poc_tx_allowed" openair2/LAYER2/NR_MAC_UE/nr_slsch_scheduler.c openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c | cut -c1-140
echo "Now rebuild:  cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem"
