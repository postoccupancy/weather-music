// CONFIGURE AUDIO OUTPUTS
s.quit; // quit the audio server
s.options.outDevice = "BlackHole 16ch";
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 16;
s.options.sampleRate = 48000;
s.boot;

// open internal audio meter
s.meter;

// play a test tone
~routingTest = {
    SinOsc.ar(440, 0, 0.08) ! 2
}.play(s, outbus: 2);
// end tone
~routingTest.free;

// check output config
s.options.outDevice.postln;
s.options.numOutputBusChannels.postln;

s.serverRunning.postln;
s.options.outDevice.postln;
s.options.numOutputBusChannels.postln;
s.avgCPU.postln;

~spectrumRun.notNil.postln;
~spectrumRun[\running].postln;
~spectrumRun[\output].postln;
~spectrumRun[\activeOutputBus].postln;

// full restart sequence
~cwtStop.value;
~spectrumStop.value(true);

s.quit;

// BlackHole 16ch
s.options.outDevice = "BlackHole 16ch";
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 16;

// Scarlett 2i2 USB
s.options.outDevice = "Scarlett 2i2 USB";
s.options.numInputBusChannels = 2;
s.options.numOutputBusChannels = 2;

// MacBook Pro Speakers
s.options.outDevice = "MacBook Pro Speakers";
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 2;


s.boot;

~cwtStart.value;
~spectrumStart.value;

~spectrumSetOutputBus.value(2);
~spectrumConfig[\masterGain] = 0.1;

~spectrumAudioStatus.value;
~spectrumTestTone.value;

[
    \functionLoaded, ~spectrumAudioStatus.notNil,
    \serverRunning, s.serverRunning,
    \device, s.options.outDevice,
    \channels, s.options.numOutputBusChannels,
    \configuredBus, ~spectrumConfig[\outputBus],
    \activeBus, ~spectrumRun[\activeOutputBus],
    \routing, ~spectrumRun[\routingState],
    \master, ~spectrumConfig[\masterGain],
    \outputPeak, ~spectrumRun[\outputPeak],
    \outputSeen, ~spectrumRun[\outputSeen]
].postln;

// list available audio devices
ServerOptions.devices.postln;     // All available devices
ServerOptions.inDevices.postln;   // Input-capable devices
ServerOptions.outDevices.postln;  // Output-capable devices

// full server config report
(
"Server running: %".format(s.serverRunning).postln;
"Configured input: %".format(s.options.inDevice).postln;
"Configured output: %".format(s.options.outDevice).postln;
"Requested sample rate: %".format(s.options.sampleRate).postln;
"Actual sample rate: %".format(s.sampleRate).postln;
"Output bus channels: %".format(s.options.numOutputBusChannels).postln;
"Input bus channels: %".format(s.options.numInputBusChannels).postln;
)

// Ongoing monitoring
s.meter;    // Audio levels
s.scope;    // Waveforms
s.queryAllNodes;  // Running synths and groups

// Simple switch output function -- must quit server first
(
~configureAudio = { |device="BlackHole 16ch", outputs=16, inputs=0, rate=nil|
    if(s.serverRunning) {
        "Stop the sketches and quit the server before changing devices.".warn;
    } {
        s.options.device = device;
        s.options.numOutputBusChannels = outputs;
        s.options.numInputBusChannels = inputs;
        s.options.sampleRate = rate;
        "Configured: %, outputs %, inputs %, requested rate %"
            .format(device, outputs, inputs, rate).postln;
        s.boot;
    };
};
)

// then insert into restart sequence
// For SuperCollider → BlackHole → Ableton
~configureAudio.value("BlackHole 16ch", 16, 0);

// For SuperCollider → Scarlett directly
~configureAudio.value("Scarlett 2i2 USB", 2, 2);

// For SuperCollider → MacBook speakers directly
~configureAudio.value("MacBook Pro Speakers", 2, 0);


~spectrumSetMidiExpression.value(
    0.0001,  // floor
    0.1,     // ceiling (raised from 0.02)
    0.1,     // smoothing
    0,       // deadband
    64       // note-on velocity
);

~spectrumMidiStatus.value;
~spectrumInspect.value(\temperature, 0);

~spectrumRun[\streams].values.do { |stream|
    var targets = stream[\targets] ? [];
    [
        stream[\signal],
        \minimum, targets.minItem,
        \maximum, targets.maxItem,
        \average, targets.sum / targets.size.max(1)
    ].postln;
};

~spectrumSetMidiExpression.value(
    0.00001, // floor
    0.003,   // ceiling
    0.1,     // smoothing
    0,       // no deadband while diagnosing
    64
);

~spectrumSetMidiExpression.value(0.00001, 0.005, 0.25, 1, 64);

[
    \mode, ~spectrumConfig[\mode],
    \physicalGain, ~spectrumConfig[\physicalGain],
    \significanceGain, ~spectrumConfig[\significanceGain],
    \amplitudeCeiling, ~spectrumConfig[\amplitudeCeiling]
].postln;

~spectrumConfig[\physicalGain] = 0.5;
// or:
~spectrumConfig[\significanceGain] = 0.001;

~spectrumRun[\streams].values.do { |stream|
    var targets = stream[\targets] ? [];
    if(targets.notEmpty) {
        [
            stream[\signal],
            \min, targets.minItem,
            \max, targets.maxItem,
            \mean, targets.sum / targets.size,
            \median, targets.sort[targets.size div: 2],
            \clipped, targets.count { |a| a >= ~spectrumConfig[\amplitudeCeiling] }
        ].postln;
    };
};

~spectrumMidiStatus.value;

~spectrumSetMidiExpression.value(
    0.00001,  // floor
    0.02,    // ceiling
    0,        // no smoothing
    0,        // no deadband
    64
);

[
    \mode, ~spectrumConfig[\mode],
    \physicalGain, ~spectrumConfig[\physicalGain],
    \significanceGain, ~spectrumConfig[\significanceGain],
    \amplitudeCeiling, ~spectrumConfig[\amplitudeCeiling]
].postln;

~spectrumRun[\streams].values.do { |st|
    var t = st[\targets] ? [];
    if(t.notEmpty) {
        [st[\signal], \min, t.minItem, \max, t.maxItem, \mean, t.sum / t.size].postln;
    };
};