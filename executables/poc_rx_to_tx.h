// Local PoC patch (rx-to-tx-patch.sh): runtime RX->TX slot offset, env SL_RX_TO_TX (4..12, default 4).
#ifndef POC_RX_TO_TX_H
#define POC_RX_TO_TX_H
#include <stdlib.h>
static inline int poc_rx_to_tx(void)
{
  static int v = 0;
  if (v == 0) {
    const char *e = getenv("SL_RX_TO_TX");
    int x = e ? atoi(e) : 4;
    v = (x < 4 || x > 12) ? 4 : x;
  }
  return v;
}
#undef DURATION_RX_TO_TX
#define DURATION_RX_TO_TX (poc_rx_to_tx())
// get_feedback_slot() is a lookup table keyed on (PSSCH slot + 4), hard-coded for the 6DL/4UL sidelink TDD pattern.
// The PSFCH slot does not depend on the RX->TX offset, so the key keeps the original constant.
#define POC_PSFCH_TABLE_OFFSET 4
#endif
