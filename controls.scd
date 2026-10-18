/*
Weather Music live controls

Open this file beside live-cwt.scd and live-spectrum.scd. Evaluate individual
lines with Command-Return while performing. Do not evaluate the whole file: it
contains mutually exclusive examples such as mute/unmute and stop/start.
*/

// LIFECYCLE — evaluate one line, then wait for completion before reloading
~cwtStop.value;
~spectrumStop.value; // normal spectrum fade
~cwtStart.value;
~spectrumStart.value;

// AUDIO OUTPUT ROUTING — zero-based hardware output bus indices
~cwtSetOutputBus.value(0); // outputs 1–2; tracked default
~spectrumSetOutputBus.value(2); // outputs 3–4; spectrum default
// A stereo-only device warns and uses explicit fallback bus 0 for spectrum.
// Stop both instruments and reboot the server after changing device/channel count.
~spectrumAudioStatus.value;
~spectrumTestTone.value;

// FULL SPECTRUM MIDI — enabled by default; destination names must match exactly
MIDIClient.init; MIDIClient.destinations.postln;
~spectrumSetMidiDestination.value("IAC Driver", "Bus 3 - Ableton Live");
~spectrumSetMidiEnabled.value(true);           // false sends note-offs and disables MIDI
~spectrumSetMidiChannel.value(\temperature, 1);// user-facing channels 1..16
~spectrumSetMidiChannel.value(\humidity, 2);
~spectrumSetMidiChannel.value(\pressure, 3);
~spectrumSetMidiExpression.value(0.0001, 0.005, 0.5, 2, 64);
// Arguments: amplitude floor, ceiling, smoothing seconds, MIDI deadband, note velocity
~spectrumMidiStatus.value;
~spectrumMidiPanic.value;                      // note-offs plus all-notes-off

// TRACKED-VOICE MIDI — enabled by default; channels 2–16 are allocated per tracker
~cwtSetMidiDestination.value("IAC Driver", "Bus 3 - Ableton Live");
~cwtSetMidiEnabled.value(true);                // false releases notes and disables MIDI
~cwtSetMidiBendRange.value(2);                 // match the Ableton instrument: ±2 semitones
~cwtSetMidiExpression.value(0.005, 0.18, 0.2, 1, 64);
// Arguments: effective-amplitude floor/ceiling, smoothing seconds, deadband, velocity
~cwtMidiStatus.value;
~cwtMidiPanic.value;

// DIAGNOSTICS
~cwtStatus.value;
~spectrumStatus.value;
~spectrumInspect.value(\temperature, 0);       // sensor and scale index

// TRACKED VOICES — selection, pitch, waveform, and master
~cwtConfig[\maxPolyphony] = 144;               // default 4; nonnegative hard ceiling
~cwtSetMinConfidence.value(0.0);             // default 0; valid 0..1
~cwtConfig[\pitchMode] = \continuous;        // default; also \midi or \midiOutput
~cwtSetBaseNote.value(24);                   // default 48; MIDI coordinate 24..72
~cwtSetPitchSpan.value(36);                  // default 36; 12..72 semitones
~cwtSetBaseNote.value(36, \temperature);     // set optional sensor override
~cwtSetBaseNote.value(nil, \temperature);    // clear optional sensor override
~cwtSetPitchSpan.value(24, \temperature);    // set optional sensor override
~cwtSetPitchSpan.value(nil, \temperature);   // clear optional sensor override
~cwtSetWaveform.value(\sine);                // \sine, \triangle, or \saw
~cwtConfig[\masterVolume] = 0.8;             // default 0.8; 0 silences output

// FULL SPECTRUM — pitch and per-sensor waveform
~spectrumSetBaseNote.value(36);                // default 48; valid 24..72
~spectrumSetPitchSpan.value(48);               // default 48; 12..72 semitones
~spectrumSetBaseNote.value(60, \temperature);  // set optional sensor override
~spectrumSetBaseNote.value(nil, \temperature); // clear optional sensor override
~spectrumSetPitchSpan.value(24, \temperature); // set optional sensor override
~spectrumSetPitchSpan.value(nil, \temperature);// clear optional sensor override
~spectrumSetWaveform.value(\temperature, \sine);
~spectrumSetWaveform.value(\humidity, \triangle);
~spectrumSetWaveform.value(\pressure, \saw);

// TRACKED VOICES — per-sensor gain and mute
// Mute smoothly silences the sensor while retaining selection and tracking state.
~cwtSetGain.value(\temperature, 1.0);         // default 1; valid 0..4
~cwtSetGain.value(\humidity, 1.0);
~cwtSetGain.value(\pressure, 1.0);
~cwtMute.value(\temperature, true);          // true mutes; false unmutes
~cwtMute.value(\temperature, false);
~cwtMute.value(\humidity, true);
~cwtMute.value(\humidity, false);
~cwtMute.value(\pressure, true);
~cwtMute.value(\pressure, false);

// TRACKED VOICES — smoothing and release, seconds
~cwtConfig[\frequencySmoothing] = 0.18;       // default 0.18
~cwtConfig[\amplitudeSmoothing] = 0.35;       // default 0.35
~cwtConfig[\releaseSmoothing] = 0.6;          // default 0.6
~cwtConfig[\releaseSeconds] = 2.5;            // default 2.5; new synth allocations

// FULL SPECTRUM — amplitude mode and global gain
~spectrumSetMode.value(\physical);
~spectrumSetMode.value(\significance);        // default
~spectrumConfig[\physicalGain] = 1.0;         // default 1.0
~spectrumConfig[\significanceGain] = 0.001;   // default 0.001
~spectrumConfig[\masterGain] = 1.0;           // default 1.0

// FULL SPECTRUM — per-sensor gain and mute
~spectrumSetGain.value(\temperature, 1.0);    // default 1
~spectrumSetGain.value(\humidity, 1.0);
~spectrumSetGain.value(\pressure, 1.0);
~spectrumMute.value(\temperature, true);      // true mutes; false unmutes
~spectrumMute.value(\temperature, false);
~spectrumMute.value(\humidity, true);
~spectrumMute.value(\humidity, false);
~spectrumMute.value(\pressure, true);
~spectrumMute.value(\pressure, false);

// FULL SPECTRUM — smoothing and safety
~spectrumConfig[\smoothingSeconds] = 2.0;      // default 2 seconds
~spectrumConfig[\amplitudeCeiling] = 0.02;    // default per oscillator

// CONFIG STATUS
// Print current config settings (json)
~cwtConfig.postln;
~spectrumConfig.postln;

// Pretty-print current config settings
~cwtConfig.keys.asArray.sort.do { |key|
    "%: %".format(key, ~cwtConfig[key]).postln;
};
~spectrumConfig.keys.asArray.sort.do { |key|
    "%: %".format(key, ~spectrumConfig[key]).postln;
};

~cwtRun[\activeOutputBus].postln;
~spectrumRun[\activeOutputBus].postln;
s.options.numOutputBusChannels.postln;

// PLANNED / UNSUPPORTED
// Per-sensor tracked waveforms, effects, FM, granular synthesis, rhythmic MIDI,
// spectrum selection/ranking, VCV Rack, and automatic audio-device changes.
