# Electric Sea mapping parity

Reference inspected: `../electric-sea` at commit `9029ffc` (working tree unchanged).
The authoritative Web Audio implementation is **not** the raw `voice-osc.js` feed:
it is the HTML/JavaScript compressed into `PAGE_GZIP_BASE64` in
`router/resident-live.js`, returned by `page()`. To inspect it without modifying
Electric Sea, decode the gzip/base64 constant. `router/resident-live-controls.js`
injects controls and wraps some of those functions before serving the page.

| Reference function / file | Ported behavior |
|---|---|
| `mappedMidiValues`, embedded resident page | Clamp environmental Hz to 0.05–1; logarithmic position; base octave and octave span |
| `mappedAudioFrequency`, embedded page | Continuous or rounded MIDI-to-Hz, A4=440 |
| `createGroup`, embedded page | Continuous default, base octave 3, span 3 octaves, volume 0.8 |
| `hystereticNote`, `syncMidi`, embedded page | Optional `midiOutput` mode uses the existing strict ±0.6-semitone hysteresis |
| `syncAudio`, `createSynthVoice`, embedded page | Sine oscillator, confidence gain, per-device active-count normalization, control smoothing and release |
| `syncReadyAudio` / `activeVoicesForDevice` wrappers, `resident-live-controls.js` | Only ready streams and enabled/selected note streams sound |
| `VoiceTracker.js` | Identity, confidence and active state are consumed as supplied, not tracked again |
| `voice-osc.js`, `docs/cwt-osc.md` | Raw seven-argument voice packets and authoritative stream lists; source timestamps retained |

## Exact pitch formulas

```text
c = clamp(environmentalHz, 0.05, 1)
pos = log2(c / 0.05) / log2(1 / 0.05)
continuousMidi = (baseOctave + 1) * 12 + pos * pitchSpan * 12
quantizedMidi = floor(continuousMidi + 0.5)
audioHz = 440 * 2 ^ ((chosenMidi - 69) / 12)
```

Default `continuous` chooses continuousMidi. `midi` chooses quantizedMidi, exactly
as the browser's **audio** pitch selector does. `midiOutput` additionally keeps the
previous note while `previousNote - 0.6 <= continuousMidi <= previousNote + 0.6`,
matching the existing actual MIDI-output pitch behavior. It still plays a sine:
this sketch does not transmit MIDI, velocities, legato overlaps or CCs. The browser
also has legato/retrigger MIDI transition settings (35 ms overlap); those are note
message behaviors, not alternate frequency normalization or musical scales.
There is no scale quantizer beyond chromatic MIDI rounding and no frequency multiplier.

Examples with the defaults:

| Environmental Hz | Continuous MIDI | Continuous audio Hz | Rounded MIDI | Rounded audio Hz |
|---|---:|---:|---:|---:|
| 0.05 or below | 48 | 130.812783 | 48 | 130.812783 |
| 0.1371254 | 60.123720871 | 263.501942 | 60 | 261.625565 |
| 0.5 | 75.670384326 | 646.822061 | 76 | 659.255114 |
| 1 or above | 84 | 1046.502261 | 84 | 1046.502261 |

## Gain and smoothing

The browser does **not** map strength to audio gain. It uses:

```text
norm = 1 / activeVoiceCountForDevice ^ 0.35
voiceGain = clamp(0.18 * confidence, 0.015, 0.22) * norm
outputGain = voiceGain * deviceVolume  // default 0.8
```

The sketch uses the same formula and counts all eligible active voices per device
before applying its four-voice selection cap. Filters exclude disabled streams,
as the injected browser note-enable controls do. One global volume replaces the
browser's independently adjustable device volumes; equal defaults match. Raw
strength and environmental phase are retained in records but do not alter sine
gain or phase, matching `syncAudio`. The phase-aware code in the injected controls
is for beat CC generation, not oscillator playback.

Web Audio `setTargetAtTime` constants are frequency 0.18 s, amplitude 0.35 s,
device bus volume 0.12 s and release 0.6 s; oscillators stop after 2.5 s. SC's Lag
parameter uses 60 dB convergence time, so the sketch multiplies the exponential
time constants by ln(1000), rather than incorrectly treating 0.18 s as Lag time.
The initial fade uses an exponential envelope over ln(1000) time constants, a
close approximation to the browser's initially-zero gain approaching its target.
See the [official Lag documentation](https://doc.sccode.org/Classes/Lag.html).

## Known differences and boundaries

- Browser audio has no four-voice cap. This instrument reserves slots through
  release and therefore briefly delays replacement voices. Confidence selection
  is an instrument policy, not a changed pitch mapping.
- The browser's output `DynamicsCompressor` (-8 dB threshold, knee 12, ratio 8,
  attack 0.003, release 0.25) is omitted to keep this first instrument four plain
  sines with no effects. Default four-voice gain stays below full scale; higher
  user volumes/polyphony may clip. This is not a claim of compressor parity.
- SC updates targets on a 100 ms control tick; browser targets update on frames/UI
  events. Oscillator start phase is local; summarized environmental phase is not
  an instantaneous audio phase. No event-time reconstruction is attempted.
- Browser per-device audio buttons and per-stream MIDI enable/channel controls
  become global controls and optional device/signal filters. All ready streams
  are eligible by default, whereas browser audio requires pressing start.
- Explicit stop is immediate; normal inactivity/readiness loss uses the mapped
  0.6-second release and 2.5-second lifetime. Silence/restart guards are additional
  OSC lifecycle safeguards, not changes to frequency normalization.
- No applicable mapping was missing. Beat CC, MIDI routing and controller-range
  settings were inspected but are outside this four-sine sketch.
