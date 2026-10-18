// Deterministic shared rhythm-engine fixture; no audio, OSC, clock, or MIDI device.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, messages = List.new, emit, run, config, desired;
(root +/+ "midi-rhythm.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
emit = { |out, type, channel, note=0, value=0| messages.add([type, channel, note, value]) };
run = (rhythmOut: \mock, rhythmConnected: true, rhythmSources: Dictionary.new, rhythmGates: Dictionary.new);
config = (rhythmSourceMinHz:0.05, rhythmSourceMaxHz:1.0, rhythmPulseMinHz:2.0, rhythmPulseMaxHz:2.0,
    rhythmPulseDuration:0.2, rhythmVelocityInputFloor:0, rhythmVelocityInputCeiling:1,
    rhythmVelocityMin:20, rhythmVelocityMax:120, rhythmMaxEventsPerTick:8);
desired = Dictionary[
    "a" -> (key:"a", channel:3, note:36, sourceHz:0.05, level:0.25),
    "b" -> (key:"b", channel:3, note:36, sourceHz:1.0, level:0.75)
];
~weatherRhythmSync.value(run, desired, 0.0, config, emit);
run[\rhythmSources]["b"][\phase] = 0.6;
~weatherRhythmStep.value(run, 0.2, config, emit);
check.value(messages.count { |m| m[0] == \noteOn } == 1
    and: { messages.detect { |m| m[0] == \noteOn }[3] == 95 }, "independent starting phases produce offset pulses");
messages.clear;
run[\rhythmSources].values.do { |source| source[\phase] = 0.9; source[\lastTime] = 0.2 };
~weatherRhythmStep.value(run, 0.3, config, emit);
check.value(messages.count { |m| m[0] == \noteOn } == 2, "independent sources pulse from accumulated phase");
check.value(messages.select { |m| m[0] == \noteOn }.collect { |m| m[3] }.asSet.size == 2,
    "velocity follows independent source levels");
check.value(run[\rhythmGates]["3/36"][\owners].size == 2, "shared note gate tracks both owners");
desired.removeAt("a"); messages.clear; ~weatherRhythmSync.value(run, desired, 0.35, config, emit);
check.value(messages.count { |m| m[0] == \noteOff } == 0, "removing one owner does not end an overlapping note");
run[\rhythmSources]["b"][\phase] = 0.25; config[\rhythmPulseMinHz] = 1.0; config[\rhythmPulseMaxHz] = 4.0;
desired["b"][\sourceHz] = 0.2; ~weatherRhythmSync.value(run, desired, 0.35, config, emit);
check.value(run[\rhythmSources]["b"][\phase] == 0.25, "frequency update retains phase before the next step");
~weatherRhythmStep.value(run, 0.45, config, emit);
check.value(run[\rhythmSources]["b"][\phase] > 0.35, "new frequency changes subsequent phase rate");
messages.clear; ~weatherRhythmStep.value(run, 0.56, config, emit);
check.value(messages.any { |m| m[0] == \noteOff }, "gate ends after its final owner expires");
messages.clear; ~weatherRhythmResync.value(run, 0.7, config, emit);
check.value(messages.any { |m| m[0] == \noteOn } and: { run[\rhythmSources].size == 1 }, "rhythm resync resends active sources");
messages.clear; ~weatherRhythmPanic.value(run, (3..15), emit, true);
check.value(run[\rhythmSources].isEmpty and: { run[\rhythmGates].isEmpty }
    and: { messages.every { |m| m[1] >= 3 } }, "panic clears sources within owned channels");
"ALL RHYTHM ENGINE TESTS PASSED".postln; 0.exit;
)
