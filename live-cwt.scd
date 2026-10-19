/* Evaluate this whole block. Stop: ~cwtStop.value; Start again: ~cwtStart.value;
   Live controls: edit ~cwtConfig[...] below or in the IDE; see README.md. */
(
if(~cwtStop.notNil) { ~cwtStop.value };
(thisProcess.nowExecutingPath.dirname +/+ "midi-rhythm.scd").load;

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
    pitchMode: \continuous, // \continuous or \quantized; legacy \midi / \midiOutput accepted
    pitchHysteresis: 0.1,
    baseNote: 48.0, pitchSpan: 36.0,
    baseNoteOverrides: Dictionary.new, pitchSpanOverrides: Dictionary.new,
    waveform: \sine,
    temperatureGain: 1.0, humidityGain: 1.0, pressureGain: 1.0,
    temperatureMuted: false, humidityMuted: false, pressureMuted: false,
    outputBus: 0, fallbackOutputBus: 0,
    deviceFilter: nil, signalFilter: nil, // e.g. "indoor-sky", "temperature"
    frequencySmoothing: 0.18, amplitudeSmoothing: 0.35,
    releaseSmoothing: 0.6, releaseSeconds: 2.5,
    toneEnabled: true, midiEnabled: true, midiDevice: "IAC Driver", midiPort: "Bus 3 - Ableton Live",
    midiBendRange: 2.0, midiExpressionFloor: 0.005, midiExpressionCeiling: 0.18,
    midiExpressionSmoothing: 0.2, midiExpressionDeadband: 1, midiNoteOnVelocity: 64,
    rhythmEnabled: true, rhythmMidiDevice: "IAC Driver", rhythmMidiPort: "Bus 4 - Ableton Rhythm",
    rhythmSourceMinHz: 0.05, rhythmSourceMaxHz: 1.0, rhythmPulseMinHz: 0.5, rhythmPulseMaxHz: 4.0,
    rhythmPulseDuration: 0.08, rhythmVelocityInputFloor: 0.0, rhythmVelocityInputCeiling: 1.0,
    rhythmVelocityMin: 35, rhythmVelocityMax: 110, rhythmMaxEventsPerTick: 16,
    rhythmExpression: \velocity, rhythmConstantVelocity: 80,
    rhythmPhaseMaxCycles: 0.25, rhythmPhaseSmoothing: 2.0,
    rhythmEuclideanSteps: 8, rhythmEuclideanMinHits: 1, rhythmEuclideanMaxHits: 8,
    rhythmEuclideanDensityHysteresis: 0.08,
    toneSelectionMargin: 0.0, toneSelectionResidence: 0.0,
    rhythmSelectionMargin: 0.0, rhythmSelectionResidence: 0.0,
    rhythmNotes: [36, 38, 42, 45],
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
    var mode = config[\pitchMode], hysteresis = (config[\pitchHysteresis] ? 0.1).clip(0, 2);
    if(([\quantized, \midiOutput].includes(mode)) and: { previousNote.notNil }) {
        if((continuous <= (previousNote + 0.5 + hysteresis))
            and: { continuous >= (previousNote - 0.5 - hysteresis) }) {
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

// Kept behind two functions so tests can use a recorder without a MIDI device.
~cwtMidiOpen = { |device, port|
    var out;
    MIDIClient.init; out = MIDIOut.newByName(device.asString, port.asString); out.latency = 0; out
};
~cwtMidiEmit = { |out, type, channel, note=0, value=0|
    switch(type,
        \noteOn, { out.noteOn(channel, note, value) }, \noteOff, { out.noteOff(channel, note, value) },
        \bend, { out.bend(channel, value) }, \touch, { out.touch(channel, value) },
        \allNotesOff, { out.allNotesOff(channel) });
};
~cwtMidiRelease = { |run, key|
    var entry = run[\midiVoices][key];
    if(entry.notNil) {
        if(run[\midiOut].notNil and: { entry[\channel] >= 3 } and: { entry[\channel] <= 15 }) {
            ~cwtMidiEmit.value(run[\midiOut], \noteOff, entry[\channel], entry[\note], 0);
            ~cwtMidiEmit.value(run[\midiOut], \touch, entry[\channel], 0, 0);
            ~cwtMidiEmit.value(run[\midiOut], \bend, entry[\channel], 0, 8192);
        };
        run[\midiVoices].removeAt(key);
    };
};
~cwtMidiPanicRun = { |run|
    if(run.notNil) {
        run[\midiVoices].keys.asArray.do { |key| ~cwtMidiRelease.value(run, key) };
        if(run[\midiOut].notNil) {
            // Channels 4-16 (SuperCollider 3-15) belong exclusively to tracked voices.
            (3..15).do { |channel| ~cwtMidiEmit.value(run[\midiOut], \allNotesOff, channel) };
        };
    };
};
~cwtMidiConnect = { |run|
    var c = ~cwtConfig, error, destinations;
    ~cwtMidiPanicRun.value(run); run[\midiOut] = nil; run[\midiConnected] = false;
    if(c[\toneEnabled] and: { c[\midiEnabled] }) {
        try { run[\midiOut] = ~cwtMidiOpen.value(c[\midiDevice], c[\midiPort]) } { |caught| error = caught };
        if(run[\midiOut].notNil) {
            run[\midiConnected] = true; run[\midiError] = nil;
            "Tracked MIDI connected: % / %.".format(c[\midiDevice], c[\midiPort]).postln;
        } {
            try { MIDIClient.init; destinations = MIDIClient.destinations.collect { |ep| ep.device.asString ++ " / " ++ ep.name.asString } }
                { |caught| if(error.isNil) { error = caught } };
            run[\midiError] = if(error.notNil) { error.asString } { "destination not found" };
            "Tracked MIDI unavailable: configured destination '% / %' could not be opened (%). Available destinations: %."
                .format(c[\midiDevice], c[\midiPort], run[\midiError], destinations ? []).warn;
        };
    } { run[\midiError] = "disabled" };
};
~cwtRhythmOpen = { |device, port| ~cwtMidiOpen.value(device, port) };
~cwtRhythmEmit = { |out, type, channel, note=0, value=0| ~cwtMidiEmit.value(out, type, channel, note, value) };
~cwtRhythmConnect = { |run|
    var c = ~cwtConfig, error, destinations;
    ~weatherRhythmPanic.value(run, (3..15), ~cwtRhythmEmit, false);
    run[\rhythmOut] = nil; run[\rhythmConnected] = false;
    if(c[\rhythmEnabled]) {
        try { run[\rhythmOut] = ~cwtRhythmOpen.value(c[\rhythmMidiDevice], c[\rhythmMidiPort]) } { |caught| error = caught };
        if(run[\rhythmOut].notNil) {
            run[\rhythmConnected] = true; run[\rhythmError] = nil;
            "Tracked rhythm connected: % / %.".format(c[\rhythmMidiDevice], c[\rhythmMidiPort]).postln;
        } {
            try { MIDIClient.init; destinations = MIDIClient.destinations.collect { |ep| ep.device.asString ++ " / " ++ ep.name.asString } } { };
            run[\rhythmError] = if(error.notNil) { error.asString } { "destination not found" };
            "Tracked rhythm unavailable: configured destination '% / %' could not be opened (%). Available destinations: %."
                .format(c[\rhythmMidiDevice], c[\rhythmMidiPort], run[\rhythmError], destinations ? []).warn;
        };
    } { run[\rhythmError] = "disabled" };
};
~cwtMidiUpdateVoice = { |run, voice, mapped, amplitude, now|
    var c = ~cwtConfig, entry = run[\midiVoices][voice[\key]], channel, used, note, delta, bend;
    var dt, alpha, smoothed, expression, range = (c[\midiBendRange] ? 2).max(0.01);
    if(c[\toneEnabled] and: { c[\midiEnabled] } and: { run[\midiConnected] } and: { amplitude > 0 }) {
        if(entry.isNil) {
            used = run[\midiVoices].values.collect { |item| item[\channel] };
            channel = (3..15).detect { |candidate| used.includes(candidate).not };
            if(channel.notNil) {
                note = mapped[\continuousMidi].round.asInteger.clip(0, 127);
                entry = (channel: channel, note: note, smoothed: amplitude, expression: -1, updated: now,
                    frequency: voice[\frequency], continuousMidi: mapped[\continuousMidi]);
                run[\midiVoices][voice[\key]] = entry;
                delta = (mapped[\continuousMidi] - note).clip(range.neg, range);
                bend = (8192 + (delta / range * 8192)).round.asInteger.clip(0, 16383);
                entry[\bend] = bend;
                ~cwtMidiEmit.value(run[\midiOut], \bend, channel, 0, bend);
                ~cwtMidiEmit.value(run[\midiOut], \noteOn, channel, note, c[\midiNoteOnVelocity]);
            };
        };
        if(entry.notNil) {
            if((mapped[\continuousMidi] - entry[\note]).abs > range) {
                ~cwtMidiEmit.value(run[\midiOut], \noteOff, entry[\channel], entry[\note], 0);
                entry[\note] = mapped[\continuousMidi].round.asInteger.clip(0, 127);
                delta = (mapped[\continuousMidi] - entry[\note]).clip(range.neg, range);
                bend = (8192 + (delta / range * 8192)).round.asInteger.clip(0, 16383);
                ~cwtMidiEmit.value(run[\midiOut], \bend, entry[\channel], 0, bend);
                entry[\bend] = bend;
                ~cwtMidiEmit.value(run[\midiOut], \noteOn, entry[\channel], entry[\note], c[\midiNoteOnVelocity]);
            };
            delta = (mapped[\continuousMidi] - entry[\note]).clip(range.neg, range);
            bend = (8192 + (delta / range * 8192)).round.asInteger.clip(0, 16383);
            if(bend != entry[\bend]) { ~cwtMidiEmit.value(run[\midiOut], \bend, entry[\channel], 0, bend); entry[\bend] = bend };
            dt = (now - entry[\updated]).max(0); alpha = if(c[\midiExpressionSmoothing] <= 0) { 1 } { 1 - (dt.neg / c[\midiExpressionSmoothing]).exp };
            smoothed = entry[\smoothed] + ((amplitude - entry[\smoothed]) * alpha);
            expression = smoothed.linlin(c[\midiExpressionFloor], c[\midiExpressionCeiling], 1, 127).round.asInteger.clip(1, 127);
            if((expression - entry[\expression]).abs > c[\midiExpressionDeadband]) {
                ~cwtMidiEmit.value(run[\midiOut], \touch, entry[\channel], 0, expression); entry[\expression] = expression;
            };
            entry[\smoothed] = smoothed; entry[\updated] = now; entry[\frequency] = voice[\frequency]; entry[\continuousMidi] = mapped[\continuousMidi];
        };
    } { if(entry.notNil) { ~cwtMidiRelease.value(run, voice[\key]) } };
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
~cwtSelectHysteretic = { |candidates, state, limit, now, margin=0, residence=0|
    ~weatherSelectHysteretic.value(candidates, state, limit, \confidence, now, margin, residence)
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
~cwtSetMidiEnabled = { |enabled|
    if([true, false].includes(enabled)) {
        ~cwtConfig[\toneEnabled] = enabled; ~cwtConfig[\midiEnabled] = enabled;
        if(~cwtRun.notNil) {
            if(enabled) { ~cwtMidiConnect.value(~cwtRun) } {
                ~cwtMidiPanicRun.value(~cwtRun); ~cwtRun[\midiOut] = nil;
                ~cwtRun[\midiConnected] = false; ~cwtRun[\midiError] = "disabled";
            };
        };
    } { "Tracked MIDI enabled must be true or false.".warn };
};
~cwtSetToneEnabled = ~cwtSetMidiEnabled;
~cwtSetRhythmEnabled = { |enabled|
    if([true, false].includes(enabled)) {
        ~cwtConfig[\rhythmEnabled] = enabled;
        if(~cwtRun.notNil) {
            if(enabled) { ~cwtRhythmConnect.value(~cwtRun) } {
                ~weatherRhythmPanic.value(~cwtRun, (3..15), ~cwtRhythmEmit, true);
                ~cwtRun[\rhythmOut] = nil; ~cwtRun[\rhythmConnected] = false; ~cwtRun[\rhythmError] = "disabled";
            };
        };
    } { "Tracked rhythm enabled must be true or false.".warn };
};
~cwtSetRhythmDestination = { |device, port|
    if(device.notNil and: { port.notNil } and: { device.asString.notEmpty } and: { port.asString.notEmpty }) {
        ~cwtConfig[\rhythmMidiDevice] = device.asString; ~cwtConfig[\rhythmMidiPort] = port.asString;
        if(~cwtRun.notNil) { ~cwtRhythmConnect.value(~cwtRun) };
    } { "Tracked rhythm destination requires nonempty device and port names.".warn };
};
~cwtSetRhythmRate = { |minimum=0.5, maximum=4.0|
    if(minimum.isNumber and: { maximum.isNumber } and: { minimum > 0 } and: { maximum >= minimum }) {
        ~cwtConfig[\rhythmPulseMinHz] = minimum; ~cwtConfig[\rhythmPulseMaxHz] = maximum;
    } { "Tracked rhythm rates require 0 < minimum <= maximum.".warn };
};
~cwtSetRhythmPulseDuration = { |duration=0.08|
    if(duration.isNumber and: { duration > 0 } and: { duration <= 2 }) {
        ~cwtConfig[\rhythmPulseDuration] = duration;
    } { "Invalid tracked rhythm duration (allowed > 0 and <= 2 seconds).".warn };
};
~cwtSetRhythmVelocity = { |inputFloor=0, inputCeiling=1, velocityMin=35, velocityMax=110|
    if(inputFloor.isNumber and: { inputCeiling.isNumber } and: { inputFloor >= 0 } and: { inputCeiling > inputFloor }
        and: { velocityMin.isInteger } and: { velocityMax.isInteger }
        and: { velocityMin >= 1 } and: { velocityMax >= velocityMin } and: { velocityMax <= 127 }) {
        ~cwtConfig[\rhythmVelocityInputFloor] = inputFloor; ~cwtConfig[\rhythmVelocityInputCeiling] = inputCeiling;
        ~cwtConfig[\rhythmVelocityMin] = velocityMin; ~cwtConfig[\rhythmVelocityMax] = velocityMax;
    } { "Invalid tracked rhythm velocity mapping.".warn };
};
~cwtSetRhythmExpression = { |mode=\velocity|
    if([\off, \velocity, \phase, \euclidean].includes(mode)) { ~cwtConfig[\rhythmExpression] = mode }
    { "Tracked rhythm expression must be off, velocity, phase, or euclidean.".warn };
};
~cwtSetRhythmConstantVelocity = { |velocity=80|
    if(velocity.isInteger and: { velocity >= 1 } and: { velocity <= 127 }) { ~cwtConfig[\rhythmConstantVelocity] = velocity }
    { "Tracked constant rhythm velocity must be an integer from 1 to 127.".warn };
};
~cwtSetRhythmPhase = { |maximum=0.25, smoothing=2.0|
    if(maximum.isNumber and: { maximum >= 0 } and: { maximum < 0.5 }
        and: { smoothing.isNumber } and: { smoothing >= 0 }) {
        ~cwtConfig[\rhythmPhaseMaxCycles] = maximum; ~cwtConfig[\rhythmPhaseSmoothing] = smoothing;
    } { "Tracked phase expression requires displacement 0..<0.5 cycles and nonnegative smoothing seconds.".warn };
};
~cwtSetRhythmEuclidean = { |steps=8, minimum=1, maximum=8, hysteresis=0.08|
    if(steps.isInteger and: { minimum.isInteger } and: { maximum.isInteger }
        and: { steps >= 1 } and: { steps <= 64 } and: { minimum >= 0 }
        and: { maximum >= minimum } and: { maximum <= steps }
        and: { hysteresis.isNumber } and: { hysteresis >= 0 } and: { hysteresis < 0.5 }) {
        ~cwtConfig[\rhythmEuclideanSteps] = steps; ~cwtConfig[\rhythmEuclideanMinHits] = minimum;
        ~cwtConfig[\rhythmEuclideanMaxHits] = maximum; ~cwtConfig[\rhythmEuclideanDensityHysteresis] = hysteresis;
    } { "Tracked Euclidean settings require 1..64 steps and 0 <= minimum <= maximum <= steps.".warn };
};
~cwtSetSelectionHysteresis = { |margin=0.20, residence=30.0|
    if(margin.isNumber and: { margin >= 0 } and: { residence.isNumber } and: { residence >= 0 }) {
        ~cwtConfig[\toneSelectionMargin] = margin; ~cwtConfig[\toneSelectionResidence] = residence;
    } { "Tracked tone selection hysteresis requires nonnegative margin and residence seconds.".warn };
};
~cwtSetRhythmSelectionHysteresis = { |margin=0.20, residence=30.0|
    if(margin.isNumber and: { margin >= 0 } and: { residence.isNumber } and: { residence >= 0 }) {
        ~cwtConfig[\rhythmSelectionMargin] = margin; ~cwtConfig[\rhythmSelectionResidence] = residence;
    } { "Tracked rhythm selection hysteresis requires nonnegative margin and residence seconds.".warn };
};
~cwtSetRhythmNotes = { |notes|
    if(notes.isArray and: { notes.notEmpty } and: { notes.every { |note| note.isInteger and: { note >= 0 } and: { note <= 127 } } }) {
        ~cwtConfig[\rhythmNotes] = notes.copy;
    } { "Tracked rhythm notes require a nonempty MIDI-note array.".warn };
};
~cwtSetMidiDestination = { |device, port|
    if(device.notNil and: { port.notNil } and: { device.asString.notEmpty } and: { port.asString.notEmpty }) {
        ~cwtConfig[\midiDevice] = device.asString; ~cwtConfig[\midiPort] = port.asString;
        if(~cwtRun.notNil) { ~cwtMidiConnect.value(~cwtRun) };
    } { "Tracked MIDI destination requires nonempty device and port names.".warn };
};
~cwtSetMidiBendRange = { |semitones|
    if(semitones.isNumber and: { semitones.isNaN.not } and: { semitones >= 0.25 } and: { semitones <= 24 }) {
        ~cwtMidiPanicRun.value(~cwtRun); ~cwtConfig[\midiBendRange] = semitones.asFloat;
    } { "Invalid tracked MIDI bend range (allowed 0.25..24 semitones).".warn };
};
~cwtSetMidiExpression = { |floor, ceiling, smoothing=0.2, deadband=1, velocity=64|
    if(floor.isNumber and: { ceiling.isNumber } and: { smoothing.isNumber }
        and: { [floor, ceiling, smoothing].every { |v| v.isNaN.not } }
        and: { floor >= 0 } and: { ceiling > floor } and: { smoothing >= 0 }
        and: { deadband.isInteger } and: { deadband >= 0 } and: { deadband <= 127 }
        and: { velocity.isInteger } and: { velocity >= 1 } and: { velocity <= 127 }) {
        ~cwtConfig[\midiExpressionFloor] = floor; ~cwtConfig[\midiExpressionCeiling] = ceiling;
        ~cwtConfig[\midiExpressionSmoothing] = smoothing; ~cwtConfig[\midiExpressionDeadband] = deadband;
        ~cwtConfig[\midiNoteOnVelocity] = velocity;
    } { "Invalid tracked MIDI expression settings.".warn };
};
~cwtMidiPanic = { ~cwtMidiPanicRun.value(~cwtRun) };
~cwtMidiResync = {
    var run = ~cwtRun;
    if(run.notNil and: { run[\running] } and: { run[\reconcile].notNil }
        and: { run[\midiConnected] } and: { ~cwtConfig[\midiEnabled] }) {
        ~cwtMidiPanicRun.value(run);
        // Reconciliation reconstructs notes from the current tracker selection
        // without replacing OSC handlers, tracker state, or audio Synths.
        run[\reconcile].value;
        "Tracked MIDI resynced on channels 4-16.".postln;
    } { "Tracked MIDI resync requires a running, connected, enabled MIDI output.".warn };
};
~cwtRhythmPanic = { ~weatherRhythmPanic.value(~cwtRun, (3..15), ~cwtRhythmEmit, false) };
~cwtRhythmResync = {
    if(~cwtRun.notNil and: { ~cwtRun[\rhythmConnected] }) {
        ~weatherRhythmResync.value(~cwtRun, Main.elapsedTime, ~cwtConfig, ~cwtRhythmEmit)
    } { "Tracked rhythm resync requires a connected rhythm output.".warn };
};

~cwtStop = {
    var run = ~cwtRun;
    if(run.notNil) {
        run[\running] = false;
        ~cwtMidiPanicRun.value(run);
        ~weatherRhythmPanic.value(run, (3..15), ~cwtRhythmEmit, true);
        ~weatherLeaseRelease.value(\cwt, run[\leaseKey]);
        if(run[\receiver].notNil) { thisProcess.removeOSCRecvFunc(run[\receiver]) };
        run[\tick].tryPerform(\stop);
        run[\rhythmTick].tryPerform(\stop);
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
        synths: Dictionary.new, midiVoices: Dictionary.new, midiOut: nil,
        midiConnected: false, midiError: nil, rhythmOut: nil, rhythmConnected: false,
        rhythmError: nil, rhythmSources: Dictionary.new, rhythmGates: Dictionary.new, rhythmCursor: 0,
        toneSelectionState: Dictionary.new, rhythmSelectionState: Dictionary.new, lastDiagnostic: 0);
    ~cwtRun = run;
    ~cwtMidiConnect.value(run);
    ~cwtRhythmConnect.value(run);
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
        var now = Main.elapsedTime, candidates, selected, rhythmSelected, selectedKeys, counts = Dictionary.new;
        var rhythmDesired = Dictionary.new, rhythmUsed = Set.new;
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
        selected = ~cwtSelectHysteretic.value(candidates, run[\toneSelectionState],
            config[\maxPolyphony].asInteger.max(0), now,
            config[\toneSelectionMargin], config[\toneSelectionResidence]);
        rhythmSelected = ~cwtSelectHysteretic.value(candidates, run[\rhythmSelectionState],
            config[\maxPolyphony].asInteger.max(0), now,
            config[\rhythmSelectionMargin], config[\rhythmSelectionResidence]);
        selectedKeys = selected.collect { |voice| voice[\key] };
        rhythmSelected.do { |voice| var source = run[\rhythmSources][voice[\key]];
            if(source.notNil) { rhythmUsed.add(source[\channel]) } };
        run[\midiVoices].keys.asArray.do { |key|
            if(selectedKeys.includesEqual(key).not) { ~cwtMidiRelease.value(run, key) };
        };
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
            ~cwtMidiUpdateVoice.value(run, voice, mapped, amp, now);
        };
        rhythmSelected.do { |voice|
            var key = voice[\key], signal = voice[\signal].asSymbol;
            var sensorGain = (config[(signal.asString ++ "Gain").asSymbol] ? 1).clip(0, 4);
            var muted = config[(signal.asString ++ "Muted").asSymbol] ? false;
            var amp = ((0.18 * voice[\confidence]).clip(0.015, 0.22) / counts[voice[\device]].pow(0.35))
                * sensorGain * muted.not.asInteger;
            if(config[\rhythmEnabled] and: { muted.not } and: { amp > 0 }) {
                var rhythm = run[\rhythmSources][key], channel, notes = config[\rhythmNotes] ? [36,38,42,45];
                channel = if(rhythm.notNil) { rhythm[\channel] } {
                    (3..15).detect { |candidate| rhythmUsed.includes(candidate).not }
                };
                if(channel.notNil) {
                    rhythmUsed.add(channel);
                    rhythmDesired[key] = (key: key, channel: channel,
                        note: notes.wrapAt(channel - 3).asInteger.clip(0, 127), sourceHz: voice[\frequency],
                        level: (amp / 0.18).clip(0, 1), confidence: voice[\confidence], signal: signal);
                };
            };
        };
        ~weatherRhythmSync.value(run, rhythmDesired, now, config, ~cwtRhythmEmit);
        releasing = run[\synths].values.count { |entry| entry[\releasing] };
        run[\eligibleCount] = candidates.size; run[\selectedCount] = selected.size;
        run[\rhythmSelectedCount] = rhythmSelected.size;
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
                        run[\rhythmTick] = Routine({ loop {
                            ~weatherRhythmStep.value(run, Main.elapsedTime, config, ~cwtRhythmEmit); 0.02.wait
                        } }).play(SystemClock);
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
~cwtMidiStatus = {
    var run = ~cwtRun, c = ~cwtConfig;
    if(run.isNil) {
        "Tracked MIDI: stopped enabled=% destination='% / %' bendRange=±% semitones"
            .format(c[\midiEnabled], c[\midiDevice], c[\midiPort], c[\midiBendRange]).postln;
    } {
        "Tracked MIDI: enabled=% connected=% destination='% / %' bendRange=±% active=% error=%"
            .format(c[\midiEnabled], run[\midiConnected], c[\midiDevice], c[\midiPort],
                c[\midiBendRange], run[\midiVoices].size, run[\midiError]).postln;
        run[\midiVoices].keys.asArray.sort.do { |key|
            var entry = run[\midiVoices][key], voice = run[\voices][key];
            "  tracker=% envHz=% midi=% note=% channel=% bend=% expression=%"
                .format(if(voice.notNil) { voice[\id] } { key }, entry[\frequency].round(0.000001),
                    entry[\continuousMidi].round(0.0001), entry[\note], entry[\channel] + 1,
                    entry[\bend], entry[\expression]).postln;
        };
    };
};
~cwtRhythmStatus = {
    var run = ~cwtRun, c = ~cwtConfig;
    if(run.isNil) { "Tracked rhythm: stopped enabled=% destination='% / %'".format(
        c[\rhythmEnabled], c[\rhythmMidiDevice], c[\rhythmMidiPort]).postln } {
        "Tracked rhythm: enabled=% connected=% destination='% / %' expression=% selected=% sources=% gates=% error=%".format(
            c[\rhythmEnabled], run[\rhythmConnected], c[\rhythmMidiDevice], c[\rhythmMidiPort],
            c[\rhythmExpression], run[\rhythmSelectedCount] ? 0,
            run[\rhythmSources].size, run[\rhythmGates].size, run[\rhythmError]).postln;
        run[\rhythmSources].keys.asArray.sort.do { |key| var source = run[\rhythmSources][key];
            "  source=% envHz=% cycleHz=% stepHz=% steps=% hits=% confidence=% velocity=% channel=% note=% phase=% offset=%".format(
                key, source[\sourceHz].round(0.000001), source[\rateHz].round(0.001),
                (source[\rateHz] * (c[\rhythmEuclideanSteps] ? 8)).round(0.001), c[\rhythmEuclideanSteps],
                source[\euclideanHits], source[\confidence].round(0.01), source[\velocity],
                source[\channel] + 1, source[\note], source[\phase].round(0.001), source[\phaseOffset].round(0.001)).postln;
        };
    };
};
if(~cwtAutoStart ? true) { ~cwtStart.value };
)
