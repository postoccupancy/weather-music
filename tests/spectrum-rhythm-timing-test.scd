// Spectrum rhythm timing quantization and shared phase alignment; no MIDI device.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, config, run, desired, info, phase;
(root +/+ "midi-rhythm.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
config = (rhythmSourceMinHz:0.05, rhythmSourceMaxHz:1, rhythmPulseMinHz:1, rhythmPulseMaxHz:4,
    rhythmTiming:\quantized, rhythmQuantizeReferenceHz:2, rhythmQuantizeRatios:[0.5,1,2],
    rhythmQuantizeHysteresis:0.1, rhythmQuantizeAlign:true, rhythmExpression:\phase,
    rhythmPhaseMaxCycles:0.25, rhythmPhaseSmoothing:2, rhythmVelocityInputFloor:0,
    rhythmVelocityInputCeiling:1, rhythmConstantVelocity:80);
info = ~weatherRhythmQuantizedRate.value(1.3, nil, config);
check.value(info[\rate] == 1 and: { info[\ratio] == 0.5 }, "rate maps to nearest reference ratio");
info = ~weatherRhythmQuantizedRate.value(1.45, 0.5, config);
check.value(info[\ratio] == 0.5, "rate hysteresis holds near ratio boundary");
info = ~weatherRhythmQuantizedRate.value(1.7, 0.5, config);
check.value(info[\ratio] == 1, "rate hysteresis switches after decisive crossing");

run = (rhythmOut:\mock, rhythmConnected:false, rhythmSources:Dictionary.new,
    rhythmGates:Dictionary.new, rhythmAlignmentAnchor:0.0);
desired = Dictionary["a" -> (key:"a", channel:0, note:36, sourceHz:0.05, level:0.5, active:true)];
~weatherRhythmSync.value(run, desired, 0.0, config, { });
run[\rhythmConnected] = true; ~weatherRhythmStep.value(run, 0.5, config, { });
desired["b"] = (key:"b", channel:1, note:38, sourceHz:0.05, level:0.5, active:true);
~weatherRhythmSync.value(run, desired, 0.5, config, { });
check.value((run[\rhythmSources]["a"][\phase] - run[\rhythmSources]["b"][\phase]).abs < 0.000001,
    "later quantized source joins shared alignment phase");
phase = run[\rhythmSources]["a"][\phase]; config[\rhythmTiming] = \continuous;
~weatherRhythmSync.value(run, desired, 0.5, config, { });
check.value(run[\rhythmSources]["a"][\phase] == phase, "timing mode change preserves oscillator phase");
config[\rhythmTiming] = \quantized; ~weatherRhythmSync.value(run, desired, 0.5, config, { });
check.value(run[\rhythmSources]["a"][\phase] == phase, "return to quantized timing does not reset phase");
~weatherRhythmStep.value(run, 0.75, config, { });
check.value(run[\rhythmSources]["a"][\phaseOffset] > 0, "quantized timing preserves phase expression");
"ALL SPECTRUM RHYTHM TIMING TESTS PASSED".postln; 0.exit;
)
