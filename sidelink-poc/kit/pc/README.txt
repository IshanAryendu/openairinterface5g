NR SIDELINK - START / STOP KIT
==============================
PC-A 192.0.2.154 = role a (SyncRef UE), sidelink IP 10.0.0.1, interface oaitun_ue1
PC-B 192.0.2.95  = role b (nearby UE),  sidelink IP 10.0.0.2, interface oaitun_ue2
The same kit is on both PCs; only settings.conf differs.

QUICK START
  1. On BOTH PCs double-click "Sidelink Start" on the Desktop
     (or in a terminal:  ~/Desktop/sidelink/start.sh). Order does not matter.
  2. Wait for "LINK IS UP" (usually 20-60 s after both are started).
  3. Optional: "Sidelink Test" (./test.sh, or ./test.sh full for TCP too) on either PC.
  4. When done, "Sidelink Stop" (./stop.sh) on BOTH PCs.

  Closing the start window does NOT stop the link. It runs in the background until stop.sh.
  If double-clicking a Desktop icon does nothing: right-click it > "Allow Launching".

FILES
  start.sh       starts everything in the background, then waits for the link.
                 ./start.sh n47 or ./start.sh 20mhz picks the frequency for that run only
                 (use the same one on both PCs).
  stop.sh        stops the modem (radio stops transmitting), supervisor, iperf3 server, cleans up.
  status.sh      running?, restarts, peer ping, radio decode stats, last events.
  test.sh        ping + UDP both ways (test.sh full adds TCP both ways). Saved to logs/test-*.txt.
  settings.conf  frequency, gains, timing advance, MCS cap, rate limit, auto-restart, watchdog.
  supervisor.sh  background process started by start.sh (do not run by hand).
  common.sh      shared helpers.

FREQUENCY  (PROFILE in settings.conf, default 20mhz)
  20mhz  2585.1 MHz, the authorized over-the-air frequency.
  n47    5910 MHz (V2X band n47). FARADAY CAGE ONLY - not authorized open-air.

WHAT THE SUPERVISOR DOES
  - Starts nr-uesoftmodem with the tested settings (TX 0, RX 110, PC-B TA 128, MCS cap 2).
  - Auto-restart: if the modem exits (for example after the UHD "bad vrt header" USB
    fault), it is restarted after 5 s. After 3 quick failures in a row it waits 60 s.
  - Restarts both sides together: when one modem (re)starts, its supervisor sends a UDP
    message (port 4049, office network) to the other PC's supervisor, which restarts its
    modem too. Needed because a one-sided restart leaves the other side discarding all
    packets (stale PDCP sequence numbers). Recovery takes ~25-40 s.
  - Watchdog: once the link has been up, if the peer stops answering pings for 90 s (PC-A)
    or 120 s (PC-B), both modems are restarted.
  - Rate limit: traffic sent into the link is capped at 100 kbit/s. Higher load makes this
    OAI branch corrupt packets. UDP tests above the cap will show loss on purpose.
  - Starts an iperf3 server on the sidelink IP so test.sh works from either PC.
  - Sets the CPU to performance mode and disables deep CPU sleep states.
  - If ufw is active, start.sh opens the sidelink interface and UDP 4049 from the other PC.

LOGS  (~/nr-sl-release-poc/logs/)
  supervisor.log         start/stop/restart/link events (start here)
  a-rf-<profile>-*.txt   modem log for each run on PC-A (b-rf-... on PC-B)
  console-<role>.txt     console of the latest run
  test-*.txt             test.sh results
  Modem logs are not deleted automatically; remove old ones now and then.

MANUAL TRAFFIC
  PC-A:  ping -I oaitun_ue1 10.0.0.2       PC-B:  ping -I oaitun_ue2 10.0.0.1
  iperf3 -c <peer sidelink IP> -B <own sidelink IP> -u -b 80k
