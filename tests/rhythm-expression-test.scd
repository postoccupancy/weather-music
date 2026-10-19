// Deterministic expression modes and global scheduler budget; no MIDI device.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, messages = List.new, emit, config, makeRun, run, desired, source, firstOwners, secondOwners;
(root +/+ "midi-rhythm.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
emit = { |out, type, channel, note=0, value=0| messages.add([type, channel, note, value]) };
makeRun = { (rhythmOut:\mock, rhythmConnected:true, rhythmSources:Dictionary.new,
    rhythmGates:Dictionary.new, rhythmCursor:0) };
config = (rhythmSourceMinHz:0.05, rhythmSourceMaxHz:1, rhythmPulseMinHz:1, rhythmPulseMaxHz:1,
    rhythmPulseDuration:0.05, rhythmVelocityInputFloor:0, rhythmVelocityInputCeiling:1,
    rhythmVelocityMin:20, rhythmVelocityMax:120, rhythmConstantVelocity:77,
    rhythmPhaseMaxCycles:0.25, rhythmPhaseSmoothing:2, rhythmEuclideanSteps:8,
    rhythmEuclideanMinHits:1, rhythmEuclideanMaxHits:8, rhythmEuclideanDensityHysteresis:0.08,
    rhythmMaxEventsPerTick:16);

run = makeRun.value;
desired = Dictionary["a" -> (key:"a", channel:0, note:36, sourceHz:0.1, level:0.1, active:true),
    "b" -> (key:"b", channel:1, note:38, sourceHz:0.1, level:0.9, active:true)];
config[\rhythmExpression] = \off; ~weatherRhythmSync.value(run, desired, 0, config, emit);
check.value(run[\rhythmSources].values.every { |item| item[\velocity] == 77 }, "off uses constant velocity");
config[\rhythmExpression] = \velocity; ~weatherRhythmSync.value(run, desired, 0, config, emit);
check.value(run[\rhythmSources]["a"][\velocity] < run[\rhythmSources]["b"][\velocity], "velocity maps environmental level");

run = makeRun.value; desired = Dictionary["p" -> (key:"p", channel:0, note:36, sourceHz:0.1, level:1, active:true)];
config[\rhythmExpression] = \phase; ~weatherRhythmSync.value(run, desired, 0, config, emit);
~weatherRhythmStep.value(run, 0.5, config, emit); source = run[\rhythmSources]["p"];
check.value(source[\phaseOffset] > 0 and: { source[\phaseOffset] < 0.25 }, "phase displacement is smoothed and bounded");
config[\rhythmExpression] = \off; ~weatherRhythmSync.value(run, desired, 0.5, config, emit);
~weatherRhythmStep.value(run, 1.0, config, emit);
check.value(source[\phaseOffset] > 0 and: { source[\phaseOffset] < 0.25 }, "mode switch smoothly removes phase displacement");
check.value(messages.count { |item| item[0] == \noteOn } <= 2, "phase crossings do not burst or repeat");

messages.clear; run = makeRun.value;
desired = Dictionary["e" -> (key:"e", channel:0, note:36, sourceHz:0.1, level:1, active:true)];
config[\rhythmExpression] = \euclidean; ~weatherRhythmSync.value(run, desired, 0, config, emit);
~weatherRhythmStep.value(run, 0.5, config, emit);
check.value(messages.count { |item| item[0] == \noteOn } == 4, "eight-hit Euclidean cycle emits four hits in half a cycle");
desired["e"][\level] = 0; ~weatherRhythmSync.value(run, desired, 0.5, config, emit);
~weatherRhythmStep.value(run, 0.75, config, emit);
check.value(run[\rhythmSources]["e"][\euclideanHits] == 8, "Euclidean density waits for cycle boundary");
~weatherRhythmStep.value(run, 1.01, config, emit);
check.value(run[\rhythmSources]["e"][\euclideanHits] == 1, "Euclidean density updates at cycle boundary");
check.value(~weatherRhythmHits.value(0.45, 4, config) == 4, "Euclidean density hysteresis rejects adjacent jitter");
check.value(~weatherEuclideanHit.value(0, 3, 8) and: { ~weatherEuclideanHit.value(1, 3, 8).not },
    "Euclidean pattern is deterministic and evenly distributed");

messages.clear; run = makeRun.value; desired = Dictionary.new;
144.do { |index| desired[index.asString] = (key:index.asString, channel:index%16,
    note:36+(index%12), sourceHz:0.1, level:1, active:true) };
config[\rhythmExpression] = \off; ~weatherRhythmSync.value(run, desired, 0, config, emit);
run[\rhythmSources].values.do { |item| item[\phase] = 0.99 };
~weatherRhythmStep.value(run, 0.02, config, emit);
check.value(messages.count { |item| item[0] == \noteOn } == 16, "global event budget bounds dense 144-source tick");
check.value(run[\rhythmGates].values.sum { |gate| gate[\owners].size } == 16,
    "global budget admits a bounded source set without stuck ownership");
firstOwners = run[\rhythmGates].values.collect { |gate| gate[\owners].keys }.flat.asSet;
run[\rhythmGates].clear; messages.clear; run[\rhythmSources].values.do { |item| item[\phase] = 0.99 };
~weatherRhythmStep.value(run, 0.04, config, emit);
secondOwners = run[\rhythmGates].values.collect { |gate| gate[\owners].keys }.flat.asSet;
check.value(firstOwners != secondOwners and: { messages.count { |item| item[0] == \noteOn } == 16 },
    "rotating global budget gives later dense sources a fair turn");
"ALL RHYTHM EXPRESSION TESTS PASSED".postln; 0.exit;
)
