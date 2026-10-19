/* Evaluate this whole file. See SPECTRUM.md. It shares one reference-counted
   native router lease with live-cwt.scd, so both sketches may run together. */
(
if(~spectrumRun.notNil) { Error("Stop spectrum and wait for its fade before reloading").throw };
(thisProcess.nowExecutingPath.dirname +/+ "midi-rhythm.scd").load;

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
};
// Refresh independently of the lease helpers. Older live sessions may already
// have a lease function but no output resolver, depending on source load order.
~weatherResolveOutputBus = { |requested, fallback=0, label="Weather Music"|
    var channels = s.options.numOutputBusChannels;
    if(requested.isInteger and: { requested >= 0 } and: { (requested + 1) < channels }) { requested } {
        if(fallback.isInteger and: { fallback >= 0 } and: { (fallback + 1) < channels }) {
            "% output bus % needs hardware channels %–%; device has % outputs. Using explicit fallback bus %."
                .format(label, requested, requested + 1, requested + 2, channels, fallback).warn; fallback
        } { "% has no valid stereo output on this %‑channel device.".format(label, channels).warn; nil };
    }
};
~spectrumConfig = (
    routerIP: "192.168.0.41", routerPort: 5005, localPort: 9000,
    mode: \significance, referenceTempC: 20, referenceRH: 50, referencePressureHpa: 1013.25,
    baseNote: 48.0, pitchSpan: 48.0,
    baseNoteOverrides: Dictionary.new, pitchSpanOverrides: Dictionary.new,
    temperatureWaveform: \sine, humidityWaveform: \sine, pressureWaveform: \sine,
    temperatureGain: 1.0, humidityGain: 1.0, pressureGain: 1.0,
    physicalGain: 1.0, significanceGain: 0.001, masterGain: 1.0,
    amplitudeCeiling: 0.02, smoothingSeconds: 2.0, staleTimeoutSeconds: 15.0,
    pendingTimeoutSeconds: 3.0, maxPendingFrames: 4, maxScales: 256,
    outputBus: 2, fallbackOutputBus: 0,
    toneEnabled: true, midiEnabled: true, midiDevice: "IAC Driver", midiPort: "Bus 3 - Ableton Live",
    temperatureMidiChannel: 1, humidityMidiChannel: 2, pressureMidiChannel: 3,
    midiExpressionFloor: 0.0001, midiExpressionCeiling: 0.005,
    midiExpressionSmoothing: 0.5, midiExpressionDeadband: 2, midiNoteOnVelocity: 64,
    rhythmEnabled: true, rhythmMidiDevice: "IAC Driver", rhythmMidiPort: "Bus 4 - Ableton Rhythm",
    rhythmSourceMinHz: 0.05, rhythmSourceMaxHz: 1.0, rhythmPulseMinHz: 0.5, rhythmPulseMaxHz: 4.0,
    rhythmPulseDuration: 0.08, rhythmVelocityInputFloor: 0.0, rhythmVelocityInputCeiling: 4.0,
    rhythmVelocityMin: 35, rhythmVelocityMax: 110, rhythmMaxEventsPerTick: 16,
    rhythmSelection: \perBand, rhythmTopN: 3,
    rhythmBands: [[0.05, 0.12], [0.12, 0.35], [0.35, 1.000001]],
    rhythmNoteMapping: \perBand, rhythmSensorNotes: (temperature:36, humidity:38, pressure:42),
    rhythmBandNotes: [36, 38, 42],
    diagnosticsSeconds: 10.0, rejectDiagnostics: true, rejectDiagnosticSeconds: 5.0,
    shutdownSeconds: 2.0
);
~spectrumFinite = { |v| v.isNumber and: { v.isNaN.not } and: { v.abs < inf } };
// OSC strings arrive as Symbols in SuperCollider 3.14's native decoder.
~spectrumText = { |v| v.isString or: { v.isKindOf(Symbol) } };
~spectrumSafe = { |v, maximum=100| if(~spectrumFinite.value(v)) { v.clip(0, maximum) } { 0 } };
~spectrumMidiCoordinate = { |hz, config, signal|
    var c = config ? ~spectrumConfig;
    var base = c[\baseNoteOverrides][signal] ? c[\baseNote];
    var span = c[\pitchSpanOverrides][signal] ? c[\pitchSpan];
    base + (span * ((hz.clip(0.05, 1) / 0.05).log2 / 20.log2))
};
~spectrumPitch = { |hz, config, signal|
    ~spectrumMidiCoordinate.value(hz, config, signal).midicps
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

// MIDI transport is isolated behind these functions so fixture tests can inject
// a recorder without requiring a physical or virtual MIDI destination.
~spectrumMidiOpen = { |device, port|
    var out;
    MIDIClient.init;
    out = MIDIOut.newByName(device.asString, port.asString);
    out.latency = 0;
    out
};
~spectrumMidiEmit = { |out, type, channel, note=0, value=0|
    switch(type,
        \noteOn, { out.noteOn(channel, note, value) },
        \noteOff, { out.noteOff(channel, note, value) },
        \polyTouch, { out.polyTouch(channel, note, value) },
        \allNotesOff, { out.allNotesOff(channel) }
    );
};
~spectrumMidiPanicRun = { |run|
    if(run.notNil) {
        if(run[\midiOut].notNil) {
            run[\midiActive].values.do { |entry|
                if((entry[\channel] >= 0) and: { entry[\channel] <= 2 }) {
                    ~spectrumMidiEmit.value(run[\midiOut], \noteOff, entry[\channel], entry[\note], 0);
                };
            };
            // Channels 1-3 (SuperCollider 0-2) belong exclusively to the spectrum.
            (0..2).do { |channel| ~spectrumMidiEmit.value(run[\midiOut], \allNotesOff, channel) };
        };
        run[\midiActive].clear; run[\midiChannelsUsed].clear;
    };
};
~spectrumMidiConnect = { |run|
    var c = ~spectrumConfig, error, destinations;
    ~spectrumMidiPanicRun.value(run); run[\midiOut] = nil; run[\midiConnected] = false;
    if(c[\toneEnabled] and: { c[\midiEnabled] }) {
        try { run[\midiOut] = ~spectrumMidiOpen.value(c[\midiDevice], c[\midiPort]) }
        { |caught| error = caught };
        if(run[\midiOut].notNil) {
            run[\midiConnected] = true; run[\midiError] = nil;
            "Spectrum MIDI connected: % / %.".format(c[\midiDevice], c[\midiPort]).postln;
        } {
            try {
                MIDIClient.init;
                destinations = MIDIClient.destinations.collect { |endpoint|
                    endpoint.device.asString ++ " / " ++ endpoint.name.asString
                };
            } { |caught| if(error.isNil) { error = caught } };
            run[\midiError] = if(error.notNil) { error.asString } { "destination not found" };
            "Spectrum MIDI unavailable: configured destination '% / %' could not be opened (%). Available destinations: %."
                .format(c[\midiDevice], c[\midiPort], run[\midiError], destinations ? []).warn;
        };
    } { run[\midiError] = "disabled" };
};
~spectrumRhythmOpen = { |device, port| ~spectrumMidiOpen.value(device, port) };
~spectrumRhythmEmit = { |out, type, channel, note=0, value=0| ~spectrumMidiEmit.value(out, type, channel, note, value) };
~spectrumRhythmConnect = { |run|
    var c = ~spectrumConfig, error, destinations;
    ~weatherRhythmPanic.value(run, (0..2), ~spectrumRhythmEmit, false);
    run[\rhythmOut] = nil; run[\rhythmConnected] = false;
    if(c[\rhythmEnabled]) {
        try { run[\rhythmOut] = ~spectrumRhythmOpen.value(c[\rhythmMidiDevice], c[\rhythmMidiPort]) } { |caught| error = caught };
        if(run[\rhythmOut].notNil) {
            run[\rhythmConnected] = true; run[\rhythmError] = nil;
            "Spectrum rhythm connected: % / %.".format(c[\rhythmMidiDevice], c[\rhythmMidiPort]).postln;
        } {
            try { MIDIClient.init; destinations = MIDIClient.destinations.collect { |ep| ep.device.asString ++ " / " ++ ep.name.asString } } { };
            run[\rhythmError] = if(error.notNil) { error.asString } { "destination not found" };
            "Spectrum rhythm unavailable: configured destination '% / %' could not be opened (%). Available destinations: %."
                .format(c[\rhythmMidiDevice], c[\rhythmMidiPort], run[\rhythmError], destinations ? []).warn;
        };
    } { run[\rhythmError] = "disabled" };
};
~spectrumRhythmDesired = { |run|
    var c = ~spectrumConfig, desired = Dictionary.new, bands = c[\rhythmBands];
    run[\streams].values.do { |st|
        var candidates = List.new, chosen = List.new, channel;
        if(st[\ready] and: { st[\muted].not } and: { st[\rows].size == 48 }) {
            st[\rows].do { |row, index| var significance = ~spectrumSignificance.value(row);
                if(significance.notNil and: { significance > 0 }) {
                    candidates.add((index:index, hz:row[0], significance:significance));
                };
            };
            if(c[\rhythmSelection] == \topN) {
                chosen = candidates.asArray.sort { |a,b| a[\significance] > b[\significance] }
                    .keep(c[\rhythmTopN].asInteger.clip(1, 48)).as(List);
            } {
                bands.do { |band, bandIndex|
                    var match = candidates.select { |item| item[\hz] >= band[0] and: { item[\hz] < band[1] } }
                        .sort { |a,b| a[\significance] > b[\significance] }.first;
                    if(match.notNil) { match = match.copy; match[\band] = bandIndex; chosen.add(match) };
                };
            };
            channel = (c[(st[\signal].asString ++ "MidiChannel").asSymbol] ? 1).asInteger.clip(1,3) - 1;
            chosen.do { |item|
                var band = item[\band] ? bands.detectIndex { |range| item[\hz] >= range[0] and: { item[\hz] < range[1] } } ? 0;
                var note = if(c[\rhythmNoteMapping] == \perSensor) {
                    c[\rhythmSensorNotes][st[\signal]] ? 36
                } { c[\rhythmBandNotes].wrapAt(band) ? 36 };
                var key = st[\signal].asString ++ "/" ++ item[\index];
                desired[key] = (key:key, channel:channel, note:note.asInteger.clip(0,127), sourceHz:item[\hz],
                    level:item[\significance], significance:item[\significance], signal:st[\signal], scale:item[\index], band:band);
            };
        };
    };
    desired
};
~spectrumRhythmSync = { |run, now|
    now = now ? Main.elapsedTime;
    ~weatherRhythmSync.value(run, if(~spectrumConfig[\rhythmEnabled]) { ~spectrumRhythmDesired.value(run) } { Dictionary.new },
        now, ~spectrumConfig, ~spectrumRhythmEmit)
};
~spectrumMidiDesired = { |run|
    var desired = Dictionary.new, c = ~spectrumConfig;
    run[\streams].values.do { |st|
        var channel = (c[(st[\signal].asString ++ "MidiChannel").asSymbol] ? 1).asInteger.clip(1, 3) - 1;
        var targets = st[\targets] ? [];
        if(st[\ready] and: { st[\muted].not } and: { st[\rows].size == targets.size }) {
            st[\rows].do { |row, index|
                var amp = targets[index], note, key, entry;
                if(amp > 0) {
                    note = (~spectrumMidiCoordinate.value(row[0], c, st[\signal]) + 0.5).floor.asInteger.clip(0, 127);
                    key = channel.asString ++ "/" ++ note.asString;
                    entry = desired[key];
                    if(entry.isNil) {
                        desired[key] = (channel: channel, note: note, amplitude: amp, signals: Set[st[\signal]])
                    } {
                        entry[\amplitude] = entry[\amplitude] + amp; entry[\signals].add(st[\signal]);
                    };
                };
            };
        };
    };
    desired
};
~spectrumMidiUpdate = { |run|
    var c = ~spectrumConfig, desired, now = Main.elapsedTime, dt, alpha, floor, ceiling, deadband, velocity;
    if(c[\toneEnabled].not or: { c[\midiEnabled].not } or: { run[\midiConnected].not }) { ~spectrumMidiPanicRun.value(run) } {
        desired = ~spectrumMidiDesired.value(run);
        floor = c[\midiExpressionFloor]; ceiling = c[\midiExpressionCeiling];
        deadband = c[\midiExpressionDeadband].asInteger; velocity = c[\midiNoteOnVelocity].asInteger;
        dt = (now - (run[\midiLastUpdate] ? now)).max(0.001); run[\midiLastUpdate] = now;
        alpha = if(c[\midiExpressionSmoothing] <= 0) { 1 } { 1 - (dt.neg / c[\midiExpressionSmoothing]).exp };
        run[\midiActive].keys.asArray.do { |key|
            if(desired[key].isNil or: { desired[key][\amplitude] < floor }) {
                var old = run[\midiActive].removeAt(key);
                ~spectrumMidiEmit.value(run[\midiOut], \noteOff, old[\channel], old[\note], 0);
            };
        };
        desired.keysValuesDo { |key, wanted|
            var active = run[\midiActive][key], smooth, expression;
            if(wanted[\amplitude] >= floor) {
                smooth = if(active.isNil) { wanted[\amplitude] } {
                    active[\smoothed] + ((wanted[\amplitude] - active[\smoothed]) * alpha)
                };
                expression = (((smooth.clip(floor, ceiling) - floor) / (ceiling - floor)) * 126 + 1)
                    .round.asInteger.clip(1, 127);
                if(active.isNil) {
                    active = (channel: wanted[\channel], note: wanted[\note], smoothed: smooth, expression: expression,
                        signals: wanted[\signals]);
                    run[\midiActive][key] = active; run[\midiChannelsUsed].add(wanted[\channel]);
                    ~spectrumMidiEmit.value(run[\midiOut], \noteOn, wanted[\channel], wanted[\note], velocity);
                    ~spectrumMidiEmit.value(run[\midiOut], \polyTouch, wanted[\channel], wanted[\note], expression);
                } {
                    active[\smoothed] = smooth; active[\signals] = wanted[\signals];
                    if((expression - active[\expression]).abs >= deadband) {
                        active[\expression] = expression;
                        ~spectrumMidiEmit.value(run[\midiOut], \polyTouch, active[\channel], active[\note], expression);
                    };
                };
            };
        };
    };
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
    SendReply.kr(Impulse.kr(2), '/weatherSpectrum/level', [peak]);
    SendReply.kr(Impulse.kr(1) * (peak > 0.8), '/weatherSpectrum/limiting', [peak]);
    Out.ar(out, (Limiter.ar(input, 0.8, 0.01) * env) ! 2);
});
~spectrumTestDef = SynthDef(\weatherSpectrumTest, { |out=0|
    var env = EnvGen.kr(Env.perc(0.02, 0.8), doneAction: 2);
    Out.ar(out, SinOsc.ar(440) * env * 0.03);
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
    ~spectrumMidiUpdate.value(run);
    ~spectrumRhythmSync.value(run);
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
~spectrumAudioStatus = {
    var run = ~spectrumRun, now = Main.elapsedTime;
    if(run.isNil) { "Spectrum audio: stopped".postln } {
        var streams = run[\streams].values, ready = streams.count { |st| st[\ready] };
        var audible = streams.count { |st| (st[\targets] ? []).sum > 0 };
        var targetSum = streams.sum { |st| (st[\targets] ? []).sum };
        var meterAge = if(run[\outputSeen].isNil) { nil } { (now - run[\outputSeen]).round(0.1) };
        var meterHealthy = run[\outputSeen].notNil and: { (now - run[\outputSeen]) <= 2 };
        var routeHealthy = run[\routingState] == \ready and: { run[\activeOutputBus].notNil }
            and: { run[\bus].notNil } and: { run[\output].notNil } and: { meterHealthy };
        "Spectrum audio: healthy=% routing=% configuredBus=% activeBus=% channels=% internalBus=% outputNode=% banks=% ready=% audibleTargets=% targetSum=% master=% peak=% meterAge=%s"
            .format(routeHealthy, run[\routingState], ~spectrumConfig[\outputBus], run[\activeOutputBus],
                s.options.numOutputBusChannels, run[\bus].tryPerform(\index), run[\output].tryPerform(\nodeID),
                streams.count { |st| st[\synth].notNil }, ready, audible, targetSum.round(0.000001),
                ~spectrumConfig[\masterGain], (run[\outputPeak] ? 0).round(0.000001), meterAge).postln;
        streams.do { |st|
            "  % ready=% muted=% rows=% nonzero=% gain=% state=%"
                .format(st[\signal], st[\ready], st[\muted], st[\rows].size,
                    (st[\targets] ? []).count { |amp| amp > 0 },
                    ~spectrumConfig[(st[\signal].asString ++ "Gain").asSymbol], st[\reason]).postln;
        };
        if(routeHealthy.not) { "Spectrum audio routing is not initialized; stop, reboot if needed, and reload the sketch.".warn };
        if(ready == 0) { "No complete ready spectrum frames.".warn };
        if(ready > 0 and: { targetSum <= 0 }) { "Ready frames currently produce zero effective amplitudes; check mode, gains, backgrounds, and mutes.".warn };
        if(run[\outputSeen].isNil or: { (now - run[\outputSeen]) > 2 }) {
            "No recent output-synth meter reply; the output node may be stale or inactive.".warn;
        };
    };
};
~spectrumMidiStatus = {
    var run = ~spectrumRun, c = ~spectrumConfig;
    if(run.isNil) {
        "Spectrum MIDI: stopped enabled=% destination='% / %' channels=[%, %, %]"
            .format(c[\midiEnabled], c[\midiDevice], c[\midiPort], c[\temperatureMidiChannel],
                c[\humidityMidiChannel], c[\pressureMidiChannel]).postln;
    } {
        "Spectrum MIDI: enabled=% connected=% destination='% / %' channels=[temperature:% humidity:% pressure:%] activeNotes=% error=%"
            .format(c[\midiEnabled], run[\midiConnected], c[\midiDevice], c[\midiPort],
                c[\temperatureMidiChannel], c[\humidityMidiChannel], c[\pressureMidiChannel],
                run[\midiActive].size, run[\midiError]).postln;
        run[\midiActive].values.asArray.sort { |a, b|
            (a[\channel] < b[\channel]) or: { (a[\channel] == b[\channel]) and: { a[\note] < b[\note] } }
        }.do { |entry|
            "  channel=% note=% expression=% amplitude=% signals=%".format(entry[\channel] + 1, entry[\note],
                entry[\expression], entry[\smoothed].round(0.000001), entry[\signals].asArray).postln;
        };
    };
};
~spectrumRhythmStatus = {
    var run = ~spectrumRun, c = ~spectrumConfig;
    if(run.isNil) { "Spectrum rhythm: stopped enabled=% destination='% / %'".format(
        c[\rhythmEnabled], c[\rhythmMidiDevice], c[\rhythmMidiPort]).postln } {
        "Spectrum rhythm: enabled=% connected=% selection=% noteMapping=% sources=% gates=% error=%".format(
            c[\rhythmEnabled], run[\rhythmConnected], c[\rhythmSelection], c[\rhythmNoteMapping],
            run[\rhythmSources].size, run[\rhythmGates].size, run[\rhythmError]).postln;
        run[\rhythmSources].keys.asArray.sort.do { |key| var source = run[\rhythmSources][key];
            "  source=% envHz=% pulseHz=% bpm=% significance=% channel=% note=% phase=%".format(
                key, source[\sourceHz].round(0.000001), source[\rateHz].round(0.001),
                (source[\rateHz] * 60).round(0.1), source[\significance].round(0.001),
                source[\channel] + 1, source[\note], source[\phase].round(0.001)).postln;
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
// Injects a brief tone before the existing output synth, exercising its internal
// bus, master gain, limiter, envelope, and selected hardware output.
~spectrumTestTone = {
    var run = ~spectrumRun;
    if(s.serverRunning and: { run.notNil } and: { run[\routingState] == \ready }
        and: { run[\bus].notNil } and: { run[\output].notNil }) {
        Synth.before(run[\output], \weatherSpectrumTest, [\out, run[\bus]]);
        "Playing a quiet 440 Hz tone through the spectrum output stage for about one second.".postln;
    } { "Start a fully initialized spectrum before running ~spectrumTestTone.value.".warn };
};
~spectrumSetMode = { |mode| if([\physical, \significance].includes(mode)) { ~spectrumConfig[\mode] = mode } { "Unknown mode".warn } };
~spectrumSetMidiEnabled = { |enabled|
    if([true, false].includes(enabled)) {
        ~spectrumConfig[\toneEnabled] = enabled; ~spectrumConfig[\midiEnabled] = enabled;
        if(~spectrumRun.notNil) {
            if(enabled) { ~spectrumMidiConnect.value(~spectrumRun) } {
                ~spectrumMidiPanicRun.value(~spectrumRun);
                ~spectrumRun[\midiOut] = nil; ~spectrumRun[\midiConnected] = false; ~spectrumRun[\midiError] = "disabled";
            };
        };
    } { "MIDI enabled must be true or false.".warn };
};
~spectrumSetToneEnabled = ~spectrumSetMidiEnabled;
~spectrumSetRhythmEnabled = { |enabled|
    if([true,false].includes(enabled)) {
        ~spectrumConfig[\rhythmEnabled] = enabled;
        if(~spectrumRun.notNil) {
            if(enabled) { ~spectrumRhythmConnect.value(~spectrumRun); ~spectrumRhythmSync.value(~spectrumRun) } {
                ~weatherRhythmPanic.value(~spectrumRun, (0..2), ~spectrumRhythmEmit, true);
                ~spectrumRun[\rhythmOut] = nil; ~spectrumRun[\rhythmConnected] = false; ~spectrumRun[\rhythmError] = "disabled";
            };
        };
    } { "Spectrum rhythm enabled must be true or false.".warn };
};
~spectrumSetRhythmDestination = { |device, port|
    if(~spectrumText.value(device) and: { ~spectrumText.value(port) } and: { device.asString.notEmpty } and: { port.asString.notEmpty }) {
        ~spectrumConfig[\rhythmMidiDevice] = device.asString; ~spectrumConfig[\rhythmMidiPort] = port.asString;
        if(~spectrumRun.notNil) { ~spectrumRhythmConnect.value(~spectrumRun) };
    } { "Spectrum rhythm destination requires nonempty device and port names.".warn };
};
~spectrumSetRhythmRate = { |minimum=0.5, maximum=4.0|
    if(~spectrumFinite.value(minimum) and: { ~spectrumFinite.value(maximum) } and: { minimum > 0 } and: { maximum >= minimum }) {
        ~spectrumConfig[\rhythmPulseMinHz] = minimum; ~spectrumConfig[\rhythmPulseMaxHz] = maximum;
    } { "Spectrum rhythm rates require 0 < minimum <= maximum.".warn };
};
~spectrumSetRhythmPulse = { |duration=0.08, velocityMin=35, velocityMax=110|
    if(~spectrumFinite.value(duration) and: { duration > 0 } and: { duration <= 2 }
        and: { velocityMin.isInteger } and: { velocityMax.isInteger }
        and: { velocityMin >= 1 } and: { velocityMax >= velocityMin } and: { velocityMax <= 127 }) {
        ~spectrumConfig[\rhythmPulseDuration] = duration; ~spectrumConfig[\rhythmVelocityMin] = velocityMin;
        ~spectrumConfig[\rhythmVelocityMax] = velocityMax;
    } { "Invalid spectrum rhythm duration or velocity bounds.".warn };
};
~spectrumSetRhythmVelocity = { |inputFloor=0, inputCeiling=4, velocityMin=35, velocityMax=110|
    if(~spectrumFinite.value(inputFloor) and: { ~spectrumFinite.value(inputCeiling) }
        and: { inputFloor >= 0 } and: { inputCeiling > inputFloor }
        and: { velocityMin.isInteger } and: { velocityMax.isInteger }
        and: { velocityMin >= 1 } and: { velocityMax >= velocityMin } and: { velocityMax <= 127 }) {
        ~spectrumConfig[\rhythmVelocityInputFloor] = inputFloor; ~spectrumConfig[\rhythmVelocityInputCeiling] = inputCeiling;
        ~spectrumConfig[\rhythmVelocityMin] = velocityMin; ~spectrumConfig[\rhythmVelocityMax] = velocityMax;
    } { "Invalid spectrum rhythm velocity mapping.".warn };
};
~spectrumSetRhythmSelection = { |mode=\perBand, topN=3|
    if([\perBand, \topN].includes(mode) and: { topN.isInteger } and: { topN >= 1 } and: { topN <= 48 }) {
        ~spectrumConfig[\rhythmSelection] = mode; ~spectrumConfig[\rhythmTopN] = topN;
    } { "Spectrum rhythm selection requires perBand/topN and topN 1..48.".warn };
};
~spectrumSetRhythmBands = { |bands|
    if(bands.isArray and: { bands.size == 3 } and: { bands.every { |band|
        band.isArray and: { band.size == 2 } and: { band[0].isNumber } and: { band[1].isNumber }
        and: { band[0] >= 0.05 } and: { band[1] > band[0] } and: { band[1] <= 1.000001 }
    } }) { ~spectrumConfig[\rhythmBands] = bands.deepCopy }
    { "Spectrum rhythm bands require three [low, high] ranges within 0.05..1 Hz.".warn };
};
~spectrumSetRhythmNotes = { |bandNotes, temperature=36, humidity=38, pressure=42|
    var notes = (bandNotes ? []).asArray ++ [temperature, humidity, pressure];
    if(bandNotes.isArray and: { bandNotes.size == 3 }
        and: { notes.every { |note| note.isInteger and: { note >= 0 } and: { note <= 127 } } }) {
        ~spectrumConfig[\rhythmBandNotes] = bandNotes.copy;
        ~spectrumConfig[\rhythmSensorNotes] = (temperature:temperature, humidity:humidity, pressure:pressure);
    } { "Spectrum rhythm notes require three band notes and valid sensor MIDI notes.".warn };
};
~spectrumSetRhythmNoteMapping = { |mode=\perBand|
    if([\perBand, \perSensor].includes(mode)) { ~spectrumConfig[\rhythmNoteMapping] = mode }
    { "Spectrum rhythm note mapping must be perBand or perSensor.".warn };
};
~spectrumSetMidiDestination = { |device, port|
    if(~spectrumText.value(device) and: { ~spectrumText.value(port) }
        and: { device.asString.notEmpty } and: { port.asString.notEmpty }) {
        ~spectrumConfig[\midiDevice] = device.asString; ~spectrumConfig[\midiPort] = port.asString;
        if(~spectrumRun.notNil) { ~spectrumMidiConnect.value(~spectrumRun) };
    } { "MIDI destination requires nonempty device and port names.".warn };
};
~spectrumSetMidiChannel = { |signal, channel|
    if([\temperature, \humidity, \pressure].includes(signal) and: { channel.isInteger }
        and: { channel >= 1 } and: { channel <= 3 }) {
        ~spectrumConfig[(signal.asString ++ "MidiChannel").asSymbol] = channel;
    } { "Spectrum MIDI channel requires temperature/humidity/pressure and an owned channel from 1 to 3.".warn };
};
~spectrumSetMidiExpression = { |floor, ceiling, smoothing=0.5, deadband=2, velocity=64|
    if(~spectrumFinite.value(floor) and: { ~spectrumFinite.value(ceiling) } and: { floor >= 0 }
        and: { ceiling > floor } and: { ~spectrumFinite.value(smoothing) } and: { smoothing >= 0 }
        and: { deadband.isInteger } and: { deadband >= 0 } and: { deadband <= 127 }
        and: { velocity.isInteger } and: { velocity >= 1 } and: { velocity <= 127 }) {
        ~spectrumConfig[\midiExpressionFloor] = floor; ~spectrumConfig[\midiExpressionCeiling] = ceiling;
        ~spectrumConfig[\midiExpressionSmoothing] = smoothing; ~spectrumConfig[\midiExpressionDeadband] = deadband;
        ~spectrumConfig[\midiNoteOnVelocity] = velocity;
    } { "Invalid MIDI expression settings: require 0 <= floor < ceiling, smoothing >= 0, deadband 0..127, velocity 1..127.".warn };
};
~spectrumMidiPanic = { ~spectrumMidiPanicRun.value(~spectrumRun) };
~spectrumRhythmPanic = { ~weatherRhythmPanic.value(~spectrumRun, (0..2), ~spectrumRhythmEmit, false) };
~spectrumRhythmResync = {
    if(~spectrumRun.notNil and: { ~spectrumRun[\rhythmConnected] }) {
        ~weatherRhythmResync.value(~spectrumRun, Main.elapsedTime, ~spectrumConfig, ~spectrumRhythmEmit)
    } { "Spectrum rhythm resync requires a connected rhythm output.".warn };
};
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
            if(resolved.isNil) {
                run[\activeOutputBus] = nil; run[\routingState] = \invalid;
            } {
                if(run[\output].isNil) {
                    run[\activeOutputBus] = nil; run[\routingState] = \missingOutput;
                    "Spectrum output synth is missing; stop and restart the sketch.".warn;
                } {
                    run[\output].set(\out, resolved);
                    run[\activeOutputBus] = resolved; run[\routingState] = \ready;
                };
            };
        };
    } { "Invalid spectrum output bus (use a nonnegative integer).".warn };
};
~spectrumStop = { |immediate=false|
    var run = ~spectrumRun;
    if(run.notNil and: { run[\running] }) {
        var finish;
        run[\running] = false;
        ~spectrumMidiPanicRun.value(run); run[\midiConnected] = false; run[\midiOut] = nil;
        ~weatherRhythmPanic.value(run, (0..2), ~spectrumRhythmEmit, true);
        run[\rhythmConnected] = false; run[\rhythmOut] = nil;
        if(run[\subscribed]) { ~weatherLeaseRelease.value(\spectrum, run[\leaseKey]); run[\subscribed] = false };
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        [\startup, \tick, \rhythmTick].do { |key| if(run[key] !== thisThread) { run[key].tryPerform(\stop) } };
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
            lastRejectDiagnostic: -100, lastClamp: -100, lastDiagnostic: Main.elapsedTime,
            routingState: \initializing, activeOutputBus: nil, outputPeak: 0.0, outputSeen: nil,
            midiOut: nil, midiConnected: false, midiError: nil, midiActive: Dictionary.new,
            midiChannelsUsed: Set.new, midiLastUpdate: Main.elapsedTime,
            rhythmOut: nil, rhythmConnected: false, rhythmError: nil,
            rhythmSources: Dictionary.new, rhythmGates: Dictionary.new);
        ~spectrumRun = run;
        [\temperature, \humidity, \pressure].do { |signal|
            run[\streams]["/osc/indoor-sky/" ++ signal ++ "/cwt/spectrum"] = (signal: signal, ready: false,
                muted: false, reason: "waiting", rows: [], frame: 0, seen: Main.elapsedTime,
                pending: Dictionary.new, retired: List.new, waveform: nil, waveLevel: 1.0);
        };
        ~spectrumMidiConnect.value(run);
        ~spectrumRhythmConnect.value(run);
        run[\onStop] = { if(~spectrumRun === run) { ~spectrumStop.value(true) } };
        run[\onQuit] = { |server| if(server === s) { run[\onStop].value } };
        CmdPeriod.add(run[\onStop]); ServerQuit.add(run[\onQuit]);
        if(s.serverRunning.not) { s.options.numInputBusChannels = 0 };
        s.waitForBoot({
            if(run[\running]) {
                run[\startup] = Routine({
                    var resolved;
                    ~spectrumBankDef.send(s); ~spectrumOutputDef.send(s); ~spectrumTestDef.send(s); s.sync;
                    if(run[\running]) {
                        resolved = ~weatherResolveOutputBus.value(c[\outputBus], c[\fallbackOutputBus], "Full spectrum");
                        if(resolved.isNil) { "Cannot start spectrum without a valid stereo output.".warn; ~spectrumStop.value(true) } {
                        if(thisProcess.openUDPPort(run[\port])) {
                            run[\activeOutputBus] = resolved;
                            run[\bus] = Bus.audio(s, 1); run[\group] = Group.new(s);
                            run[\streams].values.do { |st| st[\synth] = Synth.tail(run[\group], \weatherSpectrumBank, [\out, run[\bus]]) };
                            run[\output] = Synth.tail(run[\group], \weatherSpectrumOutput,
                                [\bus, run[\bus], \out, resolved, \master, 0]);
                            run[\routingState] = \ready;
                            run[\receiver] = { |msg, time, sender, port|
                                if(msg[0] == '/weatherSpectrum/level' and: { sender == s.addr }
                                    and: { msg[1] == run[\output].nodeID }) {
                                    run[\outputPeak] = msg[3]; run[\outputSeen] = Main.elapsedTime;
                                };
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
                            run[\rhythmTick] = Routine({ loop {
                                ~weatherRhythmStep.value(run, Main.elapsedTime, c, ~spectrumRhythmEmit); 0.02.wait
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
