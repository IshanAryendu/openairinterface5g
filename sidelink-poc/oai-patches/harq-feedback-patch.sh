#!/bin/bash
# Idempotent PoC patch: make sidelink HARQ acknowledgements (PSFCH) reach the sender under load, and make a
# retransmission that no longer fits its block harmless.
#
# 1. Acknowledgements were never used while data was flowing. preprocess() (nr_ue_scheduler.c) releases a
#    HARQ process "whose feedback slot has passed" with update_harq_lists(frame, slot), but frame/slot there
#    are the TRANSMIT slot being scheduled, which is DURATION_RX_TO_TX slots ahead of the slot being
#    received (4 stock; 12 on the Jetson). The feedback for a block sent in slot s comes about 10 slots
#    after s, so whenever the sender scheduled another slot in the meantime the process was declared timed
#    out before its feedback could arrive, the PSFCH reception was never configured ("PSFCH Stats: RX round
#    (0 0 0 0 0)") and the block was sent again, up to 4 times ("given up" although the peer had decoded
#    it). Measured 14 Nov 2026: about 70 % of the Jetson's data blocks went out 4 times.
#    Fix: the timeout uses the slot being received, with 2 slots of margin for the feedback to be processed.
# 2. A retransmission is sent with whatever block size its new slot gives (it depends on the PSFCH symbols
#    and on a CSI request in that slot, not only on the MCS). The stored MAC PDU was then cut short or
#    followed by stale bytes; the receiver parsed that into garbage ("residual mac pdu length -204 < 0",
#    "unsupported SL LCID"), and a garbage PDCP header can move the receiver's PDCP counter so far that it
#    discards everything afterwards (seen twice: rx_deliv 89228 and -66430; video frozen until restart).
#    Fix: if the new block is larger, the PDU is completed with MAC padding; if it is smaller, this round
#    sends padding only (the data stays in the HARQ process for the next round).
set -e
cd ~/nr-sl-release-poc/oai
python3 - <<'PY'
f = "openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c"
t = open(f).read()
if "harq-feedback-patch.sh" in t:
    print("already patched:", f)
else:
    a = "      update_harq_lists(mac, frame, slot, UE);\n"
    assert t.count(a) == 1, "timeout anchor"
    t = t.replace(a, """      {
        // Local PoC patch (harq-feedback-patch.sh): frame/slot are the TX slot being scheduled; feedback can
        // only have been received up to the RX slot, DURATION_RX_TO_TX earlier (2 more slots of margin).
        int poc_rx = (int)frame * nr_slots_frame + (int)slot - DURATION_RX_TO_TX - 2;
        if (poc_rx < 0)
          poc_rx += 1024 * nr_slots_frame;
        update_harq_lists(mac, poc_rx / nr_slots_frame, poc_rx % nr_slots_frame, UE);
      }
""")
    b = """    const uint32_t TBS = pscch_pssch_pdu->tb_size;
    memcpy(pscch_pssch_pdu->slsch_payload, cur_harq->transportBlock, TBS);
"""
    assert t.count(b) == 1, "payload anchor"
    t = t.replace(b, """    const uint32_t TBS = pscch_pssch_pdu->tb_size;
    // Local PoC patch (harq-feedback-patch.sh): a retransmission whose block size differs from the first
    // transmission must still be a valid MAC PDU (see the script header).
    const uint32_t poc_orig = cur_harq->sched_pssch.tb_size;
    if (cur_harq->round != 0 && poc_orig != TBS && TBS > sizeof(NR_SLSCH_MAC_SUBHEADER_FIXED)) {
      uint8_t *poc_p = (uint8_t *)pscch_pssch_pdu->slsch_payload;
      const uint32_t poc_keep = TBS > poc_orig ? poc_orig : sizeof(NR_SLSCH_MAC_SUBHEADER_FIXED);
      memcpy(poc_p, cur_harq->transportBlock, poc_keep);
      ((NR_MAC_SUBHEADER_FIXED *)(poc_p + poc_keep))->R = 0;
      ((NR_MAC_SUBHEADER_FIXED *)(poc_p + poc_keep))->LCID = SL_SCH_LCID_SL_PADDING;
      memset(poc_p + poc_keep + 1, 0, TBS - poc_keep - 1);
    } else
      memcpy(pscch_pssch_pdu->slsch_payload, cur_harq->transportBlock, TBS);
""")
    open(f, "w").write(t)
    print("patched:", f)
PY
grep -n "harq-feedback-patch.sh" openair2/LAYER2/NR_MAC_UE/nr_ue_scheduler.c
echo "Now rebuild:  cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem"
