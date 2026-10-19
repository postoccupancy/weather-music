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
~weatherRhythmNormalized = { |level, config|
    var low = config[\rhythmVelocityInputFloor] ? 0;
    var high = (config[\rhythmVelocityInputCeiling] ? 1).max(low + 0.000001);
    level.clip(low, high).linlin(low, high, 0, 1)
};
~weatherRhythmVelocity = { |level, config|
    var normalized = ~weatherRhythmNormalized.value(level, config);
    var min = (config[\rhythmVelocityMin] ? 35).asInteger.clip(1, 127);
    var max = (config[\rhythmVelocityMax] ? 110).asInteger.clip(min, 127);
    normalized.linlin(0, 1, min, max).round.asInteger.clip(1, 127)
};
~weatherRhythmHits = { |normalized, previous, config|
    var minimum = (config[\rhythmEuclideanMinHits] ? 1).asInteger;
    var maximum = (config[\rhythmEuclideanMaxHits] ? 8).asInteger.max(minimum);
    var target = normalized.linlin(0, 1, minimum, maximum).round.asInteger.clip(minimum, maximum);
    var hysteresis = (config[\rhythmEuclideanDensityHysteresis] ? 0.08).clip(0, 0.49);
    var center;
    if(previous.isNil) { target } {
        center = previous.linlin(minimum, maximum, 0, 1);
        if((normalized - center).abs <= hysteresis) { previous } { target }
    }
};
~weatherEuclideanHit = { |step, hits, steps|
    hits > 0 and: { (((step * hits) % steps) < hits) }
};
~weatherSelectHysteretic = { |candidates, state, limit, scoreField, now, margin=0, residence=0|
    var byKey = Dictionary.new, selected = List.new, challengers, weakest, challenger, replacing = true;
    if(limit <= 0) { state.clear; [] } {
    candidates.do { |item| byKey[item[\key]] = item };
    state.keys.asArray.do { |key| if(byKey[key].isNil) { state.removeAt(key) } };
    state.keys.asArray.sort.do { |key| selected.add(byKey[key]) };
    while { selected.size > limit } {
        weakest = selected.sort { |a,b| a[scoreField] < b[scoreField] }.first;
        selected.remove(weakest); state.removeAt(weakest[\key]);
    };
    challengers = candidates.select { |item| state[item[\key]].isNil }
        .sort { |a,b| if(a[scoreField] == b[scoreField]) { a[\key].compare(b[\key]) < 0 } { a[scoreField] > b[scoreField] } };
    while { selected.size < limit and: { challengers.notEmpty } } {
        challenger = challengers.removeAt(0); selected.add(challenger); state[challenger[\key]] = now;
    };
    while { selected.size >= limit and: { challengers.notEmpty } and: { replacing } } {
        weakest = selected.sort { |a,b| a[scoreField] < b[scoreField] }.first;
        challenger = challengers.removeAt(0);
        if((now - (state[weakest[\key]] ? now)) >= residence and: {
            challenger[scoreField] > (weakest[scoreField] * (1 + margin))
        }) {
            selected.remove(weakest); state.removeAt(weakest[\key]);
            selected.add(challenger); state[challenger[\key]] = now;
        } { replacing = false };
    };
        selected.asArray.sort { |a,b| if(a[scoreField] == b[scoreField]) { a[\key].compare(b[\key]) < 0 } { a[scoreField] > b[scoreField] } }
            .keep(limit)
    }
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
    var mode = config[\rhythmExpression] ? \velocity;
    run[\rhythmSources].keys.asArray.do { |key|
        if(desired[key].isNil) {
            ~weatherRhythmReleaseOwner.value(run, key, emit); run[\rhythmSources].removeAt(key);
        };
    };
    desired.keysValuesDo { |key, wanted|
        var source = run[\rhythmSources][key], previousMode;
        if(source.isNil) {
            source = wanted.copy.putAll((phase:0.0, cycles:0, lastTime:now, phaseOffset:0.0,
                emittedCycle:0, euclideanStep:0, euclideanHits:nil));
            run[\rhythmSources][key] = source;
        } {
            if((source[\channel] != wanted[\channel]) or: { source[\note] != wanted[\note] }) {
                ~weatherRhythmReleaseOwner.value(run, key, emit);
            };
            if((source[\active] ? true) and: { (wanted[\active] ? true).not }) {
                ~weatherRhythmReleaseOwner.value(run, key, emit);
            };
            wanted.keysValuesDo { |field, value| source[field] = value };
        };
        previousMode = source[\expressionMode];
        source[\rateHz] = ~weatherRhythmRate.value(source[\sourceHz], config);
        source[\normalized] = ~weatherRhythmNormalized.value(source[\level], config);
        source[\velocity] = if(mode == \velocity) { ~weatherRhythmVelocity.value(source[\level], config) } {
            (config[\rhythmConstantVelocity] ? 80).asInteger.clip(1, 127)
        };
        if(previousMode == \euclidean and: { mode != \euclidean }) {
            source[\emittedCycle] = (source[\cycles] + source[\phase] + source[\phaseOffset]).floor.asInteger;
        };
        source[\expressionMode] = mode;
        if(source[\euclideanHits].isNil) {
            source[\euclideanHits] = ~weatherRhythmHits.value(source[\normalized], nil, config)
        };
    };
};
~weatherRhythmStep = { |run, now, config, emit|
    var duration = (config[\rhythmPulseDuration] ? 0.08).clip(0.01, 2);
    var budget = (config[\rhythmMaxEventsPerTick] ? 16).asInteger.clip(1, 128);
    var mode = config[\rhythmExpression] ? \velocity;
    var candidates = List.new, keys, start;
    run[\rhythmGates].keys.asArray.do { |gateKey|
        var gate = run[\rhythmGates][gateKey];
        gate[\owners].keys.asArray.do { |owner| if(gate[\owners][owner] <= now) { gate[\owners].removeAt(owner) } };
        if(gate[\owners].isEmpty) {
            if(run[\rhythmOut].notNil) { emit.value(run[\rhythmOut], \noteOff, gate[\channel], gate[\note], 0) };
            run[\rhythmGates].removeAt(gateKey);
        };
    };
    if(run[\rhythmConnected]) {
        keys = run[\rhythmSources].keys.asArray.sort;
        start = (run[\rhythmCursor] ? 0) % keys.size.max(1);
        keys = if(keys.isEmpty) { [] } { keys.rotate(start.neg) };
        keys.do { |key|
            var source = run[\rhythmSources][key], dt = (now - source[\lastTime]).clip(0, 1);
            var oldTotal = source[\cycles] + source[\phase], newTotal, oldStep, newStep;
            var targetOffset, alpha, effective, crossings, steps;
            newTotal = oldTotal + (dt * source[\rateHz]);
            source[\cycles] = newTotal.floor.asInteger; source[\phase] = newTotal.frac; source[\lastTime] = now;
            targetOffset = if(mode == \phase) {
                source[\normalized] * (config[\rhythmPhaseMaxCycles] ? 0.25).clip(0, 0.49)
            } { 0.0 };
            alpha = if((config[\rhythmPhaseSmoothing] ? 2) <= 0) { 1 } {
                1 - (dt.neg / (config[\rhythmPhaseSmoothing] ? 2)).exp
            };
            source[\phaseOffset] = source[\phaseOffset] + ((targetOffset - source[\phaseOffset]) * alpha);
            if(mode == \euclidean) {
                steps = (config[\rhythmEuclideanSteps] ? 8).asInteger.clip(1, 64);
                oldStep = (oldTotal * steps).floor.asInteger;
                newStep = (newTotal * steps).floor.asInteger;
                if(newStep > oldStep) { (oldStep + 1 .. newStep).do { |absoluteStep|
                    var step = absoluteStep % steps;
                    if(step == 0) {
                        source[\euclideanHits] = ~weatherRhythmHits.value(source[\normalized], source[\euclideanHits], config)
                    };
                    source[\euclideanStep] = step;
                    if((source[\active] ? true) and: {
                        ~weatherEuclideanHit.value(step, source[\euclideanHits], steps)
                    }) { candidates.add([key, source]) };
                } };
            } {
                effective = newTotal + source[\phaseOffset];
                crossings = (effective.floor.asInteger - source[\emittedCycle]).max(0);
                source[\emittedCycle] = source[\emittedCycle].max(effective.floor.asInteger);
                if(source[\active] ? true) { crossings.do { candidates.add([key, source]) } };
            };
        };
        candidates.keep(budget).do { |event|
            var key = event[0], source = event[1];
            var gateKey = source[\channel].asString ++ "/" ++ source[\note].asString;
            var gate = run[\rhythmGates][gateKey];
            if(gate.isNil) {
                gate = (channel:source[\channel], note:source[\note], owners:Dictionary.new);
                run[\rhythmGates][gateKey] = gate;
            };
            gate[\owners][key] = now + duration;
            emit.value(run[\rhythmOut], \noteOn, source[\channel], source[\note], source[\velocity]);
        };
        run[\rhythmCursor] = (start + budget) % keys.size.max(1);
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
            if(source[\active] ? true) {
                gateKey = source[\channel].asString ++ "/" ++ source[\note].asString;
                gate = run[\rhythmGates][gateKey] ? (channel:source[\channel], note:source[\note], owners:Dictionary.new);
                run[\rhythmGates][gateKey] = gate; gate[\owners][key] = now + (config[\rhythmPulseDuration] ? 0.08);
                emit.value(run[\rhythmOut], \noteOn, source[\channel], source[\note], source[\velocity]);
            };
            source[\lastTime] = now;
        };
    };
};
)
