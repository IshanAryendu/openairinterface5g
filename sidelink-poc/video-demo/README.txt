NR SIDELINK LIVE VIDEO DEMO - WITH AUTOMATIC MCS / BITRATE ADAPTATION
====================================================================
Live H.264 video from the Jetson Orin Nano to the Linux PC over an OpenAirInterface 5G NR sidelink
(two USRP B210 radios). The Jetson streams the clip; the PC shows the frames as they arrive. (The Jetson
does not show the video itself unless LOCAL_DISPLAY=1 in demo.conf: playing it takes CPU time from the
modem.) The Jetson picks the MCS and the video bitrate by itself: it climbs while the
PC reports at most 1 % of frames lost in 10 s and steps back as soon as the PC reports more.

This folder is the same on both machines: ~/Desktop/sidelink-video-demo/


HOW TO RUN IT
-------------
On EACH machine (either order), in a terminal:

    cd ~/Desktop/sidelink-video-demo
    ./run-demo.sh

The script works out which side it is on (Jetson = sender, PC = receiver), sets the radio settings the
demo needs, starts the radio, waits for the other machine (up to 3 minutes per attempt, 3 attempts), and
then starts the video. The radio takes about 30-60 s to link once both sides are running.

To stop: Ctrl+C in the terminal, or close the video window on the PC. That stops the stream and turns the
radio off on that machine. Stop BOTH machines - a radio left running keeps transmitting.

    ./run-demo.sh stop      stop from another terminal or over SSH (also ends a run-demo.sh that is waiting)
    ./run-demo.sh status    what is running, the MCS in use, and the latest statistics

Only one run-demo.sh runs at a time on a machine; a second one says so and exits.


WHAT YOU SHOULD SEE
-------------------
Jetson: no picture; the terminal prints every step, e.g.
            t=  12.4s DOWN MCS 9->8 (4 of 131 frames lost); MCS 9 is not tried again for 10 s
            t=  23.0s UP MCS 8->9 (0 of 253 frames lost in the last 10 s)
PC:     a normal window (movable, resizable, maximizable) with the clip, half a second behind the sender,
        and under it three lines:
          - the band and carrier
          - ADAPTIVE: the MCS and video bitrate in use, the last step and why, when the next level is tried
          - frames shown / lost, the last 10 s, and the bitrate being received
The picture gets visibly sharper as the level rises. Every frame is sent once (best effort): a lost frame
is a brief glitch that clears at the next keyframe (at most 0.5 s later).


HOW THE ADAPTATION WORKS  (sllive.py, class Adapt; settings in demo.conf)
------------------------------------------------------------------------
A "level" is one MCS together with an encoding of the clip at the bitrate that MCS can carry
(clips/ladder-NAME/, one file per MCS, same frames and keyframe positions in all of them).
  - The PC counts, frame by frame, what arrived in time, and sends its counters to the Jetson 4 times a
    second (UDP port 5603, over the sidelink).
  - Limit: frames lost in the last LOSS_WINDOW seconds (10) must stay <= TARGET_LOSS percent (1).
  - The search runs from the top. The sender starts at the highest level (START_MCS). Whenever the frames
    lost at the current level exceed the limit it drops to the next level down, until a level holds a
    full clean window.
  - After any later failure, and after every clean window, it goes back to the highest level that is not
    waiting out a failure and drops again from there. So it never gets stuck below a bad level: on this
    modem some middle MCS fail while higher ones work (see the results).
  - A level that fails inside its first window is not tried again for FIRST_RETRY_WAIT (30 s), then twice
    as long each time, up to MAX_RETRY_WAIT; a level that had held a clean window before failing, for one
    window (10 s).
  - A new level is first tried with the lowest-bitrate encoding (the new MCS, little data) and gets its
    own bitrate once 25 frames have arrived intact. So a level that does not decode costs about a second
    of low-quality picture instead of overloading the Jetson with retransmissions.
  - The modem is capped at TX_SLOT_LIMIT transmissions per second (240): beyond about 250 the Jetson falls
    behind the radio and the whole link goes down, in both directions.
  - No report from the PC for 2.5 s counts as a failure.
  - The Jetson sets the modem's MCS while it runs (through /dev/shm/sl-mcs-ctl) and changes encoding at the
    next keyframe, so the picture never breaks at a step.
One CSV row per second goes to logs/adapt-*.csv on the Jetson: level, MCS, bitrate, the loss window, the
PC's received bitrate and queueing delay, and the modem's own HARQ counters - ready for plotting.
ADAPT=0 in demo.conf gives the earlier fixed mode (one clip, one MCS).


RESULTS (14 Nov 2026, CBRS band n48, 3625 MHz, 20 MHz carrier)
--------------------------------------------------------------
Conditions: SDRs as placed on the evening of 14 Nov 2026, TXGAIN 15 / RXGAIN 110 on both, siren ladder.

Adaptive video, ladder MCS 0-22 (211 s):
    The search tried MCS 22 and 21 (do not decode: about a second each at the trial bitrate), then MCS 20
    (decodes, but lost more than 1 % at 1184 kbit/s), and settled on MCS 19 (64QAM) at 1137 kbit/s video:
    174 of the 211 s there. Tries of MCS 20-22 came 20, 40, 80, 160 s apart; nearly all lost frames
    (199 of 4377 in the whole run, 4.5 %) fell in those tries.
Adaptive video, ladder MCS 0-19 (187 s):
    MCS 19 for 175 s at 1138 kbit/s video: 4496 frames shown, 7 lost (0.16 %); the modem made 15
    retransmissions in 25,817 blocks. One step down to MCS 18 and back.
Raw link, one-way UDP Jetson -> PC:
    MCS 9: 1200 kbit/s offered -> 0 % loss (1400 kbit/s: collapse, before the transmission cap existed)
    MCS 11, 12, 14, 16, 17, 18 at 600 kbit/s: 0 % loss.  MCS 20: 41 % loss, MCS 22: 87 %, MCS 24: 100 %.
    MCS 16: 1500 kbit/s offered -> 1283 kbit/s delivered (the Jetson's CPU is the limit).
For comparison, the same day before the modem fixes: MCS 9 was the highest that decoded, the link carried
380 kbit/s without loss (480 at most), and the demo streamed a 142 kbit/s clip with about 0.7 % loss.
The numbers move with antenna position: the same MCS that is clean here lost packets before the SDRs were
moved. That is what the adaptation is for.


WHAT IS IN THIS FOLDER
----------------------
run-demo.sh        the one script to run
demo.conf          settings: adaptation on/off and its limits, band, which ladder (edit this, not the script)
sllive.py          the live streamer and the adaptation (send / recv); run-demo.sh starts it
clips/             ladder-siren/       the siren clip, one encoding per MCS (ladder.txt lists them)
                   ladder-testvideo/   the 1080p50 test video at 480p, one encoding per MCS
                   source/             the videos the ladders were made from (PC only)
                   siren_480p_stream.mp4, siren_480p.mp4, siren_240p.mp4   clips for the fixed mode
tools/             make-ladder.sh   make a ladder from any video (needs ffmpeg: run it on the PC)
                   mcsctl.py        show / set the running modem's MCS by hand, and its HARQ counters
                   prepare-clip.sh  make one streaming-friendly clip (fixed mode)
                   slvideo.py       reliable file transfer with SHA-256 check (for files too big to stream)
                   udptest.py       one-way UDP loss / throughput test
oai-patches/       the changes made to the OAI modem and the kit, and how to re-apply them (README.txt there)
kit-snapshot/      copies of this machine's kit files as they were when the demo was first set up
logs/              per run: sender-*.log / receiver-*.log, and adapt-*.csv on the sender
backups/           copies of ~/Desktop/sidelink/settings.conf taken before run-demo.sh changed it
earlier-tests/     files from the first tests on 14 Nov 2026 (not needed by the demo)


WHAT THE DEMO TOUCHES OUTSIDE THIS FOLDER
-----------------------------------------
It uses the existing sidelink kit and modem build, which stay where they are:
    ~/Desktop/sidelink/        start.sh / stop.sh / settings.conf
    ~/nr-sl-release-poc/       OAI modem build, frequency profiles, radio logs
run-demo.sh creates no files there. It changes four values in ~/Desktop/sidelink/settings.conf if they
differ from demo.conf (PROFILE, MAXMCS, RX_TO_TX, RATE_LIMIT) and saves the old file in backups/ first.
The kit writes its radio logs to /dev/shm/sl-logs and ~/nr-sl-release-poc/logs as before, and the modem
keeps its MCS control file in RAM at /dev/shm/sl-mcs-ctl (4 kB, gone at reboot).
The kit's TXGAIN was changed by hand from 0 to 15 on both machines on 14 Nov 2026, after the SDRs were
moved closer: at full power the PC's receiver was overdriven. If the SDRs move apart again and the link
does not come up, set TXGAIN=0 in ~/Desktop/sidelink/settings.conf on both.


CHANGING THINGS
---------------
Another video:  on the PC:  tools/make-ladder.sh VIDEO NAME      -> clips/ladder-NAME/
                copy that folder into clips/ on the Jetson and set LADDER=clips/ladder-NAME in its demo.conf.
The limit:      TARGET_LOSS and LOSS_WINDOW in demo.conf on the Jetson.
The MCS range:  MIN_MCS / MAX_MCS / START_MCS in demo.conf on the Jetson.
Jetson window:  LOCAL_DISPLAY=1 in demo.conf on the Jetson (off by default: it costs the modem CPU time).
Another band:   PROFILE in demo.conf on BOTH machines (cbrs / 20mhz / n47). 2585.1 MHz (20mhz) may be in use by
                other groups in your lab: check before using it. cbrs and n47 are for use inside a shielded enclosure only.
Keep the radio on after the demo:  STOP_RADIO_ON_EXIT=0 in demo.conf.


IF SOMETHING GOES WRONG
-----------------------
"the sidelink did not come up"   Is the script running on the other machine? Are both B210s on USB 3 ports?
                                 Run ./run-demo.sh status on both, then start again.
PC window stays empty            The sender is not streaming yet, or the link dropped: check the Jetson
                                 terminal. The window fills as soon as frames arrive.
Picture frozen, sender says "NO REPORTS from the receiver"
                                 Stop both sides and start again. (Before the HARQ patches this was the PC
                                 modem discarding everything after one corrupt packet.)
It stays at a low level          Losses come in bursts whatever the level; the trace (logs/adapt-*.csv) and
                                 the PC log ("loss burst" lines) show when. Check nothing else is loading
                                 the Jetson; it has little CPU to spare.
"the modem build lacks ..."      The OAI tree was rebuilt without the local patches: see
                                 oai-patches/README.txt.
Radio details                    ~/Desktop/sidelink/status.sh and ~/nr-sl-release-poc/logs/supervisor.log


WHY THINGS ARE THE WAY THEY ARE
-------------------------------
- The Jetson needs about 0.9 ms to build one transmit slot and a slot lasts 0.5 ms. With the stock 4-slot
  lead its samples reached the radio late and were dropped. RX_TO_TX=12 gives it enough lead.
- HARQ acknowledgements used to be thrown away under load, so every data block went out four times; with
  that fixed (oai-patches/harq-feedback-patch.sh) the same link carries about 2.5 times more.
- 16QAM and 64QAM never decoded because the receiver read one rate-matching parameter in the wrong unit
  (oai-patches/lbrm-units-patch.sh). With that fixed MCS 11-18 work; above about MCS 19 the signal quality
  is the limit, which is what the adaptation is there to find.
- The other ceiling is the Jetson's CPU: about 230 transport blocks per second, i.e. about 1.3 Mbit/s at
  MCS 16. A higher MCS puts more bytes in each block, which is why the data rate follows the MCS.
- The search runs from the top because the best level is usually near it, and a level that does not work
  is recognised within a second or two.
- PC -> Jetson carries only the small reports: decoding a steady data stream overloads the Jetson receiver.
