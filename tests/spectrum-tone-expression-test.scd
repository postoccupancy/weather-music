// Spectrum aftertouch, CC74, pitch-bend, and neutral-reset behavior; no MIDI device.
(
var root = thisProcess.nowExecutingPath.dirname.dirname, check, messages=List.new, rows, st, run, noteOns;
~spectrumAutoStart = false; (root +/+ "live-spectrum.scd").load;
check = { |condition, label| if(condition) { ("PASS: " ++ label).postln } { Error("FAIL: " ++ label).throw } };
~spectrumMidiEmit = { |out, type, channel, note=0, value=0| messages.add([type,channel,note,value]) };
rows = Array.fill(48, { |index| [0.05*(20**(index/47)), 1, 0, 0, 1, 1] });
st = (signal:\temperature, ready:true, muted:false, rows:rows, targets:Array.fill(48, 0.0002));
run = (streams:Dictionary["temperature"->st], toneSelectionState:Dictionary.new,
    midiOut:\mock, midiConnected:true, midiActive:Dictionary.new, midiChannelsUsed:Set.new,
    midiLastUpdate:0.0, toneChannelExpression:Dictionary.new);
~spectrumConfig[\toneSelection] = \all; ~spectrumConfig[\midiExpressionFloor] = 0.0001;
~spectrumConfig[\midiExpressionCeiling] = 0.01; ~spectrumConfig[\midiExpressionSmoothing] = 0;
~spectrumConfig[\toneExpression] = \aftertouch; ~spectrumMidiUpdate.value(run);
check.value(messages.any { |item| item[0] == \polyTouch }, "aftertouch remains the default per-note expression");
noteOns = messages.count { |item| item[0] == \noteOn }; messages.clear;

~spectrumConfig[\toneExpression] = \off; ~spectrumToneResetExpression.value(run); messages.clear;
~spectrumMidiUpdate.value(run);
check.value(messages.every { |item| item[0] != \polyTouch } and: {
    messages.count { |item| item[0] == \noteOn } == 0 }, "off sends no expression and does not retrigger held notes");

~spectrumConfig[\toneExpression] = \filter; ~spectrumConfig[\toneFilterSmoothing] = 0;
messages.clear; ~spectrumMidiUpdate.value(run);
check.value(messages.count { |item| item[0] == \control and: { item[2] == 74 } } == 1,
    "filter sends one aggregate CC74 value per active channel");

~spectrumConfig[\toneExpression] = \pitchBend; ~spectrumConfig[\tonePitchBendSmoothing] = 0;
~spectrumToneResetExpression.value(run); messages.clear; ~spectrumMidiUpdate.value(run);
check.value(messages.count { |item| item[0] == \bend } == 1,
    "pitchBend sends one aggregate bend per active channel");
st[\muted] = true; messages.clear; ~spectrumMidiUpdate.value(run);
check.value(messages.any { |item| item[0] == \bend and: { item[3] == 8192 } }
    and: { messages.count { |item| item[0] == \noteOff } == noteOns }, "mute releases notes and restores neutral bend");
messages.clear; ~spectrumMidiPanicRun.value(run);
check.value(messages.select { |item| item[0] == \bend }.every { |item| item[3] == 8192 },
    "panic and disconnect cleanup leave spectrum channels at neutral bend");
"ALL SPECTRUM TONE EXPRESSION TESTS PASSED".postln; 0.exit;
)
