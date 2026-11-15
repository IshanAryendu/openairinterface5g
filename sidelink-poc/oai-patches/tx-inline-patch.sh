#!/bin/bash
# Idempotent PoC patch: run the TX slot job inline in the RU thread instead of queueing it in the thread pool.
#
# Problem: UE_processing() pushed the TX job (slot n+4) into the same 4-worker pool as the RX/PSSCH-decode jobs
# and then blocked the RU thread until TX finished. When decoding of earlier slots occupied the workers, the TX
# job waited behind them: TX samples reached the B210 after their timestamp (UHD "L", the samples are dropped on
# air, so the peer fails to decode anything above MCS ~2), and the RU thread stopped reading (RX overflows).
#
# Fix: launch the RX job first, then run processSlotTX() directly in the RU thread (top RT priority), which was
# waiting for it anyway. Runtime switch: env SL_TX_INLINE=0 restores the original behaviour.
set -e
cd ~/nr-sl-release-poc/oai
C=executables/nr-ue.c
python3 - "$C" <<'PY'
import sys
c = sys.argv[1]
t = open(c).read()
if "SL_TX_INLINE" in t:
    print("already patched"); sys.exit(0)
old = """  UE->tx_wait_for_dlsch[curMsgTx->proc.nr_slot_tx] = 0;
  pushTpool(&(get_nrUE_params()->Tpool), newElt);

  // RX slot processing. We launch and forget.
  newElt = newNotifiedFIFO_elt(sizeof(nr_rxtx_thread_data_t), curMsg->proc.nr_slot_rx, NULL, UE_dl_processing);
  nr_rxtx_thread_data_t *curMsgRx = (nr_rxtx_thread_data_t *) NotifiedFifoData(newElt);
  curMsgRx->proc = curMsg->proc;
  curMsgRx->UE = UE;
  curMsgRx->phy_data = UE_dl_preprocessing(UE, &curMsg->proc, intf_type);
  pushTpool(&(get_nrUE_params()->Tpool), newElt);

  // Wait for TX slot processing to finish
  notifiedFIFO_elt_t *res;
  res = pullTpool(txFifo, &(get_nrUE_params()->Tpool));
  if (res == NULL)
    LOG_E(PHY, "Tpool has been aborted\\n");
  else
    delNotifiedFIFO_elt(res);
}"""
new = """  UE->tx_wait_for_dlsch[curMsgTx->proc.nr_slot_tx] = 0;

  // Local PoC patch (tx-inline-patch.sh): run TX inline in this RT thread so it never queues behind RX decoding
  // in the thread pool (late TX -> samples dropped on air). SL_TX_INLINE=0 restores the original behaviour.
  static int tx_inline = -1;
  if (tx_inline < 0) {
    const char *e = getenv("SL_TX_INLINE");
    tx_inline = (e == NULL || atoi(e) != 0);
    LOG_I(PHY, "PoC patch: TX slot processing %s\\n", tx_inline ? "inline in the RU thread" : "in the thread pool");
  }
  notifiedFIFO_elt_t *txElt = newElt;
  if (!tx_inline)
    pushTpool(&(get_nrUE_params()->Tpool), txElt);

  // RX slot processing. We launch and forget.
  newElt = newNotifiedFIFO_elt(sizeof(nr_rxtx_thread_data_t), curMsg->proc.nr_slot_rx, NULL, UE_dl_processing);
  nr_rxtx_thread_data_t *curMsgRx = (nr_rxtx_thread_data_t *) NotifiedFifoData(newElt);
  curMsgRx->proc = curMsg->proc;
  curMsgRx->UE = UE;
  curMsgRx->phy_data = UE_dl_preprocessing(UE, &curMsg->proc, intf_type);
  pushTpool(&(get_nrUE_params()->Tpool), newElt);

  if (tx_inline) {
    processSlotTX(NotifiedFifoData(txElt));
    delNotifiedFIFO_elt(txElt);
    return;
  }

  // Wait for TX slot processing to finish
  notifiedFIFO_elt_t *res;
  res = pullTpool(txFifo, &(get_nrUE_params()->Tpool));
  if (res == NULL)
    LOG_E(PHY, "Tpool has been aborted\\n");
  else
    delNotifiedFIFO_elt(res);
}"""
assert t.count(old) == 1, "anchor not found"
t = t.replace(old, new)
open(c, "w").write(t)
print("patched")
PY
grep -n "SL_TX_INLINE" $C
