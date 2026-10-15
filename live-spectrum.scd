/* Evaluate this whole file. See SPECTRUM.md. Stop live-cwt first: the router
   has one native lease per sender IP, not independent leases per sketch. */
(
if(~spectrumRun.notNil) { Error("Stop spectrum and wait for its fade before reloading").throw };
~spectrumConfig = (
    routerIP: "192.168.0.41", routerPort: 5005, localPort: 9000,
    mode: \physical, referenceTempC: 20, referenceRH: 50, referencePressureHpa: 1013.25,
    temperatureGain: 1.0, humidityGain: 1.0, pressureGain: 1.0,
    physicalGain: 0.1, significanceGain: 0.002, masterGain: 0.1,
    amplitudeCeiling: 0.02, smoothingSeconds: 2.0, staleTimeoutSeconds: 15.0,
    pendingTimeoutSeconds: 3.0, maxPendingFrames: 4, maxScales: 256,
    diagnosticsSeconds: 10.0, shutdownSeconds: 2.0
);
~spectrumFinite = { |v| v.isNumber and: { v.isNaN.not } and: { v.abs < inf } };
~spectrumSafe = { |v, maximum=100| if(~spectrumFinite.value(v)) { v.clip(0, maximum) } { 0 } };
~spectrumPitch = { |hz| (48 + (36 * ((hz.clip(0.05, 1) / 0.05).log2 / 20.log2))).midicps };
~spectrumFactor = { |signal|
    var c = ~spectrumConfig, t = c[\referenceTempC], rh = c[\referenceRH], p = c[\referencePressureHpa];
    var valid = [t, rh, p].every(~spectrumFinite) and: { t > -100 } and: { t < 100 }
        and: { rh > 0 } and: { rh <= 100 } and: { p > 0 };
    if(valid) {
        switch(signal, \temperature, { 1.0 }, \humidity, { (t + 243.5).squared / (rh * 17.67 * 243.5) },
            \pressure, { (t + 273.15) / p }, { 0 })
    } { 0 }
};
~spectrumSignificance = { |row|
    if((row[5] == 1) and: { ~spectrumFinite.value(row[4]) } and: { row[4] > 0 }) {
        row[1] / row[4].sqrt
    } { nil }
};
~spectrumBankDef = SynthDef(\weatherSpectrumBank, { |out=0, smoothing=2|
    var freqs = NamedControl.kr(\freqs, Array.fill(48, 440));
    var amps = NamedControl.kr(\amps, Array.fill(48, 0));
    // Lag time is the time to settle to 0.1%, not an exponential time constant.
    Out.ar(out, Mix(SinOsc.ar(Lag.kr(freqs, 0.2)) * Lag.kr(amps, smoothing.max(0.02))));
});
~spectrumOutputDef = SynthDef(\weatherSpectrumOutput, { |bus=0, master=0, gate=1, release=2|
    var input = In.ar(bus, 1) * Lag.kr(master, 0.2);
    var env = EnvGen.kr(Env.asr(0.05, 1, release), gate, doneAction: 2);
    var peak = Amplitude.kr(input, 0.001, 0.1);
    SendReply.kr(Impulse.kr(1) * (peak > 0.8), '/weatherSpectrum/limiting', [peak]);
    Out.ar(0, (Limiter.ar(input, 0.8, 0.01) * env) ! 2);
});

~spectrumUpdate = { |run|
    var c = ~spectrumConfig, clamps = 0;
    run[\streams].values.do { |st|
        var amps = Array.fill(48, 0.0), freqs = Array.fill(48, 440.0);
        var gain = ~spectrumSafe.value(c[(st[\signal].asString ++ "Gain").asSymbol]);
        var modeGain = ~spectrumSafe.value(c[if(c[\mode] == \physical) { \physicalGain } { \significanceGain }]);
        if(st[\ready] and: { st[\muted].not } and: { st[\rows].size == 48 }) {
            st[\rows].do { |row, i|
                var converted = if(c[\mode] == \physical) { row[1] * ~spectrumFactor.value(st[\signal]) } {
                    if(c[\mode] == \significance) { ~spectrumSignificance.value(row) ? 0 } { 0 }
                };
                var target = converted * gain * modeGain;
                var ceiling = ~spectrumSafe.value(c[\amplitudeCeiling], 0.1);
                freqs[i] = ~spectrumPitch.value(row[0]);
                if(~spectrumFinite.value(target).not or: { target < 0 } or: { target > ceiling }) { clamps = clamps + 1 };
                amps[i] = ~spectrumSafe.value(target, ceiling);
            };
        };
        if(st[\targets] != amps or: { st[\frequencies] != freqs } or: { st[\smooth] != c[\smoothingSeconds] }) {
            st[\targets] = amps; st[\frequencies] = freqs; st[\smooth] = c[\smoothingSeconds];
            st[\synth].setn(\amps, amps, \freqs, freqs);
            st[\synth].set(\smoothing, ~spectrumSafe.value(c[\smoothingSeconds], 30).max(0.02));
        };
    };
    run[\output].set(\master, ~spectrumSafe.value(c[\masterGain], 1));
    if(clamps > 0 and: { (Main.elapsedTime - run[\lastClamp]) > 5 }) {
        "Spectrum safety: % scale amplitudes clamped; reduce gains.".format(clamps).warn;
        run[\lastClamp] = Main.elapsedTime;
    };
};

// Returns false for malformed packets. No state is touched until this passes.
~spectrumPacketValid = { |m|
    var ok = m.size >= 10;
    if(ok) {
        ok = (m[1] == 3) and: { m[1].isInteger } and: { m[2].isString } and: { m[2].size > 0 }
            and: { m[2].size <= 128 } and: { ~spectrumFinite.value(m[3]) } and: { m[3] >= 1 }
            and: { m[3] <= 9007199254740991 } and: { m[3].floor == m[3] }
            and: { ~spectrumFinite.value(m[4]) } and: { m[4] >= -1 }
            and: { m[5].isInteger } and: { [0, 1].includes(m[5]) } and: { m[6].isString }
            and: { m.copyRange(7, 9).every { |v| v.isInteger and: { v >= 0 } } };
    };
    if(ok) {
        ok = m.size == (10 + (6 * m[9]));
        if(m[5] == 0) { ok = ok and: { m.copyRange(7, 9) == [0, 0, 0] } } {
            ok = ok and: { m[4] >= 0 } and: { m[6].isEmpty } and: { m[7] > 0 }
                and: { m[7] <= ~spectrumConfig[\maxScales] } and: { m[9] > 0 }
                and: { (m[8] + m[9]) <= m[7] };
            if(ok) {
                m[9].do { |i|
                    var r = m.copyRange(10 + (6*i), 15 + (6*i));
                    ok = ok and: { r.every(~spectrumFinite) } and: { r[0] > 0 } and: { r[1] >= 0 }
                        and: { r[3].isInteger } and: { [0, 1].includes(r[3]) }
                        and: { r[5].isInteger } and: { [0, 1].includes(r[5]) }
                        and: { (r[5] == 0) or: { r[4] > 0 } };
                };
            };
        };
    };
    ok
};
~spectrumReceive = { |run, m, sender, port|
    var st = run[\streams][m[0].asString], now = Main.elapsedTime, p, meta, conflict = false;
    if(run[\running] and: { port == run[\port] } and: { sender.ip == run[\router].ip } and: { st.notNil }) {
        if(~spectrumPacketValid.value(m).not) { run[\dropped] = run[\dropped] + 1 } {
            if(st[\retired].includesEqual(m[2]).not) {
                if(st[\epoch] != m[2]) {
                    if(st[\epoch].notNil) { st[\retired].add(st[\epoch]); if(st[\retired].size > 32) { st[\retired].removeAt(0) } };
                    run[\incomplete] = run[\incomplete] + st[\pending].size;
                    st[\epoch] = m[2]; st[\frame] = 0; st[\pending].clear;
                    st[\ready] = false; st[\reason] = "epoch-warmup";
                };
                if(m[3] > st[\frame]) {
                    if(m[5] == 0) {
                        st[\frame] = m[3]; st[\timestamp] = m[4]; st[\seen] = now;
                        st[\ready] = false; st[\reason] = m[6]; st[\rows] = [];
                        st[\pending].clear;
                    } {
                        p = st[\pending][m[3]];
                        meta = m.copyRange(1, 7);
                        if(p.isNil) {
                            if(st[\pending].size >= ~spectrumConfig[\maxPendingFrames]) {
                                var oldest = st[\pending].keys.asArray.sort.first;
                                st[\pending].removeAt(oldest); run[\incomplete] = run[\incomplete] + 1;
                            };
                            p = (meta: meta, rows: Array.newClear(m[7]), born: now, rejected: false);
                            st[\pending][m[3]] = p;
                        };
                        if(p[\meta] != meta) { conflict = true };
                        if(p[\rejected].not and: { conflict.not }) {
                            m[9].do { |i|
                                var idx = m[8] + i, row = m.copyRange(10 + (6*i), 15 + (6*i));
                                if(p[\rows][idx].notNil and: { p[\rows][idx] != row }) { conflict = true };
                            };
                            if(conflict.not) {
                                m[9].do { |i| p[\rows][m[8] + i] = m.copyRange(10 + (6*i), 15 + (6*i)) };
                                if(p[\rows].every { |r| r.notNil }) {
                                    (p[\rows].size - 1).do { |i| if(p[\rows][i][0] <= p[\rows][i+1][0]) { conflict = true } };
                                    if(conflict.not) {
                                        st[\rows] = p[\rows]; st[\frame] = m[3]; st[\timestamp] = m[4]; st[\seen] = now;
                                        st[\ready] = m[7] == 48;
                                        st[\reason] = if(st[\ready]) { "ready" } { "unsupported-scale-count" };
                                        st[\pending].keys.asArray.do { |key| if(key <= m[3]) { st[\pending].removeAt(key) } };
                                    };
                                };
                            };
                        };
                        if(conflict) { p[\rejected] = true; run[\dropped] = run[\dropped] + 1 };
                    };
                };
            };
        };
    };
};
~spectrumSweep = { |run|
    var now = Main.elapsedTime;
    run[\streams].values.do { |st|
        st[\pending].keys.asArray.do { |key|
            if((now - st[\pending][key][\born]) > ~spectrumConfig[\pendingTimeoutSeconds]) {
                st[\pending].removeAt(key); run[\incomplete] = run[\incomplete] + 1;
            };
        };
        if(st[\ready] and: { (now - st[\seen]) > ~spectrumConfig[\staleTimeoutSeconds] }) {
            st[\ready] = false; st[\reason] = "timeout";
        };
    };
};
~spectrumStatus = {
    var run = ~spectrumRun;
    if(run.isNil) { "Spectrum stopped".postln } {
        "Spectrum running=% leaseSent=% mode=% master=% physicalGain=% significanceGain=% dropped=% incomplete=%".format(
            run[\running], run[\subscribed], ~spectrumConfig[\mode], ~spectrumConfig[\masterGain],
            ~spectrumConfig[\physicalGain], ~spectrumConfig[\significanceGain], run[\dropped], run[\incomplete]).postln;
        run[\streams].values.do { |st|
            var rows = st[\rows], mags = rows.collect { |r| r[1] }, sig = rows.collect(~spectrumSignificance).reject(_.isNil);
            "% frame=% age=%s scales=% backgrounds=% state=% muted=% factor=% gain=%".format(st[\signal], st[\frame],
                (Main.elapsedTime - st[\seen]).round(0.1), rows.size, sig.size, st[\reason], st[\muted],
                ~spectrumFactor.value(st[\signal]), ~spectrumConfig[(st[\signal].asString ++ "Gain").asSymbol]).postln;
            if(rows.notEmpty) { "  raw=[%, %] strongestHz=% significance=[%, %] sourceUs=% epoch=%".format(
                mags.minItem, mags.maxItem, rows[mags.maxIndex][0], sig.minItem, sig.maxItem, st[\timestamp], st[\epoch]).postln };
        };
    };
};
~spectrumInspect = { |signal=\temperature, index=0|
    var st = if(~spectrumRun.notNil) { ~spectrumRun[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] };
    if(st.notNil and: { index.isInteger } and: { index >= 0 } and: { index < st[\rows].size }) {
        var row = st[\rows][index];
        (frequencyHz: row[0], magnitude: row[1], background: row[4], backgroundValid: row[5],
            physical: row[1] * ~spectrumFactor.value(signal), significance: ~spectrumSignificance.value(row)).postln;
    } { "No such received scale".warn };
};
~spectrumSetMode = { |mode| if([\physical, \significance].includes(mode)) { ~spectrumConfig[\mode] = mode } { "Unknown mode".warn } };
~spectrumSetGain = { |signal, gain|
    if([\temperature, \humidity, \pressure].includes(signal) and: { ~spectrumFinite.value(gain) } and: { gain >= 0 } and: { gain <= 100 }) {
        ~spectrumConfig[(signal.asString ++ "Gain").asSymbol] = gain;
    } { "Invalid sensor/gain (allowed 0..100)".warn };
};
~spectrumMute = { |signal, mute=true|
    var st = if(~spectrumRun.notNil) { ~spectrumRun[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] };
    if(st.notNil) { st[\muted] = mute == true };
};
~spectrumStop = { |immediate=false|
    var run = ~spectrumRun;
    if(run.notNil and: { run[\running] }) {
        var finish;
        run[\running] = false;
        if(run[\subscribed]) { run[\router].sendMsg('/router/unsubscribe', run[\port]); run[\subscribed] = false };
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        [\startup, \heartbeat, \tick].do { |key| if(run[key] !== thisThread) { run[key].tryPerform(\stop) } };
        CmdPeriod.remove(run[\onStop]); ServerQuit.remove(run[\onQuit]);
        finish = {
            run[\group].tryPerform(\free); run[\bus].tryPerform(\free);
            if(~spectrumRun === run) { ~spectrumRun = nil };
            "Spectrum stopped; lease and resources released.".postln;
        };
        if(immediate or: { run[\output].isNil } or: { s.serverRunning.not }) { finish.value } {
            var release = ~spectrumSafe.value(~spectrumConfig[\shutdownSeconds], 10).max(0.05);
            run[\output].set(\release, release, \gate, 0);
            SystemClock.sched(release + 0.1, { finish.value; nil });
        };
    };
};
~spectrumStart = {
    if(~spectrumRun.notNil) { "Spectrum is running or fading; wait for stop before restarting.".warn } {
        var c = ~spectrumConfig, run;
        run = (running: true, subscribed: false, router: NetAddr(c[\routerIP], c[\routerPort]), port: c[\localPort],
            streams: Dictionary.new, dropped: 0, incomplete: 0, lastClamp: -100, lastDiagnostic: Main.elapsedTime);
        ~spectrumRun = run;
        [\temperature, \humidity, \pressure].do { |signal|
            run[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] = (signal: signal, ready: false,
                muted: false, reason: "waiting", rows: [], frame: 0, seen: Main.elapsedTime,
                pending: Dictionary.new, retired: List.new);
        };
        run[\onStop] = { if(~spectrumRun === run) { ~spectrumStop.value(true) } };
        run[\onQuit] = { |server| if(server === s) { run[\onStop].value } };
        CmdPeriod.add(run[\onStop]); ServerQuit.add(run[\onQuit]);
        if(s.serverRunning.not) { s.options.numInputBusChannels = 0 };
        s.waitForBoot({
            if(run[\running]) {
                run[\startup] = Routine({
                    ~spectrumBankDef.send(s); ~spectrumOutputDef.send(s); s.sync;
                    if(run[\running]) {
                        if(thisProcess.openUDPPort(run[\port])) {
                            run[\bus] = Bus.audio(s, 1); run[\group] = Group.new(s);
                            run[\streams].values.do { |st| st[\synth] = Synth.tail(run[\group], \weatherSpectrumBank, [\out, run[\bus]]) };
                            run[\output] = Synth.tail(run[\group], \weatherSpectrumOutput, [\bus, run[\bus], \master, 0]);
                            run[\receiver] = { |msg, time, sender, port|
                                if(msg[0] == '/weatherSpectrum/limiting' and: { sender == s.addr }
                                    and: { msg[1] == run[\output].nodeID }) { "Spectrum limiter active: reduce gains".warn };
                                ~spectrumReceive.value(run, msg, sender, port);
                            };
                            thisProcess.addOSCRecvFunc(run[\receiver]);
                            run[\router].sendMsg('/router/subscribe', run[\port]); run[\subscribed] = true;
                            run[\heartbeat] = Routine({ loop { 10.wait; run[\router].sendMsg('/router/heartbeat', run[\port]) } }).play(SystemClock);
                            run[\tick] = Routine({ loop {
                                ~spectrumSweep.value(run); ~spectrumUpdate.value(run);
                                if((Main.elapsedTime - run[\lastDiagnostic]) >= c[\diagnosticsSeconds]) {
                                    ~spectrumStatus.value; run[\lastDiagnostic] = Main.elapsedTime;
                                }; 0.25.wait;
                            } }).play(SystemClock);
                            "Spectrum subscribed: %:% -> UDP %; awaiting complete frames.".format(c[\routerIP], c[\routerPort], run[\port]).postln;
                        } { "Cannot open spectrum UDP port".warn; ~spectrumStop.value(true) };
                    };
                }).play(SystemClock);
            };
        });
    };
};
if(~spectrumAutoStart ? true) { ~spectrumStart.value };
)
