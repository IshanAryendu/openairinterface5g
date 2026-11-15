LOCAL CHANGES TO THE OAI MODEM AND THE SIDELINK KIT
===================================================
The demo needs these. They are already applied and built on both machines (14 Nov 2026). This folder is the
record of what was changed and the way to re-apply it if the OAI tree is reset or rebuilt from scratch.

    oai-tree.diff      "git diff" of ~/nr-sl-release-poc/oai on THIS machine when the demo was set up
    poc_rx_to_tx.h     the one new source file (goes in oai/executables/)
    *.sh               the scripts that made the changes. Each is idempotent (safe to run twice) and edits
                       files under ~/nr-sl-release-poc and ~/Desktop/sidelink.

Needed for the demo (both machines), in this order:
    overflow-align-patch.sh   RX overflow gaps are zero-filled in place, so one USB overflow no longer shifts
                              the SyncRef timing and breaks the link for good
    tx-inline-patch.sh        TX slot is built in the radio thread instead of queueing behind decode jobs
                              (env SL_TX_INLINE=0 restores the old behaviour)
    rx-to-tx-patch.sh         RX->TX slot offset becomes a setting (RX_TO_TX in settings.conf, 4..12, default
                              4); the PSFCH feedback-slot table keeps its fixed "+4" key
    cbrs-profile.sh           adds the "cbrs" profile (band n48, centre 3625.02 MHz) and lets the sidelink
                              config accept band n48. It also sets PROFILE=cbrs in settings.conf.
    runtime-mcs-patch.sh      the MCS can be set while the modem runs, and the sender's HARQ counters read,
                              through /dev/shm/sl-mcs-ctl (a 4 kB file in RAM that the modem creates; see
                              ../tools/mcsctl.py). Needed for ADAPT=1. It also keeps every HARQ
                              retransmission at the MCS of its first transmission (see the script header).
    harq-feedback-patch.sh    HARQ acknowledgements (PSFCH) are no longer timed out before they can arrive,
                              so a block is sent once instead of four times: about 2.5x the data rate
                              (MCS 9: 1200 kbit/s without loss, was 480). A retransmission whose block size
                              changed is sent as valid padding instead of a truncated packet.
    harq-deadlock-patch.sh    a retransmission no longer waits for a free HARQ process (the sender used to
                              stop transmitting for good once all 16 were retransmitting); the feedback
                              timeout handles the 1024-frame wrap-around.
    lbrm-units-patch.sh       the receiver read the LDPC limited-buffer size in bytes instead of bits, so
                              it wrapped every block longer than 10758 coded bits. That is what broke 16QAM
                              and 64QAM (MCS 11 and above never decoded, also in the RF simulator) and every
                              retransmission at MCS 4 and above. One line. After it MCS 11-18 decode.
    sci-sanity-patch.sh       a falsely detected control message with impossible contents is ignored instead
                              of stopping the modem ("Assertion (G>0) failed").

Known modem defects found on 14 Nov 2026 and NOT fixed:
    * The ARM branch of nr_ulsch_16qam_llr() (openair1/PHY/NR_TRANSPORT/nr_ulsch_llr_computation.c) takes
      the address of its pointer argument ("&rxdataF_comp"), so the Jetson cannot RECEIVE 16QAM. It does
      not matter for this demo (the PC sends to the Jetson at MCS 2) but it will for two-way traffic.
    * The Jetson cannot send acknowledgements itself: with RX_TO_TX=12 its transmitter is scheduled 12 slots
      ahead, later than the slot the acknowledgement is due in. So blocks sent by the PC (only the small
      reports in this demo) still go out four times.
    * PDCP has no protection against a corrupt PDU: one bad sequence number moves its counter far ahead and
      everything after is discarded until the modems restart.

Timing instrumentation only (log lines, no change in behaviour; applied on the Jetson):
    slot-timing-patch.sh, tx-timing-patch.sh, tx-profile-patch.sh, tx-stage-patch.sh
    (tx-profile-patch.sh needs slot-timing-patch.sh first)

Order for a fresh tree: overflow-align, tx-inline, rx-to-tx, cbrs-profile, runtime-mcs, harq-deadlock,
harq-feedback (needs rx-to-tx), lbrm-units, sci-sanity, then the instrumentation ones if wanted.

After applying, rebuild:
    cd ~/nr-sl-release-poc/oai/cmake_targets/ran_build/build && ninja nr-uesoftmodem

Other kit changes made by hand on 14 Nov 2026 (see ../kit-snapshot/ for the resulting files):
    common.sh / supervisor.sh   modem logs go to RAM (/dev/shm/sl-logs) and are archived when the modem exits;
                                MODEM_CPUS pins the modem (Jetson: 1-5, CPU 0 serves the USRP USB interrupts)
    sl-run.sh                   passes the MCS, CPU pinning, SL_TX_INLINE and SL_RX_TO_TX to the modem
    settings.conf               Jetson: ROLE=a, EXTRA_ARGS="-E", MODEM_CPUS=1-5;  PC: ROLE=b, TA=128
The originals from before that day are in ~/Desktop/sidelink/backup-20261114/ and
~/nr-sl-release-poc/config/backup-20261114/.

Note: the original files kit-snapshot/, oai-tree.diff, poc_rx_to_tx.h and clips/ mentioned above are not part of this repository (the changes are in the commits instead; no video clips are included).
