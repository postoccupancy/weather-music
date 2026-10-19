# Environmental rhythm MIDI

`live-cwt.scd` and `live-spectrum.scd` can emit independent rhythmic MIDI pulses
alongside their sustained MIDI tones. Sustained tones remain enabled by default on
`IAC Driver / Bus 3 - Ableton Live`; rhythm is enabled by default and uses the
separate configurable destination `IAC Driver / Bus 4 - Ableton Rhythm`.

Both outputs retain the channel ownership used by the sustained instruments:

- spectrum temperature, humidity, and pressure: MIDI channels 1, 2, and 3;
- tracked voices: MIDI channels 4–16, allocated deterministically by tracker identity.

Each output has its own connection, note gates, panic, resync, and cleanup. A missing
Bus 4 prints the configured destination and available ports without disconnecting or
silencing Bus 3. Disabling or changing one output releases notes only on that bus.

## Timing model

Every rhythmic source owns a phase accumulator. The 20 ms rhythm loop advances phase
from elapsed monotonic time and the source's mapped rate; OSC packet arrival does not
trigger notes. Frequency changes alter subsequent phase speed without resetting phase,
so independent sources drift naturally. There is no BPM clock, bar, grid, or tempo
quantization.

Environmental frequencies from 0.05–1 Hz map logarithmically to 0.5–4 pulse Hz by
default (30–240 pulses per minute). These bounds are explicit time compression:

```supercollider
~cwtSetRhythmRate.value(0.5, 4.0);
~spectrumSetRhythmRate.value(0.5, 4.0);
```

Both spectrum and tracked-voice rhythm timing default to `quantized`, which snaps
each mapped rate to an allowed ratio of a reference pulse. The default 2 Hz reference
and `[0.5, 1, 2]` ratios yield 1, 2, or 4 Hz. Rate hysteresis prevents small mapped-rate
changes near a boundary from repeatedly changing ratios. `continuous` remains
available and uses mapped rates directly without a shared clock.

```supercollider
~spectrumSetRhythmTiming.value(\continuous);
~spectrumSetRhythmQuantization.value(2.0, [0.5, 1, 2], 0.10, true);
~spectrumSetRhythmTiming.value(\quantized);

~cwtSetRhythmTiming.value(\continuous);
~cwtSetRhythmQuantization.value(2.0, [0.5, 1, 2], 0.10, true);
~cwtSetRhythmTiming.value(\quantized);
```

When alignment is enabled, quantized sources created while the quantized mode is
already active derive their cycle position from one monotonic anchor. Sources added
later join that same grid; removing a source does not affect the others. Switching a
running source between timing modes, or changing its quantized ratio, preserves its
current oscillator phase to avoid abrupt retriggers. Therefore switching an already
running collection into quantized mode does not forcibly realign those existing
sources; start in quantized mode when a shared initial downbeat is required. Rhythm
expression, including phase displacement, is applied after timing quantization.

Pulses default to 80 ms and MIDI velocities 35–110. Duration is controlled separately
from velocity. Tracked velocity follows the
existing effective amplitude after confidence, normalization, sensor gain, and mute.
Spectrum velocity follows scale significance. Event bursts are bounded per scheduler
step. Shared channel/note gates retain an owner per source, so one source ending does
not prematurely turn off another source's overlapping note.

`rhythmMaxEventsPerTick` is a global budget across all sources. The scheduler rotates
the first source considered on later ticks, so a dense source set cannot let one
source monopolize the budget or permanently starve later sources.

## Expression modes

Tone/rhythm source selection and rhythm expression are independent. Both sketches
support the same four mutually exclusive expression modes:

- `off`: fixed velocity; amplitude does not alter rhythm expression.
- `velocity`: maps normalized amplitude to the configured velocity range. This is the default.
- `phase`: uses fixed velocity and smoothly displaces pulse phase by at most 0.25 cycles by default.
- `euclidean`: uses fixed velocity and maps amplitude to the number of evenly distributed hits.

`SetRhythmVelocity` supplies the normalization input range in every mode. The velocity
output range is used only by `velocity`; the other modes use `rhythmConstantVelocity`.
Phase displacement is bounded and never accumulates. The underlying oscillator keeps
running while the offset moves in or out, preventing retriggers when modes change.

In Euclidean mode the mapped environmental pulse rate is the **whole pattern-cycle
frequency**. With eight steps, the diagnostic step rate is eight times the cycle rate.
Density changes take effect only at a cycle boundary and have hysteresis; every source
retains its independent phase and there is no shared clock.

```supercollider
~cwtSetRhythmExpression.value(\velocity); // \off, \phase, or \euclidean
~cwtSetRhythmConstantVelocity.value(80);
~cwtSetRhythmPhase.value(0.25, 2.0);
~cwtSetRhythmEuclidean.value(8, 1, 8, 0.08); // steps, min/max hits, density hysteresis

~spectrumSetRhythmExpression.value(\phase);
~spectrumSetRhythmConstantVelocity.value(80);
~spectrumSetRhythmPhase.value(0.25, 2.0);
~spectrumSetRhythmEuclidean.value(8, 1, 8, 0.08);
```

## Tracked voices

The existing confidence selection and four-voice default are unchanged. A selected
tracker keeps its rhythmic phase while its identity remains selected. The first four
allocated channel slots use notes 36, 38, 42, and 45. Replacement, mute, stale data,
unready state, stop, and restart release outstanding gates.

```supercollider
~cwtSetRhythmDestination.value("IAC Driver", "Bus 4 - Ableton Rhythm");
~cwtSetRhythmNotes.value([36, 38, 42, 45]);
~cwtSetRhythmPulseDuration.value(0.08);
~cwtSetRhythmVelocity.value(0.0, 1.0, 35, 110);
~cwtSetSelectionHysteresis.value(0.20, 30.0);       // sustained/audio selection
~cwtSetRhythmSelectionHysteresis.value(0.20, 30.0); // independent rhythm selection
~cwtSetRhythmEnabled.value(true);
~cwtRhythmStatus.value;
~cwtRhythmResync.value;
~cwtRhythmPanic.value;
```

## Full spectrum

The second selection argument is a count from 1 to 48. The 48 CWT scales are divided
into that many contiguous frequency bands, ordered from slow to fast, with sizes that
differ by at most one scale. Three bands contain 16 scales each; six contain eight.
`perBand` chooses the most significant eligible scale in each band and keeps that
scale's identity and phase while it remains the winner. `topN` instead chooses the N
most significant scales across the whole sensor spectrum.

`fixedBand` creates one persistent source for every automatic band. Its environmental
frequency is the geometric mean of the band's fixed scale frequencies, so its mapped
pulse rate never drifts with significance. Its velocity follows the mean current
significance of every scale in the band. At or below `rhythmActivityThreshold` (zero
by default), note-ons stop while phase continues to advance.

With `perBand` note mapping, band notes are ordered slow to fast. If the note array is
shorter than N it repeats with `wrapAt`; an empty array is rejected. `perSensor` uses
temperature 36, humidity 38, and pressure 42 for every source.

```supercollider
~spectrumSetRhythmDestination.value("IAC Driver", "Bus 4 - Ableton Rhythm");
~spectrumSetRhythmSelection.value(\perBand, 3);
~spectrumSetRhythmSelection.value(\fixedBand, 6);
~spectrumSetRhythmSelection.value(\topN, 4);
~spectrumSetRhythmNoteMapping.value(\perBand); // or \perSensor
~spectrumSetRhythmNotes.value([36, 38, 42], 36, 38, 42);
~spectrumSetRhythmPulseDuration.value(0.08);
~spectrumSetRhythmVelocity.value(0.0, 4.0, 35, 110);
~spectrumSetRhythmActivityThreshold.value(0.0);
~spectrumSetRhythmSelectionHysteresis.value(0.20, 30.0);
~spectrumSetRhythmEnabled.value(true);
~spectrumRhythmStatus.value;
~spectrumRhythmResync.value;
~spectrumRhythmPanic.value;
```

The note tables remain available as `rhythmBandNotes` and `rhythmSensorNotes` in
`~spectrumConfig`; frequency boundaries are derived from the received scale order.

## Selection hysteresis

`perBand` and `topN` retain valid incumbents. A challenger replaces the weakest
incumbent only after that incumbent's minimum residence time and only when the
challenger exceeds it by the configured relative margin. Invalid, stale, muted, and
unavailable sources leave immediately. A margin and residence of zero reproduce
immediate ranking. `fixedBand` has no winner and therefore needs no selection
hysteresis. Tracked sustained/audio and rhythm selections keep separate state, so one
can remain stable while the other changes.

## Ableton Live 12 Intro

In Audio MIDI Setup, enable IAC Driver and create both named buses. Keep the existing
sustained instruments listening to Bus 3. Create separate drum or percussion tracks
listening to Bus 4: channels 1–3 for spectrum banks and channels 4–16 for tracked
voices. Example General MIDI-style mappings are kick 36, snare 38, closed hi-hat 42,
and low tom 45. Ableton Live Intro can route each incoming channel to a separate track;
use Monitor **In**, or **Auto** with the track armed.

`~cwtRhythmResync` and `~spectrumRhythmResync` release current gates and immediately
re-articulate active sources after an Ableton instrument change. They do not restart
OSC reception, analysis state, audio synthesis, or the sustained Bus 3 notes.
