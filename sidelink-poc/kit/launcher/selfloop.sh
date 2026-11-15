#!/bin/bash
# selfloop.sh: one radio transmits a +100 kHz tone on RF A TX/RX and receives on its own RF A RX2.
# Reports the tone level above noise. Also tests TX/RX -> RX on TX/RX port (internal path) for comparison.
F=/tmp/selfloop.dat
run() {  # $1 = rx antenna
  rm -f $F
  /usr/libexec/uhd/examples/txrx_loopback_to_file --tx-args type=b200 --rx-args type=b200 --tx-freq 2585.1e6 --rx-freq 2585.1e6 \
    --tx-rate 1e6 --rx-rate 1e6 --tx-gain 40 --rx-gain 30 --tx-ant TX/RX --rx-ant $1 \
    --tx-subdev A:A --rx-subdev A:A --tx-channels 0 --rx-channels 0 \
    --wave-type SINE --wave-freq 100e3 --nsamps 500000 --settling 0.5 \
    --type short --file $F > /tmp/selfloop.log 2>&1 || { echo "loopback failed ($1)"; tail -4 /tmp/selfloop.log; return; }
  python3 - $F "$1" <<'PY'
import sys, numpy as np
x = np.fromfile(sys.argv[1], dtype=np.int16).astype(np.float32).reshape(-1, 2)
z = (x[:, 0] + 1j * x[:, 1]) / 32768.0
w = 1000; n = len(z) // w
S = np.fft.fftshift(np.mean(np.abs(np.fft.fft(z[: n * w].reshape(n, w), axis=1)) ** 2, axis=0))
b = np.fft.fftshift(np.fft.fftfreq(w, 1 / 1e6))
k = np.argmin(np.abs(b - 100e3)); t = S[k - 2: k + 3].max()
print(f"  rx on {sys.argv[2]:6s}: +100 kHz tone {10*np.log10(t/np.median(S)):5.1f} dB over noise, "
      f"rx level {10*np.log10(np.mean(np.abs(z)**2)):.1f} dBFS, clip {np.mean(np.abs(x) > 32000)*100:.2f}%")
PY
}
echo "$(hostname) / $(uhd_find_devices 2>/dev/null | awk '/serial:/{print $2; exit}'):"
run RX2
rm -f $F
