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
s.options.outDevice = "BlackHole 16ch";
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 16;
s.options.sampleRate = 48000;
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