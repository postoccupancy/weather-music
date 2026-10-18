// Deterministic spectrum rhythm selection and mapping fixture; no server startup.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, rows, run, desired, st;
~spectrumAutoStart = false;
(root +/+ "live-spectrum.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
rows = Array.fill(48, { |index|
    var hz = 0.05 * (20 ** (index / 47));
    [hz, 0.001 + (index * 0.0001), 0, 0, 0.000001, 1]
});
st = (signal:\temperature, ready:true, muted:false, rows:rows);
run = (streams:Dictionary["temperature" -> st], rhythmSources:Dictionary.new,
    rhythmGates:Dictionary.new, rhythmOut:\mock, rhythmConnected:true);
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.size == 3, "perBand selects one scale from each band");
check.value(desired.values.collect { |source| source[\note] }.asSet == Set[36,38,42],
    "perBand maps slow medium fast notes");
check.value(desired.values.every { |source| source[\channel] == 0 }, "spectrum rhythm retains sensor MIDI channel");
~spectrumConfig[\rhythmSelection] = \topN; ~spectrumConfig[\rhythmTopN] = 2;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.size == 2 and: { desired.values.collect { |source| source[\scale] }.maxItem == 47 },
    "topN selects the most significant scales");
~spectrumConfig[\rhythmNoteMapping] = \perSensor;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.values.every { |source| source[\note] == 36 }, "perSensor maps one note across selected scales");
st[\muted] = true;
check.value(~spectrumRhythmDesired.value(run).isEmpty, "mute removes spectrum rhythmic sources");
st[\muted] = false; st[\ready] = false;
check.value(~spectrumRhythmDesired.value(run).isEmpty, "not-ready spectrum removes rhythmic sources");
"ALL SPECTRUM RHYTHM SELECTION TESTS PASSED".postln; 0.exit;
)
