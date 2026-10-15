/* Evaluate this whole block. Stop: ~cwtStop.value; Start again: ~cwtStart.value;
   Live controls: edit ~cwtConfig[...] below or in the IDE; see README.md. */
(
if(~cwtStop.notNil) { ~cwtStop.value };

// One native router lease is shared by every Weather Music sketch in this sclang.
if(~weatherLeaseAcquire.isNil) {
    ~weatherLeaseState = Dictionary.new;
    ~weatherLeaseAcquire = { |owner, router, port|
        var key = router.ip ++ ":" ++ router.port ++ ":" ++ port, entry = ~weatherLeaseState[key];
        if(entry.isNil) {
            entry = (router: router, port: port, owners: Set.new, heartbeat: nil);
            ~weatherLeaseState[key] = entry;
        };
        entry[\owners].add(owner); entry[\router].sendMsg('/router/subscribe', port);
        if(entry[\heartbeat].isNil) {
            entry[\heartbeat] = Routine({ loop {
                10.wait; if(entry[\owners].notEmpty) { entry[\router].sendMsg('/router/heartbeat', port) };
            } }).play(SystemClock);
        };
        key
    };
    ~weatherLeaseRelease = { |owner, key|
        var entry = ~weatherLeaseState[key];
        if(entry.notNil) {
            entry[\owners].remove(owner);
            if(entry[\owners].isEmpty) {
                entry[\heartbeat].tryPerform(\stop);
                entry[\router].sendMsg('/router/unsubscribe', entry[\port]);
                ~weatherLeaseState.removeAt(key);
            };
        };
    };
};
~weatherResolveOutputBus = { |requested, fallback=0, label="Weather Music"|
    var channels = s.options.numOutputBusChannels;
    if(requested.isInteger and: { requested >= 0 } and: { (requested + 1) < channels }) { requested } {
        if(fallback.isInteger and: { fallback >= 0 } and: { (fallback + 1) < channels }) {
            "% output bus % needs hardware channels %–%; device has % outputs. Using explicit fallback bus %."
                .format(label, requested, requested + 1, requested + 2, channels, fallback).warn;
            fallback
        } { "% has no valid stereo output on this %‑channel device.".format(label, channels).warn; nil };
    }
};

~cwtConfig = (
    routerIP: "192.168.0.41", routerPort: 5005, localPort: 9000,
    maxPolyphony: 4, minConfidence: 0.0, masterVolume: 0.8,
    pitchMode: \continuous, // \continuous, \midi (browser audio), \midiOutput (hysteresis)
    baseNote: 48.0, pitchSpan: 36.0,
    baseNoteOverrides: Dictionary.new, pitchSpanOverrides: Dictionary.new,
    waveform: \sine,
    temperatureGain: 1.0, humidityGain: 1.0, pressureGain: 1.0,
    temperatureMuted: false, humidityMuted: false, pressureMuted: false,
    outputBus: 0, fallbackOutputBus: 0,
    deviceFilter: nil, signalFilter: nil, // e.g. "indoor-sky", "temperature"
    frequencySmoothing: 0.18, amplitudeSmoothing: 0.35,
    releaseSmoothing: 0.6, releaseSeconds: 2.5,
    trafficTimeout: 15, diagnosticsInterval: 5
);

// Port of mappedMidiValues / mappedAudioFrequency / hystereticNote.
// Selection and amplitude normalization intentionally live elsewhere.
~cwtMapPitch = { |hz, config, previousNote, signal|
    var position = (hz.clip(0.05, 1) / 0.05).log2 / 20.log2;
    var base = config[\baseNoteOverrides][signal] ? config[\baseNote];
    var span = config[\pitchSpanOverrides][signal] ? config[\pitchSpan];
    var continuous = base + (position * span);
    var note = (continuous + 0.5).floor;
    var mode = config[\pitchMode];
    if((mode == \midiOutput) and: { previousNote.notNil }) {
        if((continuous <= (previousNote + 0.6)) and: { continuous >= (previousNote - 0.6) }) {
            note = previousNote;
        };
    };
    (hz: (if(mode == \continuous) { continuous } { note }).midicps,
        continuousMidi: continuous, note: note)
};

~cwtWaveControls = { |waveform|
    switch(waveform,
        \sine, { (mix: 0.0, width: 0.5, level: 1.0) },
        \triangle, { (mix: 1.0, width: 0.5, level: 0.8) },
        \saw, { (mix: 1.0, width: 0.001, level: 0.55) },
        { nil })
};

// Confidence first; incumbents win ties; full identity breaks remaining ties.
~cwtSelect = { |candidates, synths, limit|
    candidates.sort { |a, b|
        var aHeld = synths[a[\key]].notNil and: { synths[a[\key]][\releasing].not };
        var bHeld = synths[b[\key]].notNil and: { synths[b[\key]][\releasing].not };
        if(a[\confidence] != b[\confidence]) { a[\confidence] > b[\confidence] } {
            if(aHeld != bHeld) { aHeld } { a[\key].compare(b[\key]) < 0 }
        }
    }.keep(limit)
};

~cwtSynthDef = SynthDef(\weatherCwtSine, {
    |out=0, freq=440, amp=0, master=0.8, gate=1,
    freqTau=0.18, ampTau=0.35, releaseTau=0.6, releaseTime=2.5,
    waveMix=0, waveWidth=0.5, waveLevel=1|
    var log1000 = 6.9077552789821;
    var pitch = Lag.kr(freq, freqTau.max(0.001) * log1000);
    var level = Lag.kr(amp * gate, Select.kr(gate, [releaseTau, ampTau]).max(0.001) * log1000);
    var sine = SinOsc.ar(pitch), shaped = VarSaw.ar(pitch, 0, Lag.kr(waveWidth, 0.08));
    var oscillator = XFade2.ar(sine, shaped, (Lag.kr(waveMix, 0.08) * 2) - 1) * Lag.kr(waveLevel, 0.08);
    var attack = EnvGen.kr(Env([0, 1], [ampTau.max(0.001) * log1000], [-6.9077552789821]));
    var volume = Lag.kr(master, 0.12 * log1000);
    FreeSelf.kr(TDelay.kr(1 - gate, releaseTime));
    Out.ar(out, (oscillator * level * attack * volume) ! 2);
});
~cwtOutputDef = SynthDef(\weatherCwtOutput, { |bus=0, out=0|
    Out.ar(out, Limiter.ar(In.ar(bus, 2), 0.8, 0.01));
});

~cwtSetMinConfidence = { |threshold|
    if(threshold.isNumber and: { threshold.isNaN.not } and: { threshold >= 0 } and: { threshold <= 1 }) {
        ~cwtConfig[\minConfidence] = threshold.asFloat;
    } { "Invalid CWT confidence threshold (allowed 0..1).".warn };
};
~cwtSetGain = { |signal, gain|
    if([\temperature, \humidity, \pressure].includes(signal)
        and: { gain.isNumber } and: { gain.isNaN.not } and: { gain >= 0 } and: { gain <= 4 }) {
        ~cwtConfig[(signal.asString ++ "Gain").asSymbol] = gain.asFloat;
    } { "Invalid CWT sensor/gain (signals temperature/humidity/pressure; gain 0..4).".warn };
};
~cwtMute = { |signal, mute=true|
    if([\temperature, \humidity, \pressure].includes(signal)) {
        ~cwtConfig[(signal.asString ++ "Muted").asSymbol] = mute == true;
    } { "Unknown CWT sensor bank.".warn };
};
~cwtSetBaseNote = { |note, signal|
    if(signal.notNil and: { [\temperature, \humidity, \pressure].includes(signal).not }) { "Unknown CWT pitch-override sensor.".warn } {
        if(note.isNil and: { signal.notNil }) { ~cwtConfig[\baseNoteOverrides].removeAt(signal) } {
            if(note.isNumber and: { note.isNaN.not } and: { note >= 24 } and: { note <= 72 }) {
                if(signal.isNil) { ~cwtConfig[\baseNote] = note.asFloat } { ~cwtConfig[\baseNoteOverrides][signal] = note.asFloat };
            } { "Invalid CWT base note (allowed MIDI 24..72; nil clears a sensor override).".warn };
        };
    };
};
~cwtSetPitchSpan = { |semitones, signal|
    if(signal.notNil and: { [\temperature, \humidity, \pressure].includes(signal).not }) { "Unknown CWT pitch-override sensor.".warn } {
        if(semitones.isNil and: { signal.notNil }) { ~cwtConfig[\pitchSpanOverrides].removeAt(signal) } {
            if(semitones.isNumber and: { semitones.isNaN.not } and: { semitones >= 12 } and: { semitones <= 72 }) {
                if(signal.isNil) { ~cwtConfig[\pitchSpan] = semitones.asFloat } { ~cwtConfig[\pitchSpanOverrides][signal] = semitones.asFloat };
            } { "Invalid CWT pitch span (allowed 12..72 semitones; nil clears a sensor override).".warn };
        };
    };
};
~cwtSetWaveform = { |waveform|
    if(~cwtWaveControls.value(waveform).notNil) { ~cwtConfig[\waveform] = waveform } {
        "Unknown CWT waveform (use sine, triangle, or saw).".warn
    };
};
~cwtSetOutputBus = { |bus|
    var run = ~cwtRun, resolved;
    if(bus.isInteger and: { bus >= 0 }) {
        ~cwtConfig[\outputBus] = bus;
        if(run.notNil and: { s.serverRunning }) {
            resolved = ~weatherResolveOutputBus.value(bus, ~cwtConfig[\fallbackOutputBus], "Tracked voices");
            if(resolved.notNil) {
                run[\activeOutputBus] = resolved;
                run[\output].set(\out, resolved);
            };
        };
    } { "Invalid CWT output bus (use a nonnegative integer).".warn };
};

~cwtStop = {
    var run = ~cwtRun;
    if(run.notNil) {
        run[\running] = false;
        ~weatherLeaseRelease.value(\cwt, run[\leaseKey]);
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        run[\tick].tryPerform(\stop);
        run[\startup].tryPerform(\stop);
        CmdPeriod.remove(run[\onStop]);
        ServerQuit.remove(run[\onQuit]);
        if(run[\group].notNil and: { s.serverRunning }) { run[\group].freeAll; run[\group].free };
        run[\audioBus].tryPerform(\free);
        run[\synths].clear;
        run[\voices].clear;
        run[\streams].clear;
        ~cwtRun = nil;
        "CWT stopped: lease ownership, handlers/routines/synths released.".postln;
    };
};

~cwtStart = {
    var config, run, clearStream, accept, reconcile, receive, stop;
    ~cwtStop.value;
    config = ~cwtConfig;
    stop = ~cwtStop;
    run = (running: true, router: NetAddr(config[\routerIP], config[\routerPort]),
        port: config[\localPort], voices: Dictionary.new, streams: Dictionary.new,
        synths: Dictionary.new, lastDiagnostic: 0);
    ~cwtRun = run;
    clearStream = { |stream|
        run[\voices].keys.asArray.do { |key|
            if(run[\voices][key][\stream] == stream) { run[\voices].removeAt(key) };
        };
        run[\streams].removeAt(stream);
        // Release even if this exact ID is reused in the next analysis epoch.
        run[\synths].values.do { |entry|
            if((entry[\stream] == stream) and: { entry[\releasing].not }) {
                entry[\synth].set(\gate, 0);
                entry[\releasing] = true;
                entry[\freeAt] = Main.elapsedTime + entry[\releaseTime] + 0.1;
            };
        };
    };
    accept = { |device, signal|
        (config[\deviceFilter].isNil or: { config[\deviceFilter] == device })
        and: { config[\signalFilter].isNil or: { config[\signalFilter] == signal } }
    };
    receive = { |msg, time, sender, port|
        var parts, stream, key, state, stamp, ids, count, now = Main.elapsedTime;
        if(run[\running] and: { port == run[\port] } and: { sender.ip == run[\router].ip }) {
            parts = msg[0].asString.split($/).reject { |part| part.isEmpty };
            if((parts.size >= 5) and: { parts[0] == "osc" } and: { parts[3] == "cwt" }) {
                stream = parts[1] ++ "/" ++ parts[2];
                if((parts.size == 6) and: { parts[4] == "voice" } and: { msg.size == 8 }
                    and: { msg.copyRange(1, 7).every { |v| v.isNumber and: { v.isNaN.not } and: { v.abs < inf } } }) {
                    key = stream ++ "/" ++ parts[5];
                    state = run[\streams][stream];
                    // Lower timestamps can be a reboot or reordering; retire the old epoch safely.
                    if(state.notNil and: { msg[6] < state[\timestamp] }) { clearStream.value(stream) };
                    if(msg[5] == 0) { run[\voices].removeAt(key) } {
                        if((msg[1] > 0) and: { accept.value(parts[1], parts[2]) }) {
                            run[\voices][key] = (key: key, stream: stream, device: parts[1], signal: parts[2],
                                id: parts[5], frequency: msg[1], strength: msg[2], phase: msg[3],
                                confidence: msg[4].clip(0, 1), timestamp: msg[6], lastMatched: msg[7], seen: now);
                        };
                    };
                };
                if((parts.size == 5) and: { parts[4] == "voices" } and: { msg.size >= 6 }
                    and: { msg[1].isNumber } and: { msg[5].isInteger } and: { msg[5] >= 0 }
                    and: { msg.size == (6 + msg[5]) }) {
                    stamp = msg[1]; count = msg[5]; state = run[\streams][stream];
                    if((msg[2] != 1) or: { state.notNil and: { stamp < state[\timestamp] } }) {
                        clearStream.value(stream);
                    };
                    ids = Set.new;
                    count.do { |i| ids.add(msg[i + 6].asString) };
                    run[\streams][stream] = (ready: msg[2] == 1, timestamp: stamp, seen: now, ids: ids);
                    run[\voices].keys.asArray.do { |voiceKey|
                        var voice = run[\voices][voiceKey];
                        if((voice[\stream] == stream) and: { (msg[2] != 1) or: { ids.includes(voice[\id]).not } }) {
                            run[\voices].removeAt(voiceKey);
                        };
                    };
                };
            };
        };
    };
    reconcile = {
        var now = Main.elapsedTime, candidates, selected, selectedKeys, counts = Dictionary.new;
        var threshold = config[\minConfidence], releasing;
        if(threshold.isNumber.not or: { threshold.isNaN } or: { threshold < 0 } or: { threshold > 1 }) { threshold = 0 };
        run[\streams].keys.asArray.do { |stream|
            if((now - run[\streams][stream][\seen]) > config[\trafficTimeout]) { clearStream.value(stream) };
        };
        run[\voices].keys.asArray.do { |key|
            if((now - run[\voices][key][\seen]) > config[\trafficTimeout]) { run[\voices].removeAt(key) };
        };
        candidates = run[\voices].values.asArray.select { |voice|
            var state = run[\streams][voice[\stream]];
            state.notNil and: { state[\ready] } and: { state[\ids].includes(voice[\id]) }
            and: { accept.value(voice[\device], voice[\signal]) }
            and: { voice[\confidence] >= threshold }
        };
        // Exactly the browser's per-device normalization, before the polyphony cap.
        candidates.do { |voice| counts[voice[\device]] = (counts[voice[\device]] ? 0) + 1 };
        selected = ~cwtSelect.value(candidates, run[\synths], config[\maxPolyphony].asInteger.max(0));
        selectedKeys = selected.collect { |voice| voice[\key] };
        run[\synths].keys.asArray.do { |key|
            var entry = run[\synths][key];
            if(entry[\releasing]) {
                if(now >= entry[\freeAt]) { run[\synths].removeAt(key) };
            } {
                if(selectedKeys.includesEqual(key).not) {
                    entry[\synth].set(\gate, 0);
                    entry[\releasing] = true;
                    entry[\freeAt] = now + entry[\releaseTime] + 0.1;
                };
            };
        };
        selected.do { |voice|
            var key = voice[\key], entry = run[\synths][key], signal = voice[\signal].asSymbol;
            var mapped = ~cwtMapPitch.value(voice[\frequency], config,
                if(entry.notNil and: { entry[\mode] == config[\pitchMode] }) { entry[\note] } { nil }, signal);
            var sensorGain = (config[(signal.asString ++ "Gain").asSymbol] ? 1).clip(0, 4);
            var muted = config[(signal.asString ++ "Muted").asSymbol] ? false;
            var amp = ((0.18 * voice[\confidence]).clip(0.015, 0.22) / counts[voice[\device]].pow(0.35))
                * sensorGain * muted.not.asInteger;
            var wave = ~cwtWaveControls.value(config[\waveform]) ? ~cwtWaveControls.value(\sine);
            if(entry.isNil and: { run[\synths].size < config[\maxPolyphony] }) {
                entry = (synth: Synth(\weatherCwtSine, [\out, run[\audioBus], \freq, mapped[\hz], \amp, amp,
                    \master, config[\masterVolume], \freqTau, config[\frequencySmoothing],
                    \ampTau, config[\amplitudeSmoothing], \releaseTau, config[\releaseSmoothing],
                    \releaseTime, config[\releaseSeconds], \waveMix, wave[\mix], \waveWidth, wave[\width],
                    \waveLevel, wave[\level]], run[\group]), stream: voice[\stream],
                    releasing: false, releaseTime: config[\releaseSeconds]);
                run[\synths][key] = entry;
            };
            if(entry.notNil and: { entry[\releasing].not }) {
                entry[\synth].set(\freq, mapped[\hz], \amp, amp, \master, config[\masterVolume],
                    \freqTau, config[\frequencySmoothing], \ampTau, config[\amplitudeSmoothing],
                    \waveMix, wave[\mix], \waveWidth, wave[\width], \waveLevel, wave[\level]);
                entry[\note] = mapped[\note]; entry[\mode] = config[\pitchMode]; entry[\hz] = mapped[\hz];
                entry[\amp] = amp; entry[\waveform] = config[\waveform]; entry[\muted] = muted;
            };
        };
        releasing = run[\synths].values.count { |entry| entry[\releasing] };
        run[\eligibleCount] = candidates.size; run[\selectedCount] = selected.size;
        run[\releasingCount] = releasing;
        if((now - run[\lastDiagnostic]) >= config[\diagnosticsInterval]) {
            run[\lastDiagnostic] = now;
            "CWT: eligible=% selected=% releasing=% allocated=% minConfidence=% outputBus=% waveform=%".format(
                candidates.size, selected.size, releasing, run[\synths].size, threshold,
                run[\activeOutputBus], config[\waveform]).postln;
            run[\synths].keys.asArray.sort.do { |key|
                var entry = run[\synths][key], voice = run[\voices][key];
                if(voice.notNil) {
                    "% env=% Hz audio=% Hz MIDI=% confidence=% active=%".format(key,
                        voice[\frequency].round(0.000001), entry[\hz].round(0.01),
                        if(config[\pitchMode] == \continuous) { "continuous" } { entry[\note] },
                        voice[\confidence].round(0.01), entry[\releasing].not.asInteger).postln;
                } { (key ++ " active=0 (releasing)").postln };
            };
        };
    };
    run[\receive] = receive; // Also permits deterministic native SC fixture tests.
    run[\reconcile] = reconcile;
    run[\onStop] = { if(~cwtRun === run) { stop.value } };
    run[\onQuit] = { |server| if(server === s) { run[\onStop].value } };
    CmdPeriod.add(run[\onStop]); ServerQuit.add(run[\onQuit]);
    // This oscillator-only sketch needs no microphone or input device.
    if(s.serverRunning.not) { s.options.numInputBusChannels = 0 };
    s.waitForBoot({
        if(run[\running]) {
            run[\startup] = Routine({
                var resolved;
                ~cwtSynthDef.send(s); ~cwtOutputDef.send(s); s.sync;
                if(run[\running]) {
                    resolved = ~weatherResolveOutputBus.value(config[\outputBus], config[\fallbackOutputBus], "Tracked voices");
                    if(resolved.isNil) { "Cannot start CWT without a valid stereo output.".warn; stop.value } {
                    if(thisProcess.openUDPPort(run[\port])) {
                        run[\activeOutputBus] = resolved;
                        run[\audioBus] = Bus.audio(s, 2);
                        run[\group] = Group.new(s);
                        run[\output] = Synth.tail(run[\group], \weatherCwtOutput,
                            [\bus, run[\audioBus], \out, resolved]);
                        run[\receiver] = receive;
                        thisProcess.addOSCRecvFunc(receive);
                        run[\leaseKey] = ~weatherLeaseAcquire.value(\cwt, run[\router], run[\port]);
                        run[\tick] = Routine({ loop { reconcile.value; 0.1.wait } }).play(SystemClock);
                        "CWT running: %:% -> UDP %, hardware outputs %–%".format(
                            config[\routerIP], config[\routerPort], run[\port], resolved + 1, resolved + 2).postln;
                    } { "Cannot open CWT receive port".warn; stop.value };
                    };
                };
            }).play(SystemClock);
        };
    });
};
~cwtStatus = {
    var run = ~cwtRun;
    if(run.isNil) { "CWT stopped".postln } {
        "CWT running=% eligible=% selected=% releasing=% allocated=% minConfidence=% outputBus=% waveform=% master=%"
            .format(run[\running], run[\eligibleCount] ? 0, run[\selectedCount] ? 0,
                run[\releasingCount] ? 0, run[\synths].size, ~cwtConfig[\minConfidence],
                run[\activeOutputBus], ~cwtConfig[\waveform], ~cwtConfig[\masterVolume]).postln;
    };
};
if(~cwtAutoStart ? true) { ~cwtStart.value };
)
