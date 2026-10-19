// Deterministic winner and top-N hysteresis with independent tracked states.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, candidates, state, selected, toneState, rhythmState;
(root +/+ "midi-rhythm.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
candidates = [(key:"a", score:1.0), (key:"b", score:0.9)]; state = Dictionary.new;
selected = ~weatherSelectHysteretic.value(candidates, state, 1, \score, 0, 0.1, 5);
check.value(selected[0][\key] == "a", "initial strongest candidate is selected");
candidates = [(key:"a", score:1.0), (key:"b", score:1.5)];
selected = ~weatherSelectHysteretic.value(candidates, state, 1, \score, 1, 0.1, 5);
check.value(selected[0][\key] == "a", "residence time retains incumbent");
selected = ~weatherSelectHysteretic.value(candidates, state, 1, \score, 6, 0.1, 5);
check.value(selected[0][\key] == "b", "qualified challenger replaces incumbent after residence");
selected = ~weatherSelectHysteretic.value([(key:"a", score:0.2)], state, 1, \score, 6.1, 10, 99);
check.value(selected[0][\key] == "a", "invalid incumbent is released immediately");

state = Dictionary.new;
candidates = [(key:"a", score:1.0), (key:"b", score:0.9), (key:"c", score:0.8)];
~weatherSelectHysteretic.value(candidates, state, 2, \score, 0, 0.1, 0);
candidates = [(key:"a", score:1.0), (key:"b", score:0.9), (key:"c", score:0.95)];
selected = ~weatherSelectHysteretic.value(candidates, state, 2, \score, 1, 0.1, 0);
check.value(selected.collect { |item| item[\key] }.asSet == Set["a","b"], "top-N margin stabilizes selected set");
candidates[2][\score] = 1.1;
selected = ~weatherSelectHysteretic.value(candidates, state, 2, \score, 2, 0.1, 0);
check.value(selected.collect { |item| item[\key] }.asSet == Set["a","c"], "top-N replaces only weakest qualified incumbent");

toneState = Dictionary.new; rhythmState = Dictionary.new;
candidates = [(key:"a", confidence:0.8), (key:"b", confidence:0.7)];
~weatherSelectHysteretic.value(candidates, toneState, 1, \confidence, 0, 0, 30);
~weatherSelectHysteretic.value(candidates, rhythmState, 1, \confidence, 0, 0, 0);
candidates[1][\confidence] = 0.95;
check.value(~weatherSelectHysteretic.value(candidates, toneState, 1, \confidence, 1, 0, 30)[0][\key] == "a"
    and: { ~weatherSelectHysteretic.value(candidates, rhythmState, 1, \confidence, 1, 0, 0)[0][\key] == "b" },
    "tracked tone and rhythm selections retain independent residence state");
"ALL SELECTION HYSTERESIS TESTS PASSED".postln; 0.exit;
)
