// Spectrum sustained-MIDI selection modes; no server or MIDI device.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, levels, rows, targets, st, run, desired;
~spectrumAutoStart = false; (root +/+ "live-spectrum.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
levels = Array.series(48, 1.0, 1.0);
rows = Array.fill(48, { |index| [0.05 * (20 ** (index/47)), levels[index], 0, 0, 1.0, 1] });
targets = levels * 0.001;
st = (signal:\temperature, ready:true, muted:false, rows:rows, targets:targets);
run = (streams:Dictionary["temperature" -> st], toneSelectionState:Dictionary.new,
    rhythmSelectionState:Dictionary.new, rhythmSources:Dictionary.new, rhythmGates:Dictionary.new,
    rhythmOut:\mock, rhythmConnected:true);

~spectrumConfig[\toneSelection] = \all; ~spectrumConfig[\toneSelectionCount] = 48;
desired = ~spectrumMidiDesired.value(run, 0);
check.value(desired.size == 48, "tone all preserves full-spectrum MIDI behavior");
~spectrumConfig[\toneSelection] = \perBand; ~spectrumConfig[\toneSelectionCount] = 3;
desired = ~spectrumMidiDesired.value(run, 1);
check.value(desired.size == 3, "tone perBand selects one winner from each automatic band");
~spectrumConfig[\toneSelection] = \topN; ~spectrumConfig[\toneSelectionCount] = 6;
desired = ~spectrumMidiDesired.value(run, 2);
check.value(desired.size == 6, "tone topN selects six strongest scales");
~spectrumConfig[\toneSelection] = \fixedBand; ~spectrumConfig[\toneSelectionCount] = 3;
desired = ~spectrumMidiDesired.value(run, 3);
check.value(desired.size == 3 and: { (desired.values.collect { |item| item[\amplitude] }.minItem - 0.0085).abs < 0.000001 },
    "tone fixedBand uses representative frequencies and mean band amplitude");

~spectrumConfig[\toneSelection] = \topN; ~spectrumConfig[\toneSelectionCount] = 6;
~spectrumConfig[\rhythmSelection] = \fixedBand; ~spectrumConfig[\rhythmSelectionCount] = 3;
check.value(~spectrumMidiDesired.value(run, 4).size == 6
    and: { ~spectrumRhythmDesired.value(run, 4).size == 3 }, "tone and rhythm spectrum selections are independent");
st[\muted] = true;
check.value(~spectrumMidiDesired.value(run, 5).isEmpty, "tone mute releases selected spectrum notes");
"ALL SPECTRUM TONE SELECTION TESTS PASSED".postln; 0.exit;
)
