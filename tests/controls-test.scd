/* Executes controls.scd against spies: validates syntax and public API names. */
(
var calls = List.new, controlsPath, check;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };

~cwtConfig = Dictionary.new;
~spectrumConfig = Dictionary.new;
~cwtRun = (activeOutputBus: 0); ~spectrumRun = (activeOutputBus: 2);
[
    \cwtSetMinConfidence, \cwtSetBaseNote, \cwtSetPitchSpan, \cwtSetWaveform,
    \cwtSetGain, \cwtMute, \cwtSetOutputBus, \cwtStatus, \cwtStop, \cwtStart,
    \cwtSetMidiDestination, \cwtSetMidiEnabled, \cwtSetMidiBendRange,
    \cwtSetMidiExpression, \cwtMidiStatus, \cwtMidiPanic, \cwtMidiResync,
    \cwtSetToneEnabled, \cwtSetRhythmDestination, \cwtSetRhythmEnabled, \cwtSetRhythmRate,
    \cwtSetRhythmPulse, \cwtSetRhythmVelocity, \cwtSetRhythmNotes, \cwtRhythmStatus, \cwtRhythmResync, \cwtRhythmPanic,
    \spectrumSetMode, \spectrumSetGain, \spectrumMute, \spectrumSetBaseNote,
    \spectrumSetPitchSpan, \spectrumSetWaveform, \spectrumSetOutputBus,
    \spectrumStatus, \spectrumInspect, \spectrumStop, \spectrumStart,
    \spectrumSetMidiDestination, \spectrumSetMidiEnabled, \spectrumSetMidiChannel,
    \spectrumSetMidiExpression, \spectrumMidiStatus, \spectrumMidiPanic,
    \spectrumSetToneEnabled, \spectrumSetRhythmDestination, \spectrumSetRhythmEnabled,
    \spectrumSetRhythmRate, \spectrumSetRhythmPulse, \spectrumSetRhythmVelocity, \spectrumSetRhythmSelection,
    \spectrumSetRhythmBands, \spectrumSetRhythmNotes, \spectrumSetRhythmNoteMapping,
    \spectrumRhythmStatus, \spectrumRhythmResync, \spectrumRhythmPanic
].do { |name| currentEnvironment.put(name, { |...args| calls.add([name] ++ args) }) };

controlsPath = thisProcess.nowExecutingPath.dirname +/+ "../controls.scd";
controlsPath.load;

check.value(~cwtConfig[\maxPolyphony] == 144, "tracked configuration commands execute");
check.value(~spectrumConfig[\masterGain] == 1.0, "spectrum configuration commands execute");
check.value(calls.any { |call| call[0] == \cwtSetMinConfidence }, "tracked control API is callable");
check.value(calls.any { |call| call[0] == \spectrumSetWaveform }, "spectrum control API is callable");
check.value(calls.any { |call| call[0] == \cwtSetOutputBus }, "tracked routing control is callable");
check.value(calls.any { |call| call[0] == \spectrumSetOutputBus }, "spectrum routing control is callable");
check.value(calls.any { |call| call[0] == \spectrumSetMidiDestination }
    and: { calls.any { |call| call[0] == \spectrumSetMidiExpression } }, "spectrum MIDI controls are callable");
check.value([\cwtSetMidiDestination, \cwtSetMidiBendRange, \cwtSetMidiExpression, \cwtMidiResync]
    .every { |name| calls.any { |call| call[0] == name } }, "tracked MIDI controls are callable");
check.value([\cwtSetRhythmEnabled, \cwtSetRhythmRate, \cwtRhythmStatus,
    \spectrumSetRhythmEnabled, \spectrumSetRhythmSelection, \spectrumRhythmStatus]
    .every { |name| calls.any { |call| call[0] == name } }, "rhythm control APIs are callable");
check.value(calls.any { |call| call[0] == \cwtStart } and: { calls.any { |call| call[0] == \spectrumStop } },
    "lifecycle controls are callable");

"ALL CONTROLS TESTS PASSED".postln;
0.exit;
)
