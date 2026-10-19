// Deterministic spectrum rhythm selection and fixed-band fixture; no server startup.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, makeRows, rows, run, desired, st;
var partitions, source, oldHz, oldRate, oldPhase, silentRows, expectedVelocity;
~spectrumAutoStart = false;
(root +/+ "live-spectrum.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
makeRows = { |levels|
    Array.fill(48, { |index|
        var hz = 0.05 * (20 ** (index / 47));
        [hz, levels.wrapAt(index), 0, 0, 1.0, 1]
    })
};
rows = makeRows.value(Array.series(48, 1.0, 1.0));
~spectrumConfig[\rhythmVelocityMin] = 35; ~spectrumConfig[\rhythmVelocityMax] = 110;
~spectrumSetRhythmPulseDuration.value(0.12);
check.value(~spectrumConfig[\rhythmPulseDuration] == 0.12
    and: { ~spectrumConfig[\rhythmVelocityMin] == 35 } and: { ~spectrumConfig[\rhythmVelocityMax] == 110 },
    "spectrum pulse-duration control does not alter velocity mapping");

[[1, [48]], [3, [16,16,16]], [6, [8,8,8,8,8,8]], [48, Array.fill(48, 1)],
    [5, [10,10,10,9,9]]].do { |example|
    partitions = ~spectrumRhythmPartitions.value(rows, example[0]);
    check.value(partitions.collect(_.size) == example[1], "% automatic band partition sizes".format(example[0]));
    check.value(partitions.flat.asSet.size == 48, "% bands cover each scale once".format(example[0]));
};

st = (signal:\temperature, ready:true, muted:false, rows:rows);
run = (streams:Dictionary["temperature" -> st], rhythmSources:Dictionary.new,
    rhythmGates:Dictionary.new, rhythmOut:\mock, rhythmConnected:true);
~spectrumConfig[\rhythmSelection] = \perBand; ~spectrumConfig[\rhythmSelectionCount] = 3;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.size == 3, "perBand selects one scale from each automatic band");
check.value(desired.values.collect { |item| item[\scale] }.asSet == Set[15,31,47],
    "perBand retains the winning scale identity");
check.value(desired.values.collect { |item| item[\note] }.asSet == Set[36,38,42],
    "perBand maps slow-to-fast band notes");

~spectrumConfig[\rhythmSelection] = \topN; ~spectrumConfig[\rhythmSelectionCount] = 2;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.values.collect { |item| item[\scale] }.asSet == Set[46,47],
    "topN selects strongest scales across the entire sensor");

~spectrumConfig[\rhythmBandNotes] = [36,38]; ~spectrumConfig[\rhythmSelection] = \perBand;
~spectrumConfig[\rhythmSelectionCount] = 3;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.values.select { |item| item[\band] == 2 }.first[\note] == 36,
    "short band-note arrays repeat deterministically");
~spectrumConfig[\rhythmBandNotes] = [36,38,42];

~spectrumConfig[\rhythmSelection] = \fixedBand; ~spectrumConfig[\rhythmSelectionCount] = 3;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.size == 3 and: { desired.keys.asArray.every { |key| key.contains("/band/") } },
    "fixedBand creates persistent band identities");
source = desired["temperature/band/0"];
check.value((source[\significance] - 8.5).abs < 0.000001, "fixedBand expression is mean significance");
expectedVelocity = ~weatherRhythmVelocity.value(8.5, ~spectrumConfig);
~weatherRhythmSync.value(run, desired, 0.0, ~spectrumConfig, ~spectrumRhythmEmit);
source = run[\rhythmSources]["temperature/band/0"];
oldHz = source[\sourceHz]; oldRate = source[\rateHz]; source[\phase] = 0.25; oldPhase = source[\phase];
st[\rows] = makeRows.value(Array.fill(48, 0.5));
desired = ~spectrumRhythmDesired.value(run);
~weatherRhythmSync.value(run, desired, 0.1, ~spectrumConfig, ~spectrumRhythmEmit);
source = run[\rhythmSources]["temperature/band/0"];
check.value(source[\sourceHz] == oldHz and: { source[\rateHz] == oldRate } and: { source[\phase] == oldPhase },
    "fixedBand frequency, pulse rate, identity, and phase survive expression changes");
check.value(source[\velocity] == ~weatherRhythmVelocity.value(0.5, ~spectrumConfig)
    and: { expectedVelocity == 110 }, "fixedBand mean significance uses existing velocity mapping");

silentRows = makeRows.value(Array.fill(48, 0.0)); st[\rows] = silentRows;
desired = ~spectrumRhythmDesired.value(run);
~weatherRhythmSync.value(run, desired, 0.2, ~spectrumConfig, ~spectrumRhythmEmit);
source = run[\rhythmSources]["temperature/band/0"]; oldPhase = source[\phase];
~weatherRhythmStep.value(run, 0.7, ~spectrumConfig, ~spectrumRhythmEmit);
check.value(source[\active].not and: { source[\phase] != oldPhase },
    "silent fixed bands suppress output while phase continues");

~spectrumConfig[\rhythmNoteMapping] = \perSensor; st[\rows] = rows;
desired = ~spectrumRhythmDesired.value(run);
check.value(desired.values.every { |item| item[\note] == 36 }, "perSensor maps one note across fixed bands");
st[\ready] = false;
check.value(~spectrumRhythmDesired.value(run).isEmpty, "not-ready spectrum removes rhythmic sources for cleanup");
"ALL SPECTRUM RHYTHM SELECTION TESTS PASSED".postln; 0.exit;
)
