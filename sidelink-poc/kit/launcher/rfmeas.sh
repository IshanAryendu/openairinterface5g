#!/bin/bash
# rfmeas.sh <label> [rx_gain_dB]  -- capture 0.5 s at 2585.1 MHz / 30.72 MS/s on RX2 and report burst power.
LABEL=${1:-cap}; G=${2:-30}
F=/tmp/rfmeas-$LABEL.dat
/usr/libexec/uhd/examples/rx_samples_to_file --args type=b200 --freq 2585.1e6 --rate 30.72e6 --gain $G \
  --ant RX2 --subdev A:A --type short --duration 0.5 --file $F >/tmp/rfmeas-$LABEL.log 2>&1 \
  || { echo "capture failed"; tail -5 /tmp/rfmeas-$LABEL.log; exit 1; }
python3 - "$F" "$LABEL" "$G" <<'PY'
import sys, numpy as np
f, label, g = sys.argv[1], sys.argv[2], sys.argv[3]
x = np.fromfile(f, dtype=np.int16).astype(np.float32).reshape(-1, 2)
z = (x[:, 0] + 1j * x[:, 1]) / 32768.0
z = z[int(0.05 * 30.72e6):]                       # drop first 50 ms (settling)
w = 30720                                          # 1 ms windows
n = len(z) // w
p = 10 * np.log10(np.mean(np.abs(z[: n * w].reshape(n, w)) ** 2, axis=1) + 1e-20)
med, mx = np.median(p), p.max()
k = int(p.argmax()); seg = z[k * w:(k + 1) * w]
spec = np.fft.fftshift(np.abs(np.fft.fft(seg)) ** 2)
fr = np.fft.fftshift(np.fft.fftfreq(w, 1 / 30.72e6))
pk = fr[int(spec.argmax())]
hi = np.sum(p > med + 6)
# Averaged spectrum (1 ms FFTs, ~1 kHz bins): strongest non-DC bin vs median bin -> narrowband SNR
S = np.mean(np.abs(np.fft.fft(z[: n * w].reshape(n, w), axis=1)) ** 2, axis=0)
S = np.fft.fftshift(S); bins = np.fft.fftshift(np.fft.fftfreq(w, 1 / 30.72e6))
mask = np.abs(bins) > 5e3                          # ignore DC / LO leakage
i = np.argmax(np.where(mask, S, 0))
t100 = S[np.argmin(np.abs(bins - 100e3)) - 3: np.argmin(np.abs(bins - 100e3)) + 4].max()
print(f"[{label}] narrowband: top bin {bins[i]/1e3:+.1f} kHz at {10*np.log10(S[i]/np.median(S)):.1f} dB over median; "
      f"+100 kHz (+-3 bins) at {10*np.log10(t100/np.median(S)):.1f} dB over median")
print(f"[{label}] gain {g} dB: median {med:.1f} dBFS, max 1ms {mx:.1f} dBFS (+{mx-med:.1f} dB), "
      f"windows >6 dB above median: {hi}/{n}, strongest bin in max window at {pk/1e3:+.1f} kHz, "
      f"clip {np.mean(np.abs(x) > 32000)*100:.3f}%")
PY
rm -f $F
