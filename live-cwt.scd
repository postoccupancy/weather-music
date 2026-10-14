/* Evaluate this whole block. Stop: ~cwtStop.value; Start again: ~cwtStart.value;
   Live controls: edit ~cwtConfig[...] below or in the IDE; see README.md. */
(
if(~cwtStop.notNil) { ~cwtStop.value };

~cwtConfig = (
    routerIP: "192.168.0.41", routerPort: 5005, localPort: 9000,
    maxPolyphony: 4, masterVolume: 0.8,
    pitchMode: \continuous, // \continuous, \midi (browser audio), \midiOutput (hysteresis)
    baseOctave: 3, pitchSpan: 3,
    deviceFilter: nil, signalFilter: nil, // e.g. "indoor-sky", "temperature"
    frequencySmoothing: 0.18, amplitudeSmoothing: 0.35,
    releaseSmoothing: 0.6, releaseSeconds: 2.5,
    trafficTimeout: 15, diagnosticsInterval: 5
);

// Port of mappedMidiValues / mappedAudioFrequency / hystereticNote.
// Selection and amplitude normalization intentionally live elsewhere.
~cwtMapPitch = { |hz, config, previousNote|
    var position = (hz.clip(0.05, 1) / 0.05).log2 / 20.log2;
    var continuous = ((config[\baseOctave] + 1) * 12) + (position * config[\pitchSpan] * 12);
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
    freqTau=0.18, ampTau=0.35, releaseTau=0.6, releaseTime=2.5|
    var log1000 = 6.9077552789821;
    var pitch = Lag.kr(freq, freqTau.max(0.001) * log1000);
    var level = Lag.kr(amp * gate, Select.kr(gate, [releaseTau, ampTau]).max(0.001) * log1000);
    var attack = EnvGen.kr(Env([0, 1], [ampTau.max(0.001) * log1000], [-6.9077552789821]));
    var volume = Lag.kr(master, 0.12 * log1000);
    FreeSelf.kr(TDelay.kr(1 - gate, releaseTime));
    Out.ar(out, (SinOsc.ar(pitch) * level * attack * volume) ! 2);
});

~cwtStop = {
    var run = ~cwtRun;
    if(run.notNil) {
        run[\running] = false;
        run[\router].sendMsg('/router/unsubscribe', run[\port]);
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        run[\heartbeat].tryPerform(\stop);
        run[\tick].tryPerform(\stop);
        run[\startup].tryPerform(\stop);
        CmdPeriod.remove(run[\onStop]);
        ServerQuit.remove(run[\onQuit]);
        if(run[\group].notNil and: { s.serverRunning }) { run[\group].freeAll; run[\group].free };
        run[\synths].clear;
        run[\voices].clear;
        run[\streams].clear;
        ~cwtRun = nil;
        "CWT stopped: unsubscribed, handlers/routines/synths released.".postln;
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
            var key = voice[\key], entry = run[\synths][key];
            var mapped = ~cwtMapPitch.value(voice[\frequency], config,
                if(entry.notNil and: { entry[\mode] == config[\pitchMode] }) { entry[\note] } { nil });
            var amp = (0.18 * voice[\confidence]).clip(0.015, 0.22) / counts[voice[\device]].pow(0.35);
            if(entry.isNil and: { run[\synths].size < config[\maxPolyphony] }) {
                entry = (synth: Synth(\weatherCwtSine, [\freq, mapped[\hz], \amp, amp,
                    \master, config[\masterVolume], \freqTau, config[\frequencySmoothing],
                    \ampTau, config[\amplitudeSmoothing], \releaseTau, config[\releaseSmoothing],
                    \releaseTime, config[\releaseSeconds]], run[\group]), stream: voice[\stream],
                    releasing: false, releaseTime: config[\releaseSeconds]);
                run[\synths][key] = entry;
            };
            if(entry.notNil and: { entry[\releasing].not }) {
                entry[\synth].set(\freq, mapped[\hz], \amp, amp, \master, config[\masterVolume],
                    \freqTau, config[\frequencySmoothing], \ampTau, config[\amplitudeSmoothing]);
                entry[\note] = mapped[\note]; entry[\mode] = config[\pitchMode]; entry[\hz] = mapped[\hz];
            };
        };
        if((now - run[\lastDiagnostic]) >= config[\diagnosticsInterval]) {
            run[\lastDiagnostic] = now;
            "CWT: % sounding (including release tails), % eligible".format(run[\synths].size, candidates.size).postln;
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
                ~cwtSynthDef.send(s); s.sync;
                if(run[\running]) {
                    if(thisProcess.openUDPPort(run[\port])) {
                        run[\group] = Group.new(s);
                        run[\receiver] = receive;
                        thisProcess.addOSCRecvFunc(receive);
                        run[\router].sendMsg('/router/subscribe', run[\port]);
                        run[\heartbeat] = Routine({ loop { 10.wait; run[\router].sendMsg('/router/heartbeat', run[\port]) } }).play(SystemClock);
                        run[\tick] = Routine({ loop { reconcile.value; 0.1.wait } }).play(SystemClock);
                        "CWT running: %:% -> local UDP %".format(config[\routerIP], config[\routerPort], run[\port]).postln;
                    } { "Cannot open CWT receive port".warn; stop.value };
                };
            }).play(SystemClock);
        };
    });
};
if(~cwtAutoStart ? true) { ~cwtStart.value };
)
