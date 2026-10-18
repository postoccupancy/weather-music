// Shared native lease and concurrent lifecycle fixture. No Pi traffic; audio muted.
(
var root = thisProcess.nowExecutingPath.dirname.dirname;
var check, controls = List.new, receiver, deadline, destination;
var cwtMidi = List.new, spectrumMidi = List.new, packet, sendCwt;
~cwtAutoStart = false; ~spectrumAutoStart = false;
(root +/+ "live-spectrum.scd").load;
(root +/+ "live-cwt.scd").load;
~spectrumMidiOpen = { |device, port| [device, port] };
~spectrumMidiEmit = { |out, type, channel, note=0, value=0| spectrumMidi.add([type, channel, note, value]) };
~cwtMidiOpen = { |device, port| [device, port] };
~cwtMidiEmit = { |out, type, channel, note=0, value=0| cwtMidi.add([type, channel, note, value]) };
check = { |condition, label|
    if(condition.not) {
        ("FAIL: " ++ label).postln; ~cwtStop.value; ~spectrumStop.value(true); s.quit; 1.exit
    } { ("PASS: " ++ label).postln };
};
~cwtConfig[\routerIP] = "127.0.0.1"; ~cwtConfig[\routerPort] = 50057;
~cwtConfig[\localPort] = 19002; ~cwtConfig[\masterVolume] = 0; ~cwtConfig[\diagnosticsInterval] = 60;
~spectrumConfig[\routerIP] = "127.0.0.1"; ~spectrumConfig[\routerPort] = 50057;
~spectrumConfig[\localPort] = 19002; ~spectrumConfig[\masterGain] = 0; ~spectrumConfig[\diagnosticsSeconds] = 60;
thisProcess.openUDPPort(50057);
receiver = { |msg, time, addr, port| if(port == 50057) { controls.add(msg[0].asString) } };
thisProcess.addOSCRecvFunc(receiver);
destination = NetAddr("127.0.0.1", 19002);
packet = { |offset=0, count=35|
    var message = ["/osc/indoor-sky/temperature/cwt/spectrum", 3, "concurrent", 1.0, 123456.0, 1, "", 48, offset, count];
    count.do { |i| message = message ++ [20.pow((offset+i) / 47).reciprocal, 0.01, 0.0, 0, 0.000025, 1] }; message
};
sendCwt = {
    4.do { |i| destination.sendMsg("/osc/fixture/temperature/cwt/voice/" ++ (i+1),
        0.12 + (i * 0.02), 0.01, 0.0, 0.8, 1, 1000, 1000) };
    destination.sendMsg("/osc/fixture/temperature/cwt/voices", 1000, 1, "", 1.0, 4, 1, 2, 3, 4);
};
~cwtStart.value; ~spectrumStart.value;
Routine({
    var lease, cwtReceiver, cwtNode;
    deadline = Main.elapsedTime + 20;
    while { (~cwtRun.tryPerform(\at, \receiver).isNil or: { ~spectrumRun.tryPerform(\at, \receiver).isNil })
        and: { Main.elapsedTime < deadline } } { 0.1.wait };
    check.value(~cwtRun[\receiver].notNil and: { ~spectrumRun[\receiver].notNil }, "both instruments started on one receive port");
    check.value(~spectrumRun[\midiConnected], "spectrum MIDI initializes by default alongside CWT");
    lease = ~weatherLeaseState.values.first;
    check.value(lease.notNil and: { lease[\owners].includes(\cwt) }
        and: { lease[\owners].includes(\spectrum) } and: { lease[\heartbeat].notNil }, "shared lease owns both instruments and one heartbeat");
    check.value(~cwtRun[\activeOutputBus] == 0 and: { ~spectrumRun[\activeOutputBus] == 0 }, "stereo device uses explicit spectrum fallback");
    check.value(~weatherResolveOutputBus.value(0, 0, "test") == 0, "output resolver survives spectrum-then-CWT load order");
    check.value(~cwtRun[\output].nodeID != ~spectrumRun[\output].nodeID, "instruments retain distinct output synths");
    sendCwt.value; destination.sendMsg(*packet.value(35, 13)); destination.sendMsg(*packet.value); 0.6.wait;
    check.value(~cwtRun[\midiVoices].size == 4 and: { ~spectrumRun[\midiActive].notEmpty },
        "both sketches sustain MIDI concurrently");
    check.value(cwtMidi.every { |message| message[1] >= 3 }
        and: { spectrumMidi.every { |message| message[1] <= 2 } }, "MIDI channel ownership is disjoint");
    cwtReceiver = ~cwtRun[\receiver]; cwtNode = ~cwtRun[\synths].values.first[\synth].nodeID;
    cwtMidi.clear; spectrumMidi.clear; ~cwtMidiPanic.value; 0.02.wait;
    check.value(cwtMidi.notEmpty and: { cwtMidi.every { |message| message[1] >= 3 } }
        and: { spectrumMidi.isEmpty }, "tracked panic does not affect spectrum channels");
    cwtMidi.clear; ~cwtMidiResync.value; 0.02.wait;
    check.value(cwtMidi.any { |message| message[0] == \noteOn }
        and: { cwtMidi.any { |message| message[0] == \bend } }
        and: { cwtMidi.any { |message| message[0] == \touch } }
        and: { cwtMidi.every { |message| message[1] >= 3 } }
        and: { ~cwtRun[\receiver] === cwtReceiver }
        and: { ~cwtRun[\synths].values.first[\synth].nodeID == cwtNode }, "tracked resync preserves OSC and audio while resending expression");
    cwtMidi.clear; spectrumMidi.clear; ~cwtMidiConnect.value(~cwtRun);
    check.value(cwtMidi.notEmpty and: { cwtMidi.every { |message| message[1] >= 3 } }
        and: { spectrumMidi.isEmpty }, "tracked reconnect cleans only tracked channels");
    0.15.wait;
    cwtMidi.clear; spectrumMidi.clear; ~spectrumMidiPanic.value; 0.02.wait;
    check.value(spectrumMidi.notEmpty and: { spectrumMidi.every { |message| message[1] <= 2 } }
        and: { cwtMidi.isEmpty }, "spectrum panic does not affect tracked channels");
    0.3.wait; cwtMidi.clear; spectrumMidi.clear; ~spectrumMidiConnect.value(~spectrumRun);
    check.value(spectrumMidi.notEmpty and: { spectrumMidi.every { |message| message[1] <= 2 } }
        and: { cwtMidi.isEmpty }, "spectrum reconnect cleans only spectrum channels");
    0.3.wait; cwtMidi.clear; spectrumMidi.clear; ~cwtStop.value;
    check.value(cwtMidi.notEmpty and: { cwtMidi.every { |message| message[1] >= 3 } }
        and: { spectrumMidi.isEmpty }, "stopping CWT cleans only tracked channels");
    0.3.wait;
    check.value(controls.includesEqual("/router/unsubscribe").not, "stopping CWT does not unsubscribe spectrum");
    check.value(~spectrumRun[\running] and: { lease[\owners].includes(\spectrum) }
        and: { lease[\owners].includes(\cwt).not }, "spectrum retains shared lease");
    cwtMidi.clear; spectrumMidi.clear; ~cwtStart.value;
    check.value(cwtMidi.every { |message| message[1] >= 3 }
        and: { spectrumMidi.isEmpty }, "CWT restart never touches spectrum channels");
    0.5.wait; check.value(~cwtRun[\receiver].notNil, "CWT receiver restarts");
    cwtMidi.clear; spectrumMidi.clear; ~spectrumStop.value(true); 0.3.wait;
    check.value(spectrumMidi.notEmpty and: { spectrumMidi.every { |message| message[1] <= 2 } }
        and: { cwtMidi.isEmpty }, "stopping spectrum cleans only spectrum channels");
    cwtMidi.clear; spectrumMidi.clear; ~spectrumStart.value;
    check.value(spectrumMidi.every { |message| message[1] <= 2 }
        and: { cwtMidi.isEmpty }, "spectrum restart never touches tracked channels");
    0.5.wait; check.value(~spectrumRun[\receiver].notNil, "spectrum receiver restarts");
    ~cwtStop.value; 0.2.wait; ~spectrumStop.value(true); 0.3.wait;
    check.value(controls.includesEqual("/router/unsubscribe"), "last owner unsubscribes");
    check.value(~weatherLeaseState.isEmpty and: { ~cwtRun.isNil } and: { ~spectrumRun.isNil }, "concurrent cleanup complete");
    thisProcess.removeOSCRecvFunc(receiver); s.quit;
    "ALL CONCURRENT TESTS PASSED".postln; 0.exit;
}).play(SystemClock);
SystemClock.sched(30, { "TEST TIMEOUT".postln; ~cwtStop.value; ~spectrumStop.value(true); s.quit; 1.exit });
)
