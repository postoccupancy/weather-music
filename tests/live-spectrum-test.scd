(
var check, packet, dest, st, controls = List.new, midi = List.new, receiver, midiCount, rhythm = List.new;
~spectrumAutoStart = false;
(thisProcess.nowExecutingPath.dirname.dirname +/+ "live-spectrum.scd").load;
~spectrumMidiOpen = { |device, port| [device, port] };
~spectrumMidiEmit = { |out, type, channel, note=0, value=0| midi.add([type, channel, note, value]) };
~spectrumRhythmOpen = { |device, port| [device, port] };
~spectrumRhythmEmit = { |out, type, channel, note=0, value=0| rhythm.add([type, channel, note, value]) };
midiCount = { |type| midi.count { |message| message[0] == type } };
check = { |ok, label| if(ok.not) { ("FAIL: " ++ label).postln; ~spectrumStop.value(true); s.quit; 1.exit } { ("PASS: " ++ label).postln } };
check.value((~spectrumFactor.value(\humidity).reciprocal - 3.098).abs < 0.01, "RH derivative");
check.value((~spectrumFactor.value(\pressure) - 0.289316).abs < 0.00001, "pressure factor");
check.value(~spectrumSignificance.value([1, 0.01, 0, 0, 0.000025, 1]) == 2, "significance 2");
check.value(~spectrumSignificance.value([1, 0, 0, 0, 0, 0]).isNil, "missing background");
check.value((~spectrumPitch.value(0.05) - 48.midicps).abs < 1e-8, "pitch low");
check.value((~spectrumPitch.value(1) - 96.midicps).abs < 1e-8, "pitch high at default 48-semitone span");
check.value(~spectrumConfig[\midiEnabled], "MIDI enabled by default");
check.value(~spectrumConfig[\mode] == \significance and: { ~spectrumConfig[\significanceGain] == 0.001 },
    "significance mode and conservative gain are defaults");
check.value(~spectrumConfig[\midiExpressionCeiling] == 0.005, "default MIDI expression range matches significance targets");
check.value(~spectrumFinite.value(1.0), "frame finite");
check.value((1.0 > 9.007199254740991e15).not, "frame below safe integer maximum");
check.value(((1.0 - 1.0.floor).abs > 0).not, "frame integral");
~spectrumConfig[\routerIP] = "127.0.0.1"; ~spectrumConfig[\routerPort] = 50056;
~spectrumConfig[\localPort] = 19000; ~spectrumConfig[\masterGain] = 0; ~spectrumConfig[\diagnosticsSeconds] = 60;
~spectrumConfig[\shutdownSeconds] = 0.1;
~spectrumConfig[\rhythmEnabled] = true; ~spectrumConfig[\rhythmPulseMinHz] = 10; ~spectrumConfig[\rhythmPulseMaxHz] = 10;
s.options.outDevice = "BlackHole 16ch"; s.options.numInputBusChannels = 0; s.options.numOutputBusChannels = 16;
thisProcess.openUDPPort(50056);
receiver = { |m, time, sender, port| if(port == 50056) { controls.add(m[0].asString) } };
thisProcess.addOSCRecvFunc(receiver); dest = NetAddr("127.0.0.1", 19000);
packet = { |frame=1, offset=0, count=35, epoch="epoch-a", mag=0.01, total=48, signal="temperature"|
    var m = ["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum", 3, epoch, frame.asFloat, 123456789.123, 1, "", total, offset, count];
    count.do { |i| m = m ++ [20.pow((offset+i) / (total-1)).reciprocal, mag, 0.0, 0, 0.000025, 1] }; m
};
~spectrumStart.value;
Routine({
    var deadline = Main.elapsedTime + 20, node, m, before, run;
    while { ~spectrumRun[\receiver].isNil and: { Main.elapsedTime < deadline } } { 0.1.wait };
    check.value(~spectrumRun[\receiver].notNil, "started");
    run = ~spectrumRun; st = run[\streams]["/osc/indoor-sky/temperature/cwt/spectrum"]; node = st[\synth].nodeID;
    0.2.wait; check.value(controls.includesEqual("/router/subscribe"), "UDP subscription");
    check.value(run[\midiConnected] and: { run[\midiOut] == ["IAC Driver", "Bus 3 - Ableton Live"] }, "default MIDI destination initializes");
    ~spectrumRhythmOpen = { nil }; ~spectrumRhythmConnect.value(run);
    check.value(run[\rhythmConnected].not and: { run[\midiConnected] },
        "missing spectrum rhythm destination does not disrupt sustained tones");
    ~spectrumRhythmOpen = { |device, port| [device, port] }; ~spectrumRhythmConnect.value(run);
    check.value(run[\activeOutputBus] == 2 and: { run[\routingState] == \ready }, "16-output startup assigns spectrum bus 2");
    check.value(run[\bus].index >= 16 and: { run[\output].notNil }
        and: { run[\streams].values.every { |bank| bank[\synth].notNil } }, "banks feed a private bus and output synth");
    run[\activeOutputBus] = nil; run[\routingState] = \invalid;
    ~spectrumSetOutputBus.value(2); 0.1.wait;
    check.value(run[\activeOutputBus] == 2 and: { run[\routingState] == \ready },
        "live setter repairs output-synth-present/active-bus-nil regression");
    ~spectrumSetOutputBus.value(4); 0.1.wait;
    check.value(run[\activeOutputBus] == 4, "live output move assigns valid stereo bus");
    ~spectrumSetOutputBus.value(20); 0.1.wait;
    check.value(run[\activeOutputBus] == 0, "invalid live output uses explicit fallback");
    ~spectrumSetOutputBus.value(2); 0.1.wait;
    check.value(run[\activeOutputBus] == 2, "live output returns to bus 2");
    dest.sendMsg(*packet.value(1, 35, 13)); 0.1.wait; check.value(st[\ready].not, "incomplete silent");
    dest.sendMsg(*packet.value(1)); 0.4.wait;
    check.value(st[\ready] and: { st[\rows].size == 48 }, "reverse chunk reassembly");
    check.value((st[\targets][0] - 0.002).abs < 1e-7, "default significance target uses magnitude and background power");
    check.value(run[\rhythmSources].size == 3
        and: { run[\rhythmSources].values.collect { |source| source[\note] }.asSet == Set[36,38,42] }
        and: { rhythm.any { |message| message[0] == \noteOn } }, "default per-band spectrum rhythm emits three mapped pulses");
    check.value(run[\midiActive].size == 48 and: { midiCount.value(\noteOn) == 48 }
        and: { midiCount.value(\polyTouch) == 48 }, "48-semitone mapping starts 48 held notes with aftertouch");
    check.value(midi.every { |message| message[1] <= 2 }, "spectrum MIDI owns only channels 1-3");
    midi.clear; ~spectrumSetPitchSpan.value(36); 0.4.wait;
    check.value(run[\midiActive].size == 37 and: { run[\midiActive].values.collect { |entry| entry[\smoothed] }.maxItem > 0.003 },
        "36-semitone mapping aggregates scale collisions");
    check.value(midiCount.value(\noteOff) > 0, "pitch remap releases old assignments");
    midi.clear; ~spectrumSetPitchSpan.value(48); 0.4.wait;
    check.value(run[\midiActive].size == 48, "48 scales map across 48 semitones");
    ~spectrumSetPitchSpan.value(60); 0.4.wait;
    check.value(run[\midiActive].size == 48, "48 scales distribute across 60 semitones without consecutive-note assumption");
    ~spectrumSetPitchSpan.value(48); ~spectrumSetMidiExpression.value(0.00001, 0.02, 0, 0, 64); 0.4.wait;
    midi.clear;
    dest.sendMsg(*packet.value(1, 0, 48, "humidity-a", 0.01, 48, "humidity"));
    dest.sendMsg(*packet.value(1, 0, 48, "pressure-a", 0.01, 48, "pressure")); 0.5.wait;
    check.value(run[\midiActive].values.any { |entry| entry[\channel] == 0 }
        and: { run[\midiActive].values.any { |entry| entry[\channel] == 1 } }
        and: { run[\midiActive].values.any { |entry| entry[\channel] == 2 } }, "sensor streams use configured MIDI channels");
    before = ~spectrumConfig[\temperatureMidiChannel]; ~spectrumSetMidiChannel.value(\temperature, 4);
    check.value(~spectrumConfig[\temperatureMidiChannel] == before, "spectrum rejects tracked-voice channels");
    midi.clear; ~spectrumSetMidiChannel.value(\temperature, 2); 0.4.wait;
    check.value(midi.select { |message| message[0] == \noteOff }.any { |message| message[1] == 0 }
        and: { run[\midiActive].values.any { |entry| entry[\channel] == 1 } }, "live channel remap stays within spectrum ownership");
    ~spectrumSetMidiChannel.value(\temperature, 1); 0.4.wait;
    midi.clear; ~spectrumSetMidiEnabled.value(false); 0.3.wait;
    check.value(run[\midiActive].isEmpty and: { midiCount.value(\allNotesOff) > 0 }, "explicit MIDI disable releases all notes");
    check.value(run[\rhythmSources].notEmpty, "spectrum rhythm remains active when sustained tone is disabled");
    ~spectrumSetMidiEnabled.value(true); 0.4.wait;
    check.value(run[\midiConnected] and: { run[\midiActive].notEmpty }, "MIDI re-enable reconnects and resumes held spectrum");
    midi.clear; ~spectrumSetGain.value(\temperature, 2); 0.5.wait;
    check.value(midiCount.value(\polyTouch) > 0, "aftertouch follows effective amplitude changes");
    midi.clear; ~spectrumMute.value(\temperature, true); 0.4.wait;
    check.value(midi.select { |message| message[0] == \noteOff }.every { |message| message[1] == 0 }
        and: { run[\midiActive].values.detect { |entry| entry[\channel] == 0 }.isNil }, "stream mute releases only its channel notes");
    ~spectrumMute.value(\temperature, false); ~spectrumSetGain.value(\temperature, 1); 0.4.wait;
    ~spectrumConfig[\masterGain] = 0.1; 1.2.wait;
    check.value(run[\outputSeen].notNil and: { run[\outputPeak] > 0 }, "known spectrum produces audio at output stage");
    ~spectrumConfig[\masterGain] = 0; 0.3.wait;
    ~spectrumTestTone.value; 0.7.wait;
    check.value(run[\outputPeak] > 0, "test tone traverses spectrum internal bus and output stage");
    check.value(st[\waveform] == \sine and: { st[\waveLevel] == 1.0 }, "sine default");
    ~spectrumSetBaseNote.value(60); 0.4.wait; s.sync;
    check.value((st[\frequencies][47] - 60.midicps).abs < 0.001, "live base-note low endpoint");
    check.value((st[\frequencies][0] - 108.midicps).abs < 0.001, "base-note retains span");
    ~spectrumSetPitchSpan.value(24); 0.4.wait; s.sync;
    check.value((st[\frequencies][0] - 84.midicps).abs < 0.001, "live pitch-span high endpoint");
    before = ~spectrumConfig[\baseNote]; ~spectrumSetBaseNote.value(23);
    check.value(~spectrumConfig[\baseNote] == before, "out-of-range base note rejected");
    before = ~spectrumConfig[\pitchSpan]; ~spectrumSetPitchSpan.value(73);
    check.value(~spectrumConfig[\pitchSpan] == before, "out-of-range pitch span rejected");
    ~spectrumSetBaseNote.value(48); ~spectrumSetPitchSpan.value(48); 0.4.wait;
    ~spectrumSetBaseNote.value(60, \temperature); ~spectrumSetPitchSpan.value(24, \temperature); 0.4.wait;
    check.value((st[\frequencies][47] - 60.midicps).abs < 0.001
        and: { (st[\frequencies][0] - 84.midicps).abs < 0.001 }, "spectrum sensor pitch overrides");
    ~spectrumSetBaseNote.value(nil, \temperature); ~spectrumSetPitchSpan.value(nil, \temperature); 0.4.wait;
    check.value((st[\frequencies][47] - 48.midicps).abs < 0.001, "spectrum overrides clear to global");
    ~spectrumSetWaveform.value(\temperature, \triangle); 0.3.wait; s.sync;
    check.value(st[\waveform] == \triangle and: { st[\waveLevel] == 0.8 }, "temperature triangle");
    check.value(run[\streams]["/osc/indoor-sky/humidity/cwt/spectrum"][\waveform] == \sine, "waveform is bank-local");
    [\saw, \sine, \triangle, \saw].do { |wave| ~spectrumSetWaveform.value(\temperature, wave); 0.3.wait };
    s.sync;
    check.value(st[\synth].nodeID == node and: { st[\waveform] == \saw } and: { st[\waveLevel] == 0.55 }, "repeated waveform switches preserve synth");
    ~spectrumSetWaveform.value(\humidity, \saw); ~spectrumSetWaveform.value(\pressure, \saw); 0.3.wait; s.sync;
    check.value(run[\streams].values.every { |bank| bank[\waveform] == \saw and: { bank[\waveLevel] == 0.55 } }, "all-saw compensation applied");
    before = ~spectrumConfig[\temperatureWaveform]; ~spectrumSetWaveform.value(\temperature, \square);
    check.value(~spectrumConfig[\temperatureWaveform] == before, "unknown waveform rejected");
    ~spectrumSetGain.value(\temperature, 100); 0.4.wait;
    check.value(st[\targets].maxItem <= ~spectrumConfig[\amplitudeCeiling], "worst-case target bounded");
    ~spectrumSetGain.value(\temperature, 1);
    [\temperature, \humidity, \pressure].do { |signal| ~spectrumSetWaveform.value(signal, \sine) }; 0.4.wait;
    dest.sendMsg(*packet.value(2)); dest.sendMsg(*packet.value(2)); dest.sendMsg(*packet.value(2, 35, 13)); 0.3.wait;
    check.value(st[\frame] == 2, "identical duplicates");
    check.value(st[\synth].nodeID == node, "OSC continues after waveform changes");
    dest.sendMsg(*packet.value(3)); dest.sendMsg(*packet.value(3, 0, 35, "epoch-a", 0.02)); dest.sendMsg(*packet.value(3, 35, 13)); 0.3.wait;
    check.value(st[\frame] == 2, "conflicting duplicates");
    before = run[\rejected]; m = packet.value(4); m[1] = 2; dest.sendMsg(*m);
    dest.sendMsg(*packet.value(4).drop(-1)); 0.2.wait;
    check.value(run[\rejected] == (before+2), "version and lengths");
    dest.sendMsg(*packet.value(4)); m = packet.value(4, 35, 13); m[4] = 999.0; dest.sendMsg(*m); 0.2.wait;
    check.value(st[\frame] == 2, "timestamp conflict");
    ~spectrumConfig[\pendingTimeoutSeconds] = 0.1; 0.5.wait;
    check.value(st[\pending].isEmpty, "pending expiry"); ~spectrumConfig[\pendingTimeoutSeconds] = 3;
    dest.sendMsg(*packet.value(1, 0, 35, "epoch-b")); dest.sendMsg(*packet.value(1, 35, 13, "epoch-b")); 0.3.wait;
    check.value(st[\epoch].asString == "epoch-b" and: { st[\frame] == 1 }, "epoch ordering reset");
    dest.sendMsg(*packet.value(99)); 0.1.wait; check.value(st[\epoch].asString == "epoch-b", "retired epoch rejected");
    midi.clear; ~spectrumSetMode.value(\physical); 0.4.wait;
    check.value((st[\targets][0] - 0.01).abs < 1e-7, "physical mode remains available without normalization");
    ~spectrumConfig[\significanceGain] = 0.002; ~spectrumSetMode.value(\significance); 0.4.wait;
    check.value((st[\targets][0] - 0.004).abs < 1e-7, "switch back to significance mode");
    check.value(midiCount.value(\polyTouch) > 0, "mode change updates MIDI expression without retriggering notes");
    ~spectrumSetGain.value(\temperature, 2); 0.4.wait;
    check.value((st[\targets][0] - 0.008).abs < 1e-7, "live gain");
    ~spectrumMute.value(\temperature, true); 0.4.wait; check.value(st[\targets].sum == 0, "mute");
    ~spectrumMute.value(\temperature, false); 0.4.wait; check.value(st[\targets].sum > 0, "unmute");
    m = packet.value(2, 0, 48, "epoch-b"); m[14] = 0.0; m[15] = 0; m[17] = 0.0; dest.sendMsg(*m); 0.4.wait;
    check.value(st[\targets][0] == 0 and: { st[\targets][1] == 0 } and: { st[\targets][2] > 0 }, "unavailable and zero scales");
    check.value(st[\synth].nodeID == node, "persistent nodes");
    ~spectrumStatus.value; ~spectrumInspect.value(\temperature, 2);
    ~spectrumAudioStatus.value; ~spectrumMidiStatus.value;
    midi.clear; dest.sendMsg("/osc/indoor-sky/temperature/cwt/spectrum", 3, "epoch-b", 3.0, 123.0, 0, "coverage", 0, 0, 0); 0.4.wait;
    check.value(st[\ready].not and: { st[\targets].sum == 0 }, "invalidation");
    check.value(midiCount.value(\noteOff) > 0, "invalid frame releases sustained MIDI notes");
    check.value(run[\rhythmSources].keys.every { |key| key.beginsWith("temperature/").not },
        "invalid frame removes its spectrum rhythmic sources");
    dest.sendMsg(*packet.value(2, 0, 48, "epoch-b")); 0.1.wait; check.value(st[\ready].not, "older ignored");
    dest.sendMsg(*packet.value(4, 0, 48, "epoch-b")); 0.3.wait;
    midi.clear; ~spectrumConfig[\staleTimeoutSeconds] = 0.1; 0.4.wait;
    check.value(st[\reason] == "timeout" and: { st[\targets].sum == 0 }, "timeout");
    check.value(midiCount.value(\noteOff) > 0, "stale streams release sustained MIDI notes");
    check.value(run[\rhythmSources].keys.every { |key| key.beginsWith("temperature/").not },
        "stale stream removes spectrum rhythmic sources");
    dest.sendMsg(*packet.value(5, 0, 47, "epoch-b", 0.01, 47)); 0.3.wait;
    check.value(st[\reason] == "unsupported-scale-count", "different scale count");
    while { controls.includesEqual("/router/heartbeat").not and: { Main.elapsedTime < (deadline+10) } } { 0.1.wait };
    check.value(controls.includesEqual("/router/heartbeat"), "heartbeat");
    "Spectrum test server CPU avg=% peak=% UGens=%".format(s.avgCPU.round(0.01), s.peakCPU.round(0.01), s.numUGens).postln;
    midi.clear; ~spectrumStop.value; ~spectrumStop.value; 0.4.wait;
    check.value(~spectrumRun.isNil and: { controls.includesEqual("/router/unsubscribe") }, "stop cleanup");
    check.value(midiCount.value(\allNotesOff) > 0 and: { midi.every { |message| message[1] <= 2 } },
        "stop sends MIDI panic only on spectrum channels");
    check.value(rhythm.any { |message| message[0] == \allNotesOff }
        and: { rhythm.every { |message| message[1] <= 2 } }, "stop cleans rhythm bus only on spectrum channels");
    ~spectrumMidiOpen = { |device, port| nil };
    ~spectrumStart.value; 0.5.wait; check.value(~spectrumRun[\receiver].notNil, "restart");
    check.value(~spectrumRun[\midiConnected].not and: { ~spectrumRun[\midiError].notNil }, "missing default destination reports connection failure");
    CmdPeriod.run; check.value(~spectrumRun.isNil, "Cmd-period cleanup");
    ~spectrumStart.value; ~spectrumStop.value(true); 0.4.wait; check.value(~spectrumRun.isNil, "startup cancellation");
    thisProcess.removeOSCRecvFunc(receiver); s.quit; "ALL SPECTRUM TESTS PASSED".postln; 0.exit;
}).play(SystemClock);
SystemClock.sched(45, { "TEST TIMEOUT".postln; ~spectrumStop.value(true); s.quit; 1.exit });
)
