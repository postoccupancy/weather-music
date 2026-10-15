# Live CWT spectrum instrument

`live-spectrum.scd` renders the 48 CWT scales for indoor temperature, relative
humidity, and pressure as three persistent sine-oscillator banks. Stop
`live-cwt.scd` first: both sketches use the same native OSC lease for the sender IP
and UDP port, so either sketch's unsubscribe would release that shared lease.

Evaluate the entire `live-spectrum.scd` file. It starts automatically. The public
controls are:

```supercollider
~spectrumStart.value;
~spectrumStop.value;                 // fades, unsubscribes, then frees resources
~spectrumSetMode.value(\physical);
~spectrumSetMode.value(\significance);
~spectrumSetGain.value(\temperature, 1.0);
~spectrumSetGain.value(\humidity, 1.0);
~spectrumSetGain.value(\pressure, 1.0);
~spectrumMute.value(\pressure, true);
~spectrumMute.value(\pressure, false);
~spectrumStatus.value;
~spectrumInspect.value(\temperature, 0);
~spectrumTestTone.value;             // quiet 440 Hz test, independent of OSC
```

To reload after editing, run `~spectrumStop.value`, wait for “Spectrum stopped,”
then evaluate the whole file again. `Cmd-.` performs immediate cleanup. Production
defaults receive on UDP 9000 and register with `192.168.0.41:5005`; a heartbeat
refreshes the lease every ten seconds and stop sends `/router/unsubscribe 9000`.

## Amplitude modes

The OSC magnitude is the square root of recent mean CWT power. The instrument does
not normalize a frame by its maximum or sum.

Physical mode converts all magnitudes to temperature-equivalent degrees Celsius
before applying sensor gain, `physicalGain`, and `masterGain`:

```text
temperature = magnitude_C
humidity    = magnitude_RH * (T + 243.5)^2 / (RH * 17.67 * 243.5)
pressure    = magnitude_hPa * (T + 273.15) / P_hPa
```

Electric Sea identifies these streams as Celsius, percentage points, and hPa. At
the defaults T=20°C, RH=50%, and P=1013.25 hPa, one Celsius corresponds to about
3.10 RH percentage points and one hPa corresponds to about 0.289°C. The humidity
formula is the local derivative of the Magnus saturation-vapor-pressure relation
at approximately constant actual vapor pressure. The pressure formula is the
requested constant-volume ideal-gas proportional convention; it does not model the
room as a sealed vessel. The older dashboard's Fahrenheit expected-RH heuristic
and affine display alignment are separate visual conventions and are not used.

Significance mode uses `magnitude / sqrt(backgroundPower)`. It is dimensionless.
A scale fades to silence when `backgroundValid` is zero or its background is not
finite and strictly positive; it never falls back to physical amplitude. Physical
conversion factors are not applied in significance mode. Adjust `physicalGain`,
`significanceGain`, sensor gains, and `masterGain` live in `~spectrumConfig`.
Targets are bounded by `amplitudeCeiling`; rate-limited warnings report clamping,
and a final limiter catches exceptional summed peaks.

## Receiver behavior and diagnostics

The receiver validates schema v3 and reassembles frames by stream, epoch, and
float64 publication frame number. Chunks may arrive in either order. It requires
complete non-overlapping coverage and consistent metadata, rejects conflicting
duplicates, bounds pending frames, expires incomplete frames, ignores retired
epochs and older frames, and fades on invalidation or stream timeout. A completed
frame with a scale count other than 48 is retained for diagnostics but silenced by
the fixed-size first-version bank.

`~spectrumStatus.value` reports five distinct receiver measures: rejected malformed
packets, valid-but-ignored old packets, frames currently awaiting chunks, expired
incomplete frames, and completed frames. A malformed packet also produces a
rate-limited warning naming its first failing field, OSC index, value, decoded
SuperCollider class, and expected form. Source timestamps are retained for display
but are not interpreted as UTC.

## Tests and manual checks

On macOS, from this repository:

```sh
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/live-spectrum-test.scd
```

The fixture uses loopback UDP 19000, never registers with the Pi, and keeps master
gain at zero. It exercises real native OSC decoding, two-chunk frames in reverse
order, duplicates, malformed packets, metadata conflicts, pending expiry, epoch
changes, invalidation, timeout, both amplitude modes, gain/mute controls, persistent
synth nodes, heartbeat, and start/stop/restart cleanup.

For Windows, stop the old sketch, evaluate `~cwtStop.value` if it is loaded, then
evaluate all of `live-spectrum.scd`. Within a few analysis cycles:

```supercollider
~spectrumStatus.value;
```

should show `frame` above zero, `scales=48`, `backgrounds=48`, and `state=ready` for
active streams. Use `~spectrumTestTone.value` to verify the selected server output
device independently. If the tone works but the banks do not, inspect one received
scale and temporarily raise a musical gain within the documented safety ceiling;
do not change the protocol validator or limiter.
