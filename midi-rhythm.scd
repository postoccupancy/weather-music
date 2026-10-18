/* Shared phase-accumulating MIDI pulse engine. Callers own selection and transport. */
(
~weatherRhythmRate = { |sourceHz, config|
    var low = (config[\rhythmSourceMinHz] ? 0.05).max(0.000001);
    var high = (config[\rhythmSourceMaxHz] ? 1.0).max(low * 1.000001);
    var outLow = (config[\rhythmPulseMinHz] ? 0.5).max(0.01);
    var outHigh = (config[\rhythmPulseMaxHz] ? 4.0).max(outLow);
    var position = (sourceHz.clip(low, high) / low).log / (high / low).log;
    outLow * ((outHigh / outLow) ** position)
};
~weatherRhythmVelocity = { |level, config|
    var low = config[\rhythmVelocityInputFloor] ? 0;
    var high = (config[\rhythmVelocityInputCeiling] ? 1).max(low + 0.000001);
    var min = (config[\rhythmVelocityMin] ? 35).asInteger.clip(1, 127);
    var max = (config[\rhythmVelocityMax] ? 110).asInteger.clip(min, 127);
    level.clip(low, high).linlin(low, high, min, max).round.asInteger.clip(1, 127)
};
~weatherRhythmReleaseOwner = { |run, sourceKey, emit|
    run[\rhythmGates].keys.asArray.do { |gateKey|
        var gate = run[\rhythmGates][gateKey];
        gate[\owners].removeAt(sourceKey);
        if(gate[\owners].isEmpty) {
            if(run[\rhythmOut].notNil) { emit.value(run[\rhythmOut], \noteOff, gate[\channel], gate[\note], 0) };
            run[\rhythmGates].removeAt(gateKey);
        };
    };
};
~weatherRhythmSync = { |run, desired, now, config, emit|
    run[\rhythmSources].keys.asArray.do { |key|
        if(desired[key].isNil) {
            ~weatherRhythmReleaseOwner.value(run, key, emit); run[\rhythmSources].removeAt(key);
        };
    };
    desired.keysValuesDo { |key, wanted|
        var source = run[\rhythmSources][key];
        if(source.isNil) {
            source = wanted.copy.putAll((phase: 0.0, lastTime: now)); run[\rhythmSources][key] = source;
        } {
            if((source[\channel] != wanted[\channel]) or: { source[\note] != wanted[\note] }) {
                ~weatherRhythmReleaseOwner.value(run, key, emit);
            };
            wanted.keysValuesDo { |field, value| source[field] = value };
        };
        source[\rateHz] = ~weatherRhythmRate.value(source[\sourceHz], config);
        source[\velocity] = ~weatherRhythmVelocity.value(source[\level], config);
    };
};
~weatherRhythmStep = { |run, now, config, emit|
    var duration = (config[\rhythmPulseDuration] ? 0.08).clip(0.01, 2);
    var maxEvents = (config[\rhythmMaxEventsPerTick] ? 16).asInteger.clip(1, 128);
    run[\rhythmGates].keys.asArray.do { |gateKey|
        var gate = run[\rhythmGates][gateKey];
        gate[\owners].keys.asArray.do { |owner|
            if(gate[\owners][owner] <= now) { gate[\owners].removeAt(owner) };
        };
        if(gate[\owners].isEmpty) {
            if(run[\rhythmOut].notNil) { emit.value(run[\rhythmOut], \noteOff, gate[\channel], gate[\note], 0) };
            run[\rhythmGates].removeAt(gateKey);
        };
    };
    if(run[\rhythmConnected]) {
        run[\rhythmSources].keys.asArray.sort.do { |key|
            var source = run[\rhythmSources][key], dt = (now - source[\lastTime]).clip(0, 1);
            var pulses, gateKey, gate;
            source[\phase] = source[\phase] + (dt * source[\rateHz]); source[\lastTime] = now;
            pulses = source[\phase].floor.asInteger.min(maxEvents); source[\phase] = source[\phase] - pulses;
            pulses.do {
                gateKey = source[\channel].asString ++ "/" ++ source[\note].asString;
                gate = run[\rhythmGates][gateKey];
                if(gate.isNil) {
                    gate = (channel: source[\channel], note: source[\note], owners: Dictionary.new);
                    run[\rhythmGates][gateKey] = gate;
                };
                gate[\owners][key] = now + duration;
                emit.value(run[\rhythmOut], \noteOn, source[\channel], source[\note], source[\velocity]);
            };
        };
    };
};
~weatherRhythmPanic = { |run, channels, emit, clearSources=false|
    if(run.notNil) {
        if(run[\rhythmOut].notNil) {
            run[\rhythmGates].values.do { |gate| emit.value(run[\rhythmOut], \noteOff, gate[\channel], gate[\note], 0) };
            channels.do { |channel| emit.value(run[\rhythmOut], \allNotesOff, channel) };
        };
        run[\rhythmGates].clear;
        if(clearSources) { run[\rhythmSources].clear };
    };
};
~weatherRhythmResync = { |run, now, config, emit|
    ~weatherRhythmPanic.value(run, [], emit, false);
    if(run.notNil and: { run[\rhythmConnected] }) {
        run[\rhythmSources].keys.asArray.sort.do { |key|
            var source = run[\rhythmSources][key], gateKey, gate;
            gateKey = source[\channel].asString ++ "/" ++ source[\note].asString;
            gate = run[\rhythmGates][gateKey] ? (channel: source[\channel], note: source[\note], owners: Dictionary.new);
            run[\rhythmGates][gateKey] = gate; gate[\owners][key] = now + (config[\rhythmPulseDuration] ? 0.08);
            emit.value(run[\rhythmOut], \noteOn, source[\channel], source[\note], source[\velocity]);
            source[\lastTime] = now;
        };
    };
};
)
