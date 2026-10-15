/* Executes controls.scd against spies: validates syntax and public API names. */
(
var calls = List.new, controlsPath, check;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };

~cwtConfig = Dictionary.new;
~spectrumConfig = Dictionary.new;
[
    \cwtSetMinConfidence, \cwtSetBaseNote, \cwtSetPitchSpan, \cwtSetWaveform,
    \cwtSetGain, \cwtMute, \cwtSetOutputBus, \cwtStatus, \cwtStop, \cwtStart,
    \spectrumSetMode, \spectrumSetGain, \spectrumMute, \spectrumSetBaseNote,
    \spectrumSetPitchSpan, \spectrumSetWaveform, \spectrumSetOutputBus,
    \spectrumStatus, \spectrumInspect, \spectrumStop, \spectrumStart
].do { |name| currentEnvironment.put(name, { |...args| calls.add([name] ++ args) }) };

controlsPath = thisProcess.nowExecutingPath.dirname +/+ "../controls.scd";
controlsPath.load;

check.value(~cwtConfig[\maxPolyphony] == 4, "tracked configuration commands execute");
check.value(~spectrumConfig[\masterGain] == 0.1, "spectrum configuration commands execute");
check.value(calls.any { |call| call[0] == \cwtSetMinConfidence }, "tracked control API is callable");
check.value(calls.any { |call| call[0] == \spectrumSetWaveform }, "spectrum control API is callable");
check.value(calls.any { |call| call[0] == \cwtSetOutputBus }, "tracked routing control is callable");
check.value(calls.any { |call| call[0] == \spectrumSetOutputBus }, "spectrum routing control is callable");
check.value(calls.any { |call| call[0] == \cwtStart } and: { calls.any { |call| call[0] == \spectrumStop } },
    "lifecycle controls are callable");

"ALL CONTROLS TESTS PASSED".postln;
0.exit;
)
