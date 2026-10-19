# Live CWT spectrum instrument

`live-spectrum.scd` renders the 48 CWT scales for indoor temperature, relative
humidity, and pressure as three persistent oscillator banks. It can run alongside
`live-cwt.scd`; both sketches reference-count one native OSC lease, and stopping one
keeps the lease alive until the other stops.

See [RHYTHM.md](RHYTHM.md) for the optional phase-accumulated Bus 4 pulse output,
scale selection, percussion note mappings, and Ableton routing.

Evaluate the entire `live-spectrum.scd` file. It starts automatically. The public
controls are:

```supercollider
~spectrumStart.value;
~spectrumStop.value;                 // fades, unsubscribes, then frees resources
~spectrumSetMode.value(\physical);
~spectrumSetMode.value(\significance); // default
~spectrumSetBaseNote.value(48);      // MIDI-note coordinate, continuous playback
~spectrumSetPitchSpan.value(48);     // default; semitones across 0.05..1 environmental Hz
~spectrumSetBaseNote.value(60, \temperature); // optional sensor override
~spectrumSetBaseNote.value(nil, \temperature);// clear sensor override
~spectrumSetWaveform.value(\temperature, \sine);
~spectrumSetWaveform.value(\humidity, \triangle);
~spectrumSetWaveform.value(\pressure, \saw);
~spectrumSetGain.value(\temperature, 1.0);
~spectrumSetGain.value(\humidity, 1.0);
~spectrumSetGain.value(\pressure, 1.0);
~spectrumMute.value(\pressure, true);
~spectrumMute.value(\pressure, false);
~spectrumStatus.value;
~spectrumAudioStatus.value;          // routing, target amplitudes, output-stage meter
~spectrumInspect.value(\temperature, 0);
~spectrumTestTone.value;             // brief tone through the spectrum output stage
~spectrumSetOutputBus.value(2);      // zero-based hardware outputs 3–4
~spectrumMidiStatus.value;
~spectrumMidiPanic.value;
```

To reload after editing, run `~spectrumStop.value`, wait for “Spectrum stopped,”
then evaluate the whole file again. `Cmd-.` performs immediate cleanup. Production
defaults receive on UDP 9000 and register with `192.168.0.41:5005`; a heartbeat
refreshes the lease every ten seconds and stop sends `/router/unsubscribe 9000`.

## Pitch and waveform controls

The pitch mapping follows Electric Sea's resident interface in
`router/resident-live.js`, specifically `mappedMidiValues`,
`mappedAudioFrequency`, and the `base-octave` and `span` inputs. Electric Sea offers
base octaves 1–5 (default 3) and spans of 1–6 octaves (default 3). Weather Music
expresses the same ranges as MIDI coordinates: `baseNote` accepts 24–72 and
`pitchSpan` accepts 12–72 semitones. Defaults 48 and 48 span four octaves. Values may
be fractional and audio playback is never rounded to MIDI notes. An optional sensor
argument installs an override; passing `nil` with that sensor clears the override.

```text
fraction = log2(clamp(environmentalHz, 0.05, 1) / 0.05) / log2(20)
midi      = baseNote + pitchSpan * fraction
audioHz   = 440 * 2^((midi - 69) / 12)
```

Spectrum MIDI rounds the same coordinate to the nearest MIDI note. This does not
alter continuous audio pitch.

For example, these move the lowest scale to C4 and compress the bank to two
octaves, immediately and without touching OSC state:

```supercollider
~spectrumSetBaseNote.value(60);
~spectrumSetPitchSpan.value(24);
```

Each bank independently selects `\sine`, `\triangle`, or `\saw`. A bank keeps its
48 synth voices allocated. Its SynthDef continuously runs a sine source and one
band-limited `VarSaw` source per scale; an 80 ms equal-power crossfade selects sine
or the variable-width triangle/saw source. Pitch retains its existing 200 ms
smoothing, so live pitch edits do not retrigger oscillators.

Fixed waveform compensation is deliberately conservative: sine is 1.0, triangle
is 0.8, and saw is 0.55. These are approximate perceptual adjustments rather than
peak or frame normalization: triangle and especially saw contain upper harmonics
that sound louder than a sine at the same peak. Every CWT scale within a bank gets
the same factor, preserving its spectral relationships. The amplitude ceiling and
final 0.8 limiter remain active, including when all banks use saw.

This architecture adds one continuously running `VarSaw` per scale: 144 additional
oscillators across three full banks, for 288 oscillator UGens total. It avoids the
432 oscillators required to run separate sine, triangle, and saw sources. The muted
native suite at 48 kHz reported 7.02% average and 11.64% peak server CPU on the
development Apple M1 Pro while all three banks were allocated (1,099 total UGens,
including controls, smoothing, mixing, and output safety). This is a local snapshot,
not an installation-machine benchmark; check `avgCPU`/`peakCPU` in the SuperCollider
server meter before sustained use on lower-power hardware.

The limiter, master gain, and shutdown envelope run before the selected hardware
output. Spectrum defaults to bus 2 (physical outputs 3–4). If the booted server has
only two outputs, startup warns and uses configured fallback bus 0 rather than
writing silently to nonexistent outputs. See [multichannel routing](ROUTING.md).

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

Significance mode is the default with `significanceGain` 0.001. Physical mode remains
available with `physicalGain` 1.0. These conservative significance defaults keep the
typical target range below the per-oscillator ceiling while preserving differences
relative to each scale's measured background power.

## Sustained spectrum MIDI

Spectrum MIDI is enabled by default and startup attempts to open `IAC Driver` /
`Bus 3 - Ableton Live`. Destination names must match the operating system exactly:

```supercollider
MIDIClient.init;
MIDIClient.destinations.postln;
~spectrumSetMidiDestination.value("IAC Driver", "Bus 3 - Ableton Live");
```

If the endpoint cannot be opened, the sketch remains MIDI-enabled, prints the
configured endpoint and available destinations, and sends nothing until a valid
destination is selected. MIDI uses the effective per-scale targets before audio
`masterGain`, so it continues when audio is muted at the master.

```supercollider
~spectrumSetMidiEnabled.value(true);             // default; connect immediately
~spectrumSetMidiEnabled.value(false);            // release notes and disconnect
~spectrumSetMidiChannel.value(\temperature, 1);  // spectrum-owned channels 1..3
~spectrumSetMidiChannel.value(\humidity, 2);
~spectrumSetMidiChannel.value(\pressure, 3);
~spectrumSetMidiExpression.value(0.0001, 0.005, 0.5, 2, 64);
~spectrumSetToneExpression.value(\aftertouch); // default
~spectrumMidiStatus.value;
~spectrumMidiPanic.value;
```

The expression arguments are amplitude floor, summation ceiling, smoothing seconds,
MIDI-value deadband, and initial note-on velocity. A scale at or above the floor
starts one held note. Amplitude changes send polyphonic key pressure without
retriggering. Scales that round to the same channel/note are summed and clipped at
the expression ceiling; the note remains on until every contributor is inactive.
Mute, invalid/stale frames, pitch or channel remapping, destination changes,
disable, stop, server quit, and Command-period release affected notes. Panic sends
all-notes-off only on spectrum-owned channels 1–3. Tracked voices own channels 4–16,
so cleanup and reconnects in either sketch cannot reset the other sketch's MIDI state.

Bus 3 tone selection is independent of Bus 4 rhythm selection. `all` is the default
and preserves the original 48-scale behavior. `perBand` chooses one significant scale
from each automatic band, `topN` chooses the strongest N scales across the sensor, and
`fixedBand` emits one representative tone at the band's geometric-mean environmental
frequency with the mean effective band amplitude. Selection occurs before MIDI-note
aggregation, so scales that map to the same MIDI note still share the existing summed
amplitude and note ownership.

```supercollider
~spectrumSetToneSelection.value(\all);
~spectrumSetToneSelection.value(\perBand, 3);
~spectrumSetToneSelection.value(\fixedBand, 3);
~spectrumSetToneSelection.value(\topN, 6);
~spectrumSetToneSelectionHysteresis.value(0.10, 5.0);
```

Tone hysteresis applies only to `perBand` and `topN`. The relative margin and minimum
residence use monotonic time; invalid and stale incumbents release immediately. Native
SuperCollider spectrum audio remains a 48-oscillator bank and is unaffected by this
MIDI-only selection.

### Tone expression modes

Spectrum tone expression is independent of tone selection and Bus 4 rhythm output:

- `off` uses the configured fixed note-on velocity and sends no ongoing expression.
- `aftertouch` preserves the default per-note polyphonic-aftertouch behavior.
- `filter` sends MIDI CC74 once per active sensor channel.
- `pitchBend` sends one conventional channel-wide pitch bend per sensor channel.

For CC74 and pitch bend, all selected notes on a channel contribute by summing their
existing processed amplitudes. The sum is bounded and normalized by the existing
`midiExpressionFloor` and `midiExpressionCeiling`, then smoothed as one channel value.
This prevents individual scales on the same MIDI channel from sending conflicting
controls. A channel with no active tones immediately returns CC74 to zero and pitch
bend to neutral 8192.

```supercollider
~spectrumSetToneExpression.value(\off);
~spectrumSetToneExpression.value(\aftertouch);
~spectrumSetToneExpression.value(\filter);
~spectrumSetToneFilter.value(0, 127, 0.5, 2);
~spectrumSetToneExpression.value(\pitchBend);
~spectrumSetTonePitchBend.value(2.0, 0.5, 64);
```

CC74 has an effect only when the Ableton instrument or an explicit MIDI mapping
responds to it. Conventional MIDI pitch bend affects every note on its channel; set
the receiving instrument's bend range to match `tonePitchBendRange` (±2 semitones by
default). Mode changes, mute, disable, disconnect, panic, and stop restore neutral
bend without retriggering held notes.

No pitch bend is sent, so unrelated notes cannot be bent. Spectrum rhythm remains a
separate Bus 4 output with its own selection, expression, timing, and cleanup state.

### Ableton Live routing on macOS

1. In **Audio MIDI Setup → MIDI Studio**, enable IAC Driver and create a port such
   as `Bus 3 - Ableton Live`.
2. In Ableton **Settings → Link, Tempo & MIDI**, enable **Track** input for that IAC
   port. Remote and Sync are unnecessary.
3. Create three instrument tracks. Select the IAC port and input channels 1, 2,
   and 3 for temperature, humidity, and pressure. These are the only channels the
   spectrum sketch may use. Monitor **In**, or use **Auto**
   and arm the tracks.
4. Run `~spectrumMidiStatus.value`; ready data should show `connected=true` and
   active notes. Use an instrument that supports polyphonic aftertouch for
   independent note expression.
5. Before changing live sets, call `~spectrumMidiPanic.value` or stop normally.

Live verification:

```supercollider
MIDIClient.destinations.postln;
~spectrumSetMidiDestination.value("IAC Driver", "Bus 3 - Ableton Live");
~spectrumSetMidiEnabled.value(true);
~spectrumMidiStatus.value;
~spectrumMute.value(\temperature, true);   // channel 1 releases
~spectrumMute.value(\temperature, false);  // channel 1 returns
~spectrumMidiPanic.value;
```

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

`~spectrumAudioStatus.value` separately reports routing health, configured and
active hardware buses, the private audio bus, output node, bank count, ready banks,
nonzero amplitude targets, gains, and the latest output-stage peak. The peak is
measured after `masterGain` and before the existing limiter. A recent zero peak with
nonzero targets points to the bank/internal-bus path; missing meter replies point to
a stale or inactive output synth. The command warns when no complete frames exist,
when ready frames produce zero targets, or when routing is incomplete.

`~spectrumTestTone.value` injects a quiet, self-freeing 440 Hz tone into the private
spectrum bus immediately before the spectrum output synth. It therefore exercises
the actual master gain, limiter, shutdown envelope, and selected hardware bus. It
does not bypass the spectrum output stage and cannot remain sounding indefinitely.

## Tests and manual checks

On macOS, from this repository:

```sh
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/live-spectrum-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/spectrum-tone-selection-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/selection-hysteresis-test.scd
```

The fixture uses loopback UDP 19000, never registers with the Pi, and keeps master
gain at zero. It exercises real native OSC decoding, two-chunk frames in reverse
order, duplicates, malformed packets, metadata conflicts, pending expiry, epoch
changes, invalidation, timeout, both amplitude modes, live pitch endpoints and
bounds, independent waveform selection and compensation, worst-case target
clamping, gain/mute controls, persistent synth nodes, heartbeat, and
start/stop/restart cleanup.

The MIDI fixture replaces `MIDIOut` with an in-memory recorder, so no physical or
virtual synthesizer is required. It verifies default connection attempts and clear
failure state, 36/48/60-semitone mappings, collision aggregation, sensor channels,
polyphonic aftertouch, live channel and pitch remapping, explicit disable/re-enable,
mode/gain/mute changes, invalid and stale frame note-offs, panic, and stop cleanup.
`tests/spectrum-rhythm-selection-test.scd` deterministically verifies per-band and
top-N selection, per-band/per-sensor notes, mute, and readiness without a MIDI device.

For Windows, stop the old sketch, evaluate `~cwtStop.value` if it is loaded, then
evaluate all of `live-spectrum.scd`. Within a few analysis cycles:

```supercollider
~spectrumStatus.value;
```

should show `frame` above zero, `scales=48`, `backgrounds=48`, and `state=ready` for
active streams. Use `~spectrumTestTone.value` to verify the spectrum output path.
If the tone works but the banks do not, inspect one received
scale and temporarily raise a musical gain within the documented safety ceiling;
do not change the protocol validator or limiter.
