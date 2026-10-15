// Shared native lease and concurrent lifecycle fixture. No Pi traffic; audio muted.
(
var root = thisProcess.nowExecutingPath.dirname.dirname;
var check, controls = List.new, receiver, deadline;
~cwtAutoStart = false; ~spectrumAutoStart = false;
(root +/+ "live-spectrum.scd").load;
(root +/+ "live-cwt.scd").load;
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
~cwtStart.value; ~spectrumStart.value;
Routine({
    var lease;
    deadline = Main.elapsedTime + 20;
    while { (~cwtRun.tryPerform(\at, \receiver).isNil or: { ~spectrumRun.tryPerform(\at, \receiver).isNil })
        and: { Main.elapsedTime < deadline } } { 0.1.wait };
    check.value(~cwtRun[\receiver].notNil and: { ~spectrumRun[\receiver].notNil }, "both instruments started on one receive port");
    lease = ~weatherLeaseState.values.first;
    check.value(lease.notNil and: { lease[\owners].includes(\cwt) }
        and: { lease[\owners].includes(\spectrum) } and: { lease[\heartbeat].notNil }, "shared lease owns both instruments and one heartbeat");
    check.value(~cwtRun[\activeOutputBus] == 0 and: { ~spectrumRun[\activeOutputBus] == 0 }, "stereo device uses explicit spectrum fallback");
    check.value(~weatherResolveOutputBus.value(0, 0, "test") == 0, "output resolver survives spectrum-then-CWT load order");
    check.value(~cwtRun[\output].nodeID != ~spectrumRun[\output].nodeID, "instruments retain distinct output synths");
    ~cwtStop.value; 0.3.wait;
    check.value(controls.includesEqual("/router/unsubscribe").not, "stopping CWT does not unsubscribe spectrum");
    check.value(~spectrumRun[\running] and: { lease[\owners].includes(\spectrum) }
        and: { lease[\owners].includes(\cwt).not }, "spectrum retains shared lease");
    ~spectrumStop.value(true); 0.3.wait;
    check.value(controls.includesEqual("/router/unsubscribe"), "last owner unsubscribes");
    check.value(~weatherLeaseState.isEmpty and: { ~cwtRun.isNil } and: { ~spectrumRun.isNil }, "concurrent cleanup complete");
    thisProcess.removeOSCRecvFunc(receiver); s.quit;
    "ALL CONCURRENT TESTS PASSED".postln; 0.exit;
}).play(SystemClock);
SystemClock.sched(30, { "TEST TIMEOUT".postln; ~cwtStop.value; ~spectrumStop.value(true); s.quit; 1.exit });
)
