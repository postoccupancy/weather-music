/* Evaluate this whole file. See SPECTRUM.md. Stop live-cwt first: the router
   has one native lease per sender IP, not independent leases per sketch. */
(
if(~spectrumRun.notNil) { Error("Stop spectrum and wait for its fade before reloading").throw };

// One native router lease is shared by every Weather Music sketch in this sclang.
if(~weatherLeaseAcquire.isNil) {
    ~weatherLeaseState = Dictionary.new;
    ~weatherLeaseAcquire = { |owner, router, port|
        var key = router.ip ++ ":" ++ router.port ++ ":" ++ port, entry = ~weatherLeaseState[key];
        if(entry.isNil) { entry = (router: router, port: port, owners: Set.new, heartbeat: nil); ~weatherLeaseState[key] = entry };
        entry[\owners].add(owner); entry[\router].sendMsg('/router/subscribe', port);
        if(entry[\heartbeat].isNil) {
            entry[\heartbeat] = Routine({ loop { 10.wait; if(entry[\owners].notEmpty) { entry[\router].sendMsg('/router/heartbeat', port) } } }).play(SystemClock);
        };
        key
    };
    ~weatherLeaseRelease = { |owner, key|
        var entry = ~weatherLeaseState[key];
        if(entry.notNil) {
            entry[\owners].remove(owner);
            if(entry[\owners].isEmpty) {
                entry[\heartbeat].tryPerform(\stop); entry[\router].sendMsg('/router/unsubscribe', entry[\port]);
                ~weatherLeaseState.removeAt(key);
            };
        };
    };
    ~weatherResolveOutputBus = { |requested, fallback=0, label="Weather Music"|
        var channels = s.options.numOutputBusChannels;
        if(requested.isInteger and: { requested >= 0 } and: { (requested + 1) < channels }) { requested } {
            if(fallback.isInteger and: { fallback >= 0 } and: { (fallback + 1) < channels }) {
                "% output bus % needs hardware channels %–%; device has % outputs. Using explicit fallback bus %."
                    .format(label, requested, requested + 1, requested + 2, channels, fallback).warn; fallback
            } { "% has no valid stereo output on this %‑channel device.".format(label, channels).warn; nil };
        }
    };
};
~spectrumConfig = (
    routerIP: "192.168.0.41", routerPort: 5005, localPort: 9000,
    mode: \physical, referenceTempC: 20, referenceRH: 50, referencePressureHpa: 1013.25,
    baseNote: 48.0, pitchSpan: 36.0,
    baseNoteOverrides: Dictionary.new, pitchSpanOverrides: Dictionary.new,
    temperatureWaveform: \sine, humidityWaveform: \sine, pressureWaveform: \sine,
    temperatureGain: 1.0, humidityGain: 1.0, pressureGain: 1.0,
    physicalGain: 0.1, significanceGain: 0.002, masterGain: 0.1,
    amplitudeCeiling: 0.02, smoothingSeconds: 2.0, staleTimeoutSeconds: 15.0,
    pendingTimeoutSeconds: 3.0, maxPendingFrames: 4, maxScales: 256,
    outputBus: 2, fallbackOutputBus: 0,
    diagnosticsSeconds: 10.0, rejectDiagnostics: true, rejectDiagnosticSeconds: 5.0,
    shutdownSeconds: 2.0
);
~spectrumFinite = { |v| v.isNumber and: { v.isNaN.not } and: { v.abs < inf } };
// OSC strings arrive as Symbols in SuperCollider 3.14's native decoder.
~spectrumText = { |v| v.isString or: { v.isKindOf(Symbol) } };
~spectrumSafe = { |v, maximum=100| if(~spectrumFinite.value(v)) { v.clip(0, maximum) } { 0 } };
~spectrumPitch = { |hz, config, signal|
    var c = config ? ~spectrumConfig;
    var base = c[\baseNoteOverrides][signal] ? c[\baseNote];
    var span = c[\pitchSpanOverrides][signal] ? c[\pitchSpan];
    (base + (span * ((hz.clip(0.05, 1) / 0.05).log2 / 20.log2))).midicps
};
~spectrumWaveControls = { |waveform|
    switch(waveform,
        \sine, { (mix: 0.0, width: 0.5, level: 1.0) },
        \triangle, { (mix: 1.0, width: 0.5, level: 0.8) },
        \saw, { (mix: 1.0, width: 0.001, level: 0.55) },
        { nil })
};
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
~spectrumBankDef = SynthDef(\weatherSpectrumBank, { |out=0, smoothing=2, waveMix=0, waveWidth=0.5, waveLevel=1|
    var freqs = NamedControl.kr(\freqs, Array.fill(48, 440));
    var amps = NamedControl.kr(\amps, Array.fill(48, 0));
    var pitch = Lag.kr(freqs, 0.2);
    var sine = SinOsc.ar(pitch);
    var shaped = VarSaw.ar(pitch, 0, Lag.kr(waveWidth, 0.08));
    var waveform = XFade2.ar(sine, shaped, (Lag.kr(waveMix, 0.08) * 2) - 1)
        * Lag.kr(waveLevel, 0.08);
    // Lag time is the time to settle to 0.1%, not an exponential time constant.
    Out.ar(out, Mix(waveform * Lag.kr(amps, smoothing.max(0.02))));
});
~spectrumOutputDef = SynthDef(\weatherSpectrumOutput, { |bus=0, out=0, master=0, gate=1, release=2|
    var input = In.ar(bus, 1) * Lag.kr(master, 0.2);
    var env = EnvGen.kr(Env.asr(0.05, 1, release), gate, doneAction: 2);
    var peak = Amplitude.kr(input, 0.001, 0.1);
    SendReply.kr(Impulse.kr(1) * (peak > 0.8), '/weatherSpectrum/limiting', [peak]);
    Out.ar(out, (Limiter.ar(input, 0.8, 0.01) * env) ! 2);
});

~spectrumUpdate = { |run|
    var c = ~spectrumConfig, clamps = 0;
    run[\streams].values.do { |st|
        var amps = Array.fill(48, 0.0), freqs = Array.fill(48, 440.0), requestedWave, wave, gain, modeGain;
        requestedWave = c[(st[\signal].asString ++ "Waveform").asSymbol];
        wave = ~spectrumWaveControls.value(requestedWave);
        if(wave.isNil) { requestedWave = \sine; wave = ~spectrumWaveControls.value(\sine) };
        gain = ~spectrumSafe.value(c[(st[\signal].asString ++ "Gain").asSymbol]);
        modeGain = ~spectrumSafe.value(c[if(c[\mode] == \physical) { \physicalGain } { \significanceGain }]);
        if(st[\ready] and: { st[\muted].not } and: { st[\rows].size == 48 }) {
            st[\rows].do { |row, i|
                var converted = if(c[\mode] == \physical) { row[1] * ~spectrumFactor.value(st[\signal]) } {
                    if(c[\mode] == \significance) { ~spectrumSignificance.value(row) ? 0 } { 0 }
                };
                var target = converted * gain * modeGain;
                var ceiling = ~spectrumSafe.value(c[\amplitudeCeiling], 0.1);
                freqs[i] = ~spectrumPitch.value(row[0], c, st[\signal]);
                if(~spectrumFinite.value(target).not or: { target < 0 } or: { target > ceiling }) { clamps = clamps + 1 };
                amps[i] = ~spectrumSafe.value(target, ceiling);
            };
        };
        if(st[\targets] != amps or: { st[\frequencies] != freqs } or: { st[\smooth] != c[\smoothingSeconds] }) {
            st[\targets] = amps; st[\frequencies] = freqs; st[\smooth] = c[\smoothingSeconds];
            st[\synth].setn(\amps, amps, \freqs, freqs);
            st[\synth].set(\smoothing, ~spectrumSafe.value(c[\smoothingSeconds], 30).max(0.02));
        };
        if(st[\waveform] != requestedWave) {
            st[\waveform] = requestedWave;
            st[\waveLevel] = wave[\level];
            st[\synth].set(\waveMix, wave[\mix], \waveWidth, wave[\width], \waveLevel, wave[\level]);
        };
    };
    run[\output].set(\master, ~spectrumSafe.value(c[\masterGain], 1));
    if(clamps > 0 and: { (Main.elapsedTime - run[\lastClamp]) > 5 }) {
        "Spectrum safety: % scale amplitudes clamped; reduce gains.".format(clamps).warn;
        run[\lastClamp] = Main.elapsedTime;
    };
};

// Records the first failed predicate for bounded live diagnostics. OSC strings
// decode as Symbols in native SuperCollider, while numeric OSC i/f/d types retain
// Integer/Float classes.
~spectrumPacketValid = { |m|
    var error, reject, r;
    reject = { |field, index, value, expected|
        if(error.isNil) { error = (field: field, index: index, value: value, expected: expected) };
    };
    if(m.size < 10) { reject.value(\headerLength, m.size, m.size, ">= 10") };
    if(error.isNil and: { m[1].isInteger.not or: { m[1] != 3 } }) { reject.value(\version, 1, m[1], "integer 3") };
    if(error.isNil and: { (~spectrumText.value(m[2])).not or: { m[2].asString.size < 1 } or: { m[2].asString.size > 128 } }) { reject.value(\epoch, 2, m[2], "OSC string 1..128 chars") };
    // Decimal integer literals overflow SuperCollider's Integer class; express
    // JavaScript's maximum safe integer as a Float for this float64 field.
    if(error.isNil and: { (~spectrumFinite.value(m[3])).not or: { m[3] < 1 } or: { m[3] > 9.007199254740991e15 } or: { (m[3] - m[3].floor).abs > 0 } }) { reject.value(\frame, 3, m[3], "positive integral float64") };
    if(error.isNil and: { (~spectrumFinite.value(m[4])).not or: { m[4] < -1 } }) { reject.value(\timestamp, 4, m[4], "finite number >= -1") };
    if(error.isNil and: { m[5].isInteger.not or: { [0,1].includes(m[5]).not } }) { reject.value(\valid, 5, m[5], "integer 0 or 1") };
    if(error.isNil and: { (~spectrumText.value(m[6])).not }) { reject.value(\reason, 6, m[6], "OSC string") };
    if(error.isNil) {
        [7,8,9].do { |index| if(error.isNil and: { m[index].isInteger.not or: { m[index] < 0 } }) { reject.value([\total,\offset,\count][index-7], index, m[index], "nonnegative integer") } };
    };
    if(error.isNil and: { m.size != (10 + (6*m[9])) }) { reject.value(\packetLength, m.size, m.size, 10+(6*m[9])) };
    if(error.isNil and: { m[5] == 0 }) {
        if((m[7] != 0) or: { m[8] != 0 } or: { m[9] != 0 }) { reject.value(\invalidRange, 7, m.copyRange(7,9), [0,0,0]) };
    };
    if(error.isNil and: { m[5] == 1 }) {
        if(m[4] < 0) { reject.value(\timestamp, 4, m[4], ">= 0 for valid frame") };
        if(error.isNil and: { m[6].asString.size != 0 }) { reject.value(\reason, 6, m[6], "empty for valid frame") };
        if(error.isNil and: { (m[7] < 1) or: { m[7] > ~spectrumConfig[\maxScales] } }) { reject.value(\total, 7, m[7], "1..maxScales") };
        if(error.isNil and: { (m[9] < 1) or: { (m[8]+m[9]) > m[7] } }) { reject.value(\chunkRange, 8, [m[8],m[9]], "positive count within total") };
        if(error.isNil) {
            m[9].do { |i|
                if(error.isNil) {
                    r = m.copyRange(10+(6*i), 15+(6*i));
                    if((r.every { |value| ~spectrumFinite.value(value) }).not) { reject.value(\scaleFinite, 10+(6*i), r, "six finite numerics") };
                    if(error.isNil and: { (r[0] <= 0) or: { r[1] < 0 } }) { reject.value(\scaleValues, 10+(6*i), r.copyRange(0,1), "frequency > 0; magnitude >= 0") };
                    if(error.isNil and: { r[3].isInteger.not or: { [0,1].includes(r[3]).not } }) { reject.value(\phaseValid, 13+(6*i), r[3], "integer 0 or 1") };
                    if(error.isNil and: { r[5].isInteger.not or: { [0,1].includes(r[5]).not } }) { reject.value(\backgroundValid, 15+(6*i), r[5], "integer 0 or 1") };
                    if(error.isNil and: { (r[5] == 1) and: { r[4] <= 0 } }) { reject.value(\backgroundPower, 14+(6*i), r[4], "> 0 when valid") };
                };
            };
        };
    };
    ~spectrumLastValidationError = error;
    error.isNil
};
~spectrumReceive = { |run, m, sender, port|
    var st = run[\streams][m[0].asString], now = Main.elapsedTime, p, meta, conflict = false;
    if(run[\running] and: { port == run[\port] } and: { sender.ip == run[\router].ip } and: { st.notNil }) {
        if(~spectrumPacketValid.value(m).not) {
            var error = ~spectrumLastValidationError;
            run[\rejected] = run[\rejected] + 1;
            if(~spectrumConfig[\rejectDiagnostics] and: { (now-run[\lastRejectDiagnostic]) >= ~spectrumConfig[\rejectDiagnosticSeconds] }) {
                "Spectrum rejected field=% index=% value=% class=% expected=%".format(error[\field], error[\index], error[\value], error[\value].class, error[\expected]).warn;
                run[\lastRejectDiagnostic] = now;
            };
        } {
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
                                        run[\completed] = run[\completed] + 1;
                                        st[\pending].keys.asArray.do { |key| if(key <= m[3]) { st[\pending].removeAt(key) } };
                                    };
                                };
                            };
                        };
                        if(conflict) { p[\rejected] = true; run[\rejected] = run[\rejected] + 1 };
                    };
                } { run[\ignored] = run[\ignored] + 1 };
            } { run[\ignored] = run[\ignored] + 1 };
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
        "Spectrum running=% leaseSent=% mode=% baseNote=% pitchSpan=% outputBus=% master=% physicalGain=% significanceGain=% rejected=% ignored=% awaiting=% incomplete=% complete=%".format(
            run[\running], run[\subscribed], ~spectrumConfig[\mode],
            ~spectrumConfig[\baseNote], ~spectrumConfig[\pitchSpan], run[\activeOutputBus], ~spectrumConfig[\masterGain],
            ~spectrumConfig[\physicalGain], ~spectrumConfig[\significanceGain], run[\rejected], run[\ignored],
            run[\streams].values.sum { |st| st[\pending].size }, run[\incomplete], run[\completed]).postln;
        run[\streams].values.do { |st|
            var rows = st[\rows], mags = rows.collect { |r| r[1] }, sig = rows.collect(~spectrumSignificance).reject(_.isNil);
            "% frame=% age=%s scales=% backgrounds=% state=% muted=% waveform=% factor=% gain=%".format(st[\signal], st[\frame],
                (Main.elapsedTime - st[\seen]).round(0.1), rows.size, sig.size, st[\reason], st[\muted],
                st[\waveform], ~spectrumFactor.value(st[\signal]), ~spectrumConfig[(st[\signal].asString ++ "Gain").asSymbol]).postln;
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
// Bypasses OSC, banks, control bus and limiter for a brief output-device check.
~spectrumTestTone = {
    if(s.serverRunning) {
        { var env = EnvGen.kr(Env.perc(0.02, 0.8), doneAction: 2); (SinOsc.ar(440) * env * 0.03) ! 2 }.play(s);
        "Playing a quiet 440 Hz output test for about one second.".postln;
    } { "Boot the audio server before running ~spectrumTestTone.value.".warn };
};
~spectrumSetMode = { |mode| if([\physical, \significance].includes(mode)) { ~spectrumConfig[\mode] = mode } { "Unknown mode".warn } };
~spectrumSetBaseNote = { |note, signal|
    if(signal.notNil and: { [\temperature, \humidity, \pressure].includes(signal).not }) { "Unknown spectrum pitch-override sensor.".warn } {
        if(note.isNil and: { signal.notNil }) { ~spectrumConfig[\baseNoteOverrides].removeAt(signal) } {
            if(~spectrumFinite.value(note) and: { note >= 24 } and: { note <= 72 }) {
                if(signal.isNil) { ~spectrumConfig[\baseNote] = note.asFloat } { ~spectrumConfig[\baseNoteOverrides][signal] = note.asFloat };
            } { "Invalid base note (allowed MIDI 24..72; nil clears a sensor override).".warn };
        };
    };
};
~spectrumSetPitchSpan = { |semitones, signal|
    if(signal.notNil and: { [\temperature, \humidity, \pressure].includes(signal).not }) { "Unknown spectrum pitch-override sensor.".warn } {
        if(semitones.isNil and: { signal.notNil }) { ~spectrumConfig[\pitchSpanOverrides].removeAt(signal) } {
            if(~spectrumFinite.value(semitones) and: { semitones >= 12 } and: { semitones <= 72 }) {
                if(signal.isNil) { ~spectrumConfig[\pitchSpan] = semitones.asFloat } { ~spectrumConfig[\pitchSpanOverrides][signal] = semitones.asFloat };
            } { "Invalid pitch span (allowed 12..72 semitones; nil clears a sensor override).".warn };
        };
    };
};
~spectrumSetWaveform = { |signal, waveform|
    if([\temperature, \humidity, \pressure].includes(signal).not) { "Unknown sensor bank".warn } {
        if(~spectrumWaveControls.value(waveform).isNil) { "Unknown waveform (use sine, triangle, or saw).".warn } {
            ~spectrumConfig[(signal.asString ++ "Waveform").asSymbol] = waveform;
        };
    };
};
~spectrumSetGain = { |signal, gain|
    if([\temperature, \humidity, \pressure].includes(signal) and: { ~spectrumFinite.value(gain) } and: { gain >= 0 } and: { gain <= 100 }) {
        ~spectrumConfig[(signal.asString ++ "Gain").asSymbol] = gain;
    } { "Invalid sensor/gain (allowed 0..100)".warn };
};
~spectrumMute = { |signal, mute=true|
    var st = if(~spectrumRun.notNil) { ~spectrumRun[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] };
    if(st.notNil) { st[\muted] = mute == true };
};
~spectrumSetOutputBus = { |bus|
    var run = ~spectrumRun, resolved;
    if(bus.isInteger and: { bus >= 0 }) {
        ~spectrumConfig[\outputBus] = bus;
        if(run.notNil and: { s.serverRunning }) {
            resolved = ~weatherResolveOutputBus.value(bus, ~spectrumConfig[\fallbackOutputBus], "Full spectrum");
            if(resolved.notNil) { run[\activeOutputBus] = resolved; run[\output].set(\out, resolved) };
        };
    } { "Invalid spectrum output bus (use a nonnegative integer).".warn };
};
~spectrumStop = { |immediate=false|
    var run = ~spectrumRun;
    if(run.notNil and: { run[\running] }) {
        var finish;
        run[\running] = false;
        if(run[\subscribed]) { ~weatherLeaseRelease.value(\spectrum, run[\leaseKey]); run[\subscribed] = false };
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        [\startup, \tick].do { |key| if(run[key] !== thisThread) { run[key].tryPerform(\stop) } };
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
            streams: Dictionary.new, rejected: 0, ignored: 0, incomplete: 0, completed: 0,
            lastRejectDiagnostic: -100, lastClamp: -100, lastDiagnostic: Main.elapsedTime);
        ~spectrumRun = run;
        [\temperature, \humidity, \pressure].do { |signal|
            run[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] = (signal: signal, ready: false,
                muted: false, reason: "waiting", rows: [], frame: 0, seen: Main.elapsedTime,
                pending: Dictionary.new, retired: List.new, waveform: nil, waveLevel: 1.0);
        };
        run[\onStop] = { if(~spectrumRun === run) { ~spectrumStop.value(true) } };
        run[\onQuit] = { |server| if(server === s) { run[\onStop].value } };
        CmdPeriod.add(run[\onStop]); ServerQuit.add(run[\onQuit]);
        if(s.serverRunning.not) { s.options.numInputBusChannels = 0 };
        s.waitForBoot({
            if(run[\running]) {
                run[\startup] = Routine({
                    var resolved;
                    ~spectrumBankDef.send(s); ~spectrumOutputDef.send(s); s.sync;
                    if(run[\running]) {
                        resolved = ~weatherResolveOutputBus.value(c[\outputBus], c[\fallbackOutputBus], "Full spectrum");
                        if(resolved.isNil) { "Cannot start spectrum without a valid stereo output.".warn; ~spectrumStop.value(true) } {
                        if(thisProcess.openUDPPort(run[\port])) {
                            run[\activeOutputBus] = resolved;
                            run[\bus] = Bus.audio(s, 1); run[\group] = Group.new(s);
                            run[\streams].values.do { |st| st[\synth] = Synth.tail(run[\group], \weatherSpectrumBank, [\out, run[\bus]]) };
                            run[\output] = Synth.tail(run[\group], \weatherSpectrumOutput,
                                [\bus, run[\bus], \out, resolved, \master, 0]);
                            run[\receiver] = { |msg, time, sender, port|
                                if(msg[0] == '/weatherSpectrum/limiting' and: { sender == s.addr }
                                    and: { msg[1] == run[\output].nodeID }) { "Spectrum limiter active: reduce gains".warn };
                                ~spectrumReceive.value(run, msg, sender, port);
                            };
                            thisProcess.addOSCRecvFunc(run[\receiver]);
                            run[\leaseKey] = ~weatherLeaseAcquire.value(\spectrum, run[\router], run[\port]); run[\subscribed] = true;
                            run[\tick] = Routine({ loop {
                                ~spectrumSweep.value(run); ~spectrumUpdate.value(run);
                                if((Main.elapsedTime - run[\lastDiagnostic]) >= c[\diagnosticsSeconds]) {
                                    ~spectrumStatus.value; run[\lastDiagnostic] = Main.elapsedTime;
                                }; 0.25.wait;
                            } }).play(SystemClock);
                            "Spectrum subscribed: %:% -> UDP %, hardware outputs %–%; awaiting complete frames."
                                .format(c[\routerIP], c[\routerPort], run[\port], resolved + 1, resolved + 2).postln;
                        } { "Cannot open spectrum UDP port".warn; ~spectrumStop.value(true) };
                        };
                    };
                }).play(SystemClock);
            };
        });
    };
};
if(~spectrumAutoStart ? true) { ~spectrumStart.value };
)
