# Live CWT sine sketch

For the full 48-scale temperature, humidity, and pressure instrument, see
[SPECTRUM.md](SPECTRUM.md). `live-cwt.scd` and `live-spectrum.scd` may run together:
they share one reference-counted native router lease and keep independent OSC
handlers, synthesis groups, gains, and hardware output routes.

For phase-accumulated pulse output on the independent Ableton rhythm bus, see
[RHYTHM.md](RHYTHM.md). Rhythm is disabled by default and can run with or without
the existing sustained MIDI tones.

Open [`controls.scd`](controls.scd) beside both instrument files for the tracked
voice, spectrum, routing, diagnostic, and lifecycle commands used during a live
performance. Evaluate individual lines rather than the whole file; it deliberately
includes mutually exclusive examples such as mute/unmute and stop/start.

`live-cwt.scd` is a native SuperCollider client for Electric Sea. It registers with
`192.168.0.41:5005`, receives OSC on UDP 9000, and plays at most four oscillators
(including release tails). No intermediary or Electric Sea changes are needed.

## Start and stop

1. Open `live-cwt.scd` in the SuperCollider IDE on the receiving Mac. Make sure UDP
   9000 is not owned by another application. Start with your speakers/headphones low.
2. Edit the configuration at the top if necessary. Evaluate the **entire block**
   (select all, Command-Return). The sketch boots the local audio server if needed;
   when doing so it disables unused microphone input to avoid input/output rate
   mismatches. It does not change an already-running server's audio configuration.
3. Look for `CWT running`. Ready active voices should appear in diagnostics within
   five seconds of the router's snapshot. Defaults are the browser's continuous
   pitch mapping and volume 0.8. Tracked MIDI also connects automatically to
   `IAC Driver / Bus 3 - Ableton Live`; a missing destination produces a diagnostic
   listing the available destinations while audio continues normally.
4. Evaluate `~cwtStop.value;` to release this sketch's lease ownership and free its
   group, synths, receive callback and update routine. The router is unsubscribed
   only when the last Weather Music owner stops. Command-period also cleans up.
5. Evaluate `~cwtStart.value;` to restart, or re-evaluate the whole file. Re-evaluation
   stops the previous instance before installing another one. It resets controls.

SuperCollider's installed Main API opens additional UDP ports for the lifetime of
sclang and has no closeUDPPort method. Stop removes this sketch's callback and lease
ownership; 9000 remains language-owned and is reused on restart. Quit/restart the
language to release the socket to another application.

## Controls

Change these live in the IDE; updates take effect on the next 100 ms control tick:

```supercollider
~cwtConfig[\masterVolume] = 0.4;       // 0 mutes; browser default is 0.8
~cwtConfig[\pitchMode] = \continuous; // default, unquantized
~cwtConfig[\pitchMode] = \quantized;  // nearest semitone with pitch hysteresis
~cwtConfig[\pitchHysteresis] = 0.1;   // margin beyond the nearest-note boundary
~cwtConfig[\deviceFilter] = "indoor-sky";
~cwtConfig[\signalFilter] = "temperature";
~cwtConfig[\deviceFilter] = nil;      // all devices
~cwtConfig[\signalFilter] = nil;      // all signals
~cwtConfig[\maxPolyphony] = 4;        // nonnegative integer
~cwtSetMinConfidence.value(0.85);     // 0..1; default 0
~cwtSetBaseNote.value(48);            // MIDI coordinate 24..72
~cwtSetPitchSpan.value(36);           // semitones 12..72
~cwtSetWaveform.value(\triangle);     // sine, triangle, saw
~cwtSetGain.value(\temperature, 1.0); // 0..4
~cwtMute.value(\temperature, true);   // smooth silence; selection retained
~cwtSetOutputBus.value(0);            // zero-based hardware outputs 1–2
~cwtConfig[\frequencySmoothing] = 0.18; // exponential time constant, seconds
~cwtConfig[\amplitudeSmoothing] = 0.35;
```

### Tracked-voice MIDI and Ableton Live 12

Tracked MIDI is enabled by default and follows the same selected tracker identities,
pitch mapping, confidence normalization, sensor gain, and mute state as the audio
instrument. It does not use the full-spectrum amplitude targets. Each active tracker
gets the lowest free MIDI channel from channels 4–16, up to `maxPolyphony`. Channels
1–3 are reserved for the full-spectrum temperature, humidity, and pressure banks.
Its nearest MIDI note is held
while ordinary channel pitch bend carries the fractional pitch. If motion exceeds
the configured bend range, the sender releases and rebases that one note on the same
channel. Other voices are unaffected. Channel pressure carries the smoothed effective
amplitude (defaults: floor 0.005, ceiling 0.18, smoothing 0.2 seconds, deadband 1).

In Audio MIDI Setup, enable the IAC Driver and create `Bus 3 - Ableton Live`. In
Ableton Live 12, enable that port for Track input. Route spectrum tracks from channels
1–3 and the tracked instrument from channels 4–16. Use an MPE-compatible tracked
instrument with its pitch-bend range set to **±2 semitones**. This is MPE-style
per-voice allocation using standard note, pitch-bend, and channel-pressure messages;
the sketch does not send MPE zone-configuration RPNs. Configure the instrument so
channels 4–16 remain independent. A non-MPE instrument must likewise preserve incoming
channels and respond to channel pressure.

```supercollider
~cwtSetMidiDestination.value("IAC Driver", "Bus 3 - Ableton Live");
~cwtSetMidiEnabled.value(true);       // false releases held notes
~cwtSetMidiBendRange.value(2);        // 0.25..24; match the Ableton instrument
~cwtSetMidiExpression.value(0.005, 0.18, 0.2, 1, 64);
~cwtMidiStatus.value;                 // tracker, Hz, coordinate, note, channel, bend, expression
~cwtMidiPanic.value;                  // cleanup on tracked channels 4-16 only
~cwtMidiResync.value;                 // release/resend notes after changing instruments
```

MIDI initialization happens before audio-server boot and expression does not include
`masterVolume`, so MIDI output is independent of the SuperCollider output level and
hardware bus. Stop, restart, Cmd-period, timeout, unready streams, deselection, and
mute all release held notes and reset their channels. Changing the destination or
bend range also panics first. Full-spectrum MIDI remains independent on channels 1–3.
Resync rebuilds tracked MIDI from the current selection without restarting OSC
reception or audio Synths.

Other controls: `baseNote` (48), `pitchSpan` (36 semitones), `releaseSmoothing` (0.6 s),
`releaseSeconds` (2.5 s), `trafficTimeout` (15 s), `diagnosticsInterval` (5 s).
Use positive smoothing/timeout settings. Release settings apply to newly created
synths. Confidence filtering occurs before ranked polyphony selection. Lowering
polyphony or raising the threshold releases excess synths before their slots are reused;
the old tails can persist for 2.5 seconds. Raising the cap above four explicitly
changes the instrument's default limit. A summed stereo limiter catches exceptional
peaks after the existing per-voice envelopes and master gain.

Legacy `\midi` remains nearest-semitone mode without hysteresis and `\midiOutput`
remains an alias for quantized mode with hysteresis. Pitch hysteresis affects only
semitone changes; it is separate from confidence-based tracker selection.

Stop/start after changing `routerIP`, `routerPort` or `localPort`. The existing
router accepts **only localPort 9000** despite exposing this setting for future
routers/testing. A LAN or Tailscale IPv4 address works; use the address reachable
from this Mac. Allow inbound UDP 9000 and outbound UDP 5005. The router's UDP output
source port is ephemeral: the client filters the sender IP, not its source port.
Registration occurs after audio startup and handlers are installed. One shared OSC
heartbeat every ten seconds renews the 30-second lease and obtains a fresh snapshot.

Tracked voices default to hardware bus 0 (outputs 1–2). Spectrum defaults to bus 2
(outputs 3–4). See [multichannel routing](ROUTING.md) for BlackHole/Ableton setup,
stereo fallback behavior, monitoring, and hardware limitations.

## Behavior and diagnostics

The full `device/signal/id` is the dictionary key. Repeated updates set existing
synth controls; they do not retrigger oscillators. Selection prioritizes confidence,
then incumbent synths on ties, then lexicographic full identity. Higher-confidence
voices can displace incumbents. New voices wait for outgoing release tails to finish,
so a steal never temporarily exceeds the cap. Per-sensor mute drives selected voice
amplitudes smoothly to zero without changing selection or tracker state. Diagnostics
report eligible, selected, releasing, and allocated counts separately.

The sketch waits for a ready authoritative list before sounding a stream. Inactive
packets, missing IDs, unready lists and 15 seconds without stream/voice traffic
release voices. Timestamps remain source metadata; local monotonic receipt time
is used only for the watchdog. Unready state, silence and backwards source time
retire old identities. A subsequent reused ID gets a fresh synth after its old tail.
Diagnostics print every five seconds, not per packet, including identity, input Hz,
audio Hz, MIDI note in quantized modes, confidence and active/release state.

UDP has no ordering guarantee or epoch identifier. A reordered older frame can
cause a conservative release; an entirely missed restart with increasing timestamps
and identical IDs cannot be distinguished from continuity. Five-second router
snapshots and heartbeat snapshots repair ordinary loss. This sketch does not infer
sub-second onset times from the CWT summaries.

See [mapping parity](MAPPING-PARITY.md) for exact formulas and deliberate differences.

## Validation

With SuperCollider installed, run the native local fixture test:

```sh
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/live-cwt-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/controls-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/midi-rhythm-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/rhythm-expression-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/selection-hysteresis-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/spectrum-rhythm-selection-test.scd
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/spectrum-tone-selection-test.scd
```

It boots local audio **muted**, uses isolated loopback OSC on 19001/50055 (no Pi
subscription), and tests mapping, confidence/polyphony selection, sensor gain/mute,
waveforms, output fallback, node continuity, release, readiness, ID reuse,
heartbeat, timeout, independent bends, note rebasing, expression, MIDI cleanup, and
repeated cleanup. The rhythm fixtures use explicit timestamps and mocked MIDI to test
phase, velocity, Euclidean density, global event budgets, overlapping gate ownership,
selection hysteresis, spectrum tone/rhythm independence, band/top-N selection, and note mapping.
`tests/live-concurrent-test.scd` verifies
both instruments share a lease and that stopping one does not unsubscribe the other.
`tests/controls-test.scd` executes the control panel against API spies to catch
syntax errors and stale command names without starting audio or contacting the router.
For an audible check in the IDE, start the sketch normally, switch between
`continuous` and `midi`, and confirm gliding/quantized pitches without node restarts.
Check `~cwtRun[\synths].size` (at most four by default), then stop and confirm silence.

Validated on this Mac with SuperCollider 3.14.1: the native fixture suite passed,
and an 18-second muted live test against `192.168.0.41` received humidity, pressure,
RMS and temperature streams, with four synths selected from seven active records
at the final snapshot. It unsubscribed and shut down cleanly. Speaker listening
was not tested; use the IDE steps above for the audible check.
