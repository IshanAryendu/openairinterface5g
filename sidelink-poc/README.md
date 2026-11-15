# NR sidelink on Jetson Orin Nano + USRP B210: fixes and a live video demo

This directory belongs to a fork of OpenAirInterface (OAI), branch `sl-release-1.0`
(base commit `53a8ac81d1` from <https://gitlab.eurecom.fr/oai/openairinterface5g>). The fork adds fixes that
make NR sidelink mode 2 usable between an NVIDIA Jetson Orin Nano and an x86 Linux PC, each with a USRP B210,
and a live H.264 video demo that adapts the MCS and the video bitrate to the link by itself.

The OAI source changes are ordinary commits on the branch `sl-release-1.0-jetson-video`
(`git log --oneline 53a8ac81d1..HEAD`). This directory holds everything around them: the demo, the lab kit
(start/stop/status scripts, frequency profiles), and the patch scripts that made the source changes.

## The fixes

One commit each, in the order they were made (see `git log`):

| Commit subject | What it fixes |
|---|---|
| PoC: USRP C++17 build, --sl-ta / --sl-max-mcs options, short RF read retry | Build with the C++17 USRP driver; options for TX timing advance and an MCS cap; retry of short RF reads |
| Build and run nr-uesoftmodem on aarch64 (NVIDIA Jetson Orin Nano) | aarch64 build |
| sidelink PoC: zero-fill RX overflow gaps in place so slot timing stays locked | A USB overflow no longer shifts the SyncRef timing and breaks the link for good |
| sidelink PoC: build the TX slot inline in the RU thread (SL_TX_INLINE) | The TX slot is built in the radio thread instead of queueing behind decode jobs |
| sidelink PoC: make the RX->TX slot offset a run-time setting (SL_RX_TO_TX) | The Jetson needs about 0.9 ms to build a 0.5 ms slot, so the default 4-slot lead is too short; the offset is now a setting (4..12) |
| sidelink: accept band n48 (CBRS) for sidelink operation | Band n48 |
| sidelink PoC: run-time MCS control, transmit cap and HARQ counters (/dev/shm/sl-mcs-ctl) | MCS can be changed while the modem runs, with a cap on transmissions per second |
| sidelink MAC: fix HARQ retransmission deadlock and feedback-timeout frame wrap | A retransmission no longer waits for a free HARQ process; the 1024-frame wrap is handled |
| sidelink MAC: do not time out HARQ feedback before it can arrive; keep retransmissions valid | HARQ feedback used to time out before it could arrive, so every block was sent 4 times |
| sidelink PHY: pass TBS_LBRM in bits to the PSSCH decoder (fixes 16QAM/64QAM and retransmissions) | The receiver read TBS_LBRM in bytes instead of bits, which broke 16QAM/64QAM and all retransmissions at MCS 4 and above (one-line fix) |
| sidelink PHY: ignore a PSSCH with impossible parameters instead of asserting | A falsely detected SCI no longer stops the modem with an assertion |
| sidelink PoC instrumentation (4 commits) | Timing log lines only (RU thread slots, TX send timing, RX lag and TX time split, PSSCH TX stages); no change in behaviour |

## Results

Measured on 14 Nov 2026, band n48, 3625 MHz, 20 MHz carrier, with both radios inside a shielded enclosure.

* Before the fixes, MCS 9 was the highest that decoded and the link carried about 380-480 kbit/s.
* After them, MCS 0-19 decode. The adaptive video stream held MCS 19 (64QAM) at about 1.14 Mbit/s of video for
  175 s, with 7 of 4503 frames lost (0.16 %) over about 3 minutes.
* The ceilings are the Jetson CPU, at roughly 1.3 Mbit/s, and signal quality above MCS 19.

The numbers depend on antenna placement: the same MCS that was clean on that evening lost packets before the
radios were moved. More measurements are in `video-demo/README.txt`.

## How the adaptation works

Details are in `video-demo/README.txt` and `video-demo/sllive.py`.

* A "level" is one MCS plus a video encoding at the bitrate that MCS can carry (a "ladder" of encodings, one
  per MCS, same keyframes).
* The Jetson searches from the top: it starts at the highest level and drops whenever frames lost in the last
  10 s exceed 1 %, as reported by the PC four times a second.
* A new level is first tried at the lowest bitrate; it gets its own bitrate after 25 intact frames. A level
  that does not work therefore costs about a second of low-quality picture.
* A level that fails is not retried for 30 s, then for twice as long each time. The search always restarts
  from the highest level that is not waiting.
* The modem is capped at 240 transmissions per second, because beyond about 250 the Jetson falls behind the
  radio and the link goes down.

## Contents of this directory

| Path | Contents |
|---|---|
| `video-demo/` | `run-demo.sh`, `demo.conf`, `sllive.py` (streamer and adaptation), `tools/` (ladder maker, MCS control, UDP test) |
| `oai-patches/` | The idempotent patch scripts that produced the source changes, and `README.txt` describing them. Everything except `oai-tree.diff` and the two new headers is already in the commits. |
| `kit/jetson/`, `kit/pc/` | The lab start/stop/status kit (`~/Desktop/sidelink/` on each machine) |
| `kit/launcher/` | `sl-run.sh` (modem launcher), `rfmeas.sh`, `selfloop.sh` |
| `kit/config/` | Sidelink frequency profiles (`*.conf`) |
| `kit/setup/setup-c.sh` | Setup script used on the PC |

No video clips are included. Make a ladder from your own video with `video-demo/tools/make-ladder.sh`.

## Reproducing it

This procedure was written from the lab setup. It has not been re-tested on a clean machine, and the scripts
expect the paths below.

1. Build this branch as `~/nr-sl-release-poc/oai`:
   `cmake_targets/build_oai --nrUE -w USRP --ninja`. The binary ends up in `cmake_targets/ran_build/build`.
2. Copy `kit/<machine>/` (`jetson` or `pc`) to `~/Desktop/sidelink/`, `kit/launcher/*` to
   `~/nr-sl-release-poc/scripts/`, `kit/config/*` to `~/nr-sl-release-poc/config/`, and `video-demo/` to
   `~/Desktop/sidelink-video-demo/`.
3. Edit `~/Desktop/sidelink/settings.conf` on each machine: the role and `PEER_LAN_IP` (the other machine's
   address).
4. Make a ladder from your own video (needs ffmpeg), e.g.
   `tools/make-ladder.sh VIDEO NAME`, copy it to `clips/` on the Jetson and set `LADDER=` in `demo.conf`.
5. Run `./run-demo.sh` in `~/Desktop/sidelink-video-demo/` on both machines. The Jetson sends, the PC shows
   the video.

The IP addresses in the kit files (`192.0.2.x`) and the user name (`labuser`, host `lab-pc`) are
placeholders from the documentation range: replace them with your own. Some kit comments still refer to the
original lab (for example "the authorized over-the-air frequency" for 2585.1 MHz): that frequency may be in
use by other groups where you are, check before using it.

## Known open issues

* The ARM branch of `nr_ulsch_16qam_llr()` takes `&rxdataF_comp`, so the Jetson cannot receive 16QAM.
* The Jetson cannot send PSFCH with a 12-slot RX->TX offset, so blocks sent by the PC still go out four times.
* Steady PC to Jetson data overloads the Jetson receiver; in the demo the PC only sends small reports.
* PDCP has no protection against a corrupt PDU (see `oai-patches/README.txt`).
* The PoC patches are lab-grade (environment variables, a `/dev/shm` control file), not upstream quality.

## Caution

Transmitting on these frequencies (band n48 at 3625 MHz, 2585.1 MHz, 5910 MHz) needs a licence or other
authorisation where you are, or a shielded enclosure. Check before you transmit. Stop both machines after a
demo: a radio left running keeps transmitting.

## Licence and credits

This is a fork of OpenAirInterface by the OpenAirInterface Software Alliance and EURECOM. It keeps upstream's
licence, the OAI Public License V1.1 (see `LICENSE` at the repository root). The sidelink code base is
upstream's `sl-release-1.0` branch; the changes here are fixes and a demo built on top of it.
