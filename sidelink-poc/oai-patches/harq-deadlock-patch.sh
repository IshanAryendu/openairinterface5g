#!/bin/bash
# Idempotent PoC patch: two faults in the sidelink HARQ process bookkeeping of the sender.
#
# 1. Deadlock. preprocess() (nr_ue_scheduler.c) skipped a pending RETRANSMISSION whenever no HARQ process
#    was free, although a retransmission re-uses its own process. With small transport blocks (low MCS: one
#    IP packet needs many blocks) all 16 processes are soon waiting for a retransmission at the same time;
#    from then on the modem logs "UE has no free SL HARQ process, skipping" on every slot and never
#    transmits data again (seen 14 Nov 2026 at MCS 0-1 after 2.5 minutes of video).
#    Fix: a retransmission no longer needs a free process.
# 2. Stuck processes. update_harq_lists() (nr_ue_procedures_sl.c) releases a process whose feedback slot
#    has passed, but compared frame numbers without the 1024-frame wrap-around (a process whose feedback
#    frame was missed just before the wrap stayed blocked for up to 10 s) and stopped at the first process
#    it released. Fix: wrap-aware comparison, and the whole list is checked.
set -e
cd ~/nr-sl-release-poc/oai
python3 - <<'PY'
import re
f = "openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c"
t = open(f).read()
if "harq-deadlock-patch.sh" in t:
    print("already patched:", f)
else:
    pat = re.compile(r"""(    /\* retransmission \*/\n    if \(sched_pssch->sl_harq_pid >= 0\) \{\n)      if \(sched_ctrl->available_sl_harq\.head < 0\) \{\n\s*LOG_W\(NR_MAC, "\[UE\]\[%4d\.%2d\] UE has no free SL HARQ process, skipping\\n",\n\s*frame,\n\s*slot\);\n\s*continue;\n      \} else \{\n\s*sched_ctrl->sched_csi_report\.active = false;\n      \}\n""")
    assert len(pat.findall(t)) == 1, "preprocess anchor"
    t = pat.sub(lambda m: m.group(1) +
                "      // Local PoC patch (harq-deadlock-patch.sh): a retransmission re-uses its own HARQ process, so it\n"
                "      // must not wait for a free one (that wait never ended once all processes were retransmitting).\n"
                "      sched_ctrl->sched_csi_report.active = false;\n", t)
    open(f, "w").write(t)
    print("patched:", f)

f = "openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c"
t = open(f).read()
if "harq-deadlock-patch.sh" in t:
    print("already patched:", f)
else:
    a = t.index("void update_harq_lists(")
    b = t.index("\n}\n", a) + 3
    body = t[a:b]
    cond = re.compile(r"if \(\(harq->feedback_frame < frame\s*\|\| \(harq->feedback_frame == frame && harq->feedback_slot < slot\)\)\) \{")
    assert len(cond.findall(body)) == 1, "condition anchor"
    body = cond.sub("// Local PoC patch (harq-deadlock-patch.sh): frame numbers wrap at 1024\n"
                    "    const int poc_age = ((int)frame - (int)harq->feedback_frame + 1024) % 1024;\n"
                    "    if ((poc_age > 0 && poc_age < 512) || (poc_age == 0 && harq->feedback_slot < slot)) {", body)
    first = "    NR_UE_sl_harq_t *harq = &sched_ctrl->sl_harq_processes[cur];\n"
    assert body.count(first) == 1, "loop head anchor"
    body = body.replace(first, first + "    const int poc_next = sched_ctrl->feedback_sl_harq.next[cur]; // read before cur is unlinked\n")
    last = "    cur = sched_ctrl->feedback_sl_harq.next[cur];\n"
    assert body.count(last) == 1, "loop tail anchor"
    body = body.replace(last, "    cur = poc_next;\n")
    open(f, "w").write(t[:a] + body + t[b:])
    print("patched:", f)
PY
grep -n "harq-deadlock-patch.sh" openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c openair2/LAYER2/NR_MAC_UE/nr_ue_procedures_sl.c
echo "Now rebuild:  cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem"
