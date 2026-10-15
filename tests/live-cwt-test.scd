// Run with sclang -D tests/live-cwt-test.scd. Boots local audio with master=0.
// Uses local native OSC fixtures only; never registers with the real Pi.
(
var root = thisProcess.nowExecutingPath.dirname.dirname;
var check, destination, sendVoice, sendState, controls = List.new, controlReceiver;
~cwtAutoStart = false;
(root +/+ "live-cwt.scd").load;
check = { |condition, label|
    if(condition.not) { ("FAIL: " ++ label).postln; ~cwtStop.value; s.quit; 1.exit } { ("PASS: " ++ label).postln };
};
check.value((~cwtMapPitch.value(0.1371254, ~cwtConfig)[\hz] - 263.50194232597).abs < 1e-8, "continuous JS parity");
~cwtConfig[\pitchMode] = \midi;
check.value((~cwtMapPitch.value(0.1371254, ~cwtConfig)[\hz] - 261.6255653006).abs < 1e-8, "quantized JS parity");
~cwtConfig[\pitchMode] = \midiOutput;
check.value(~cwtMapPitch.value(0.1371254, ~cwtConfig, 60)[\note] == 60, "MIDI hysteresis holds");
check.value(~cwtMapPitch.value(0.5, ~cwtConfig, 60)[\note] == 76, "MIDI hysteresis crosses");
~cwtConfig[\pitchMode] = \continuous;
~cwtSetBaseNote.value(60, \temperature); ~cwtSetPitchSpan.value(24, \temperature);
check.value((~cwtMapPitch.value(0.05, ~cwtConfig, nil, \temperature)[\hz] - 60.midicps).abs < 1e-8, "sensor base-note override");
check.value((~cwtMapPitch.value(1, ~cwtConfig, nil, \temperature)[\hz] - 84.midicps).abs < 1e-8, "sensor span override");
~cwtSetBaseNote.value(nil, \temperature); ~cwtSetPitchSpan.value(nil, \temperature);
check.value((~cwtMapPitch.value(0.05, ~cwtConfig, nil, \temperature)[\hz] - 48.midicps).abs < 1e-8, "sensor pitch overrides clear");
~cwtConfig[\routerIP] = "127.0.0.1";
~cwtConfig[\routerPort] = 50055;
~cwtConfig[\localPort] = 19001;
~cwtConfig[\masterVolume] = 0;
~cwtConfig[\diagnosticsInterval] = 60;
check.value(thisProcess.openUDPPort(50055), "fixture control port opens");
controlReceiver = { |msg, time, addr, port| if(port == 50055) { controls.add(msg[0].asString) } };
thisProcess.addOSCRecvFunc(controlReceiver);
destination = NetAddr("127.0.0.1", 19001);
sendVoice = { |id, confidence=0.8, active=1, frequency=0.1371254, stamp=1000, signal="temperature"|
    destination.sendMsg("/osc/fixture/" ++ signal ++ "/cwt/voice/" ++ id,
        frequency, 0.000001505, 3.02084, confidence, active, stamp, stamp);
};
sendState = { |ids, ready=1, stamp=1000, signal="temperature"|
    destination.sendMsg(*(["/osc/fixture/" ++ signal ++ "/cwt/voices", stamp, ready, "", 1.0, ids.size] ++ ids));
};
~cwtStart.value;
Routine({
    var deadline = Main.elapsedTime + 20, firstNode, nextRun, selected;
    while { ~cwtRun[\receiver].isNil and: { Main.elapsedTime < deadline } } { 0.1.wait };
    check.value(~cwtRun[\receiver].notNil, "instrument started");
    0.2.wait;
    check.value(controls.includesEqual("/router/subscribe"), "native subscription received");
    5.do { |i| sendVoice.value(i + 1) }; sendState.value([1,2,3,4,5]);
    0.3.wait;
    check.value(~cwtRun[\synths].size == 4, "five candidates produce four synths");
    check.value(~cwtRun[\output].notNil and: { ~cwtRun[\activeOutputBus] == 0 }, "tracked output limiter on stereo bus 0");
    firstNode = ~cwtRun[\synths]["fixture/temperature/1"][\synth].nodeID;
    sendVoice.value(1, 0.9); ~cwtSetMinConfidence.value(0.85); 0.3.wait;
    check.value(~cwtRun[\eligibleCount] == 1 and: { ~cwtRun[\selectedCount] == 1 }
        and: { ~cwtRun[\releasingCount] == 3 }, "confidence threshold filters then releases");
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\synth].nodeID == firstNode, "qualifying incumbent retained");
    ~cwtSetMinConfidence.value(1.1);
    check.value(~cwtConfig[\minConfidence] == 0.85, "invalid confidence threshold rejected");
    ~cwtSetMinConfidence.value(0); 2.7.wait;
    check.value(~cwtRun[\synths].size == 4 and: { ~cwtRun[\releasingCount] == 0 }, "lower threshold refills to polyphony ceiling");
    ~cwtSetGain.value(\temperature, 0.5); 0.3.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\amp] > 0, "live sensor gain updates sounding voice");
    ~cwtMute.value(\temperature, true); 0.3.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\amp] == 0
        and: { ~cwtRun[\selectedCount] == 4 }, "mute silences without changing selection");
    ~cwtMute.value(\temperature, false); ~cwtSetGain.value(\temperature, 1); 0.3.wait;
    ~cwtSetWaveform.value(\triangle); 0.3.wait; s.sync;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\waveform] == \triangle
        and: { ~cwtRun[\synths]["fixture/temperature/1"][\synth].nodeID == firstNode }, "waveform switch preserves voice node");
    ~cwtSetWaveform.value(\sine);
    ~cwtSetOutputBus.value(2); 0.2.wait;
    check.value(~cwtRun[\activeOutputBus] == 0, "unavailable multichannel bus uses warned stereo fallback");
    sendVoice.value(1, 0.8, 1, 0.5, 2000); sendState.value([1,2,3,4,5], 1, 2000);
    0.3.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\synth].nodeID == firstNode, "pitch update preserves node identity");
    check.value((~cwtRun[\synths]["fixture/temperature/1"][\hz] - 646.8220605414).abs < 0.001, "updated audio pitch");
    selected = ~cwtSelect.value([(key:"z", confidence:0.8), (key:"a", confidence:0.8)],
        Dictionary["z" -> (releasing:false)], 1);
    check.value(selected[0][\key] == "z", "incumbents win confidence ties");
    sendVoice.value(5, 0.95, 1, 0.2, 2000);
    0.3.wait;
    check.value(~cwtRun[\synths].size == 4, "steal reserves slot during release");
    2.7.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/5"].notNil, "higher confidence admitted after release");
    sendVoice.value(1, 0.8, 0, 0.5, 2000);
    0.3.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\releasing], "inactive packet releases");
    sendState.value([], 0, 2000);
    0.3.wait;
    check.value(~cwtRun[\synths].values.every { |entry| entry[\releasing] }, "unready list releases all");
    2.7.wait;
    check.value(~cwtRun[\synths].isEmpty, "release tails removed");
    sendVoice.value(1, 0.8, 1, 0.1371254, 10); sendState.value([1], 1, 10);
    sendVoice.value(1, 0.8, 1, 0.1371254, 10, "rms"); sendState.value([1], 1, 10, "rms");
    0.3.wait;
    check.value(~cwtRun[\synths].size == 2, "same ID in distinct signals stays distinct");
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\synth].nodeID != firstNode, "reused ID creates new epoch synth");
    sendState.value([], 1, 10);
    0.3.wait;
    check.value(~cwtRun[\synths]["fixture/temperature/1"][\releasing], "authoritative list repairs missing inactive packet");
    ~cwtConfig[\trafficTimeout] = 0.2;
    0.4.wait;
    check.value(~cwtRun[\synths]["fixture/rms/1"][\releasing], "silence watchdog releases voices");
    4.wait;
    check.value(controls.includesEqual("/router/heartbeat"), "native heartbeat received");
    ~cwtStop.value; ~cwtStop.value;
    0.2.wait;
    check.value(controls.includesEqual("/router/unsubscribe"), "native unsubscribe received");
    check.value(~cwtRun.isNil, "stop is idempotent");
    ~cwtStart.value;
    0.5.wait;
    nextRun = ~cwtRun;
    check.value(nextRun[\receiver].notNil, "restart works on same UDP port");
    CmdPeriod.run;
    check.value(~cwtRun.isNil, "Cmd-period cleanup");
    thisProcess.removeOSCRecvFunc(controlReceiver);
    s.quit;
    "ALL CWT TESTS PASSED".postln;
    0.exit;
}).play(SystemClock);
SystemClock.sched(45, { "TEST TIMEOUT".postln; ~cwtStop.value; s.quit; 1.exit });
)
