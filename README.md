# Live CWT sine sketch

`live-cwt.scd` is a native SuperCollider client for Electric Sea. It registers with
`192.168.0.41:5005`, receives OSC on UDP 9000, and plays at most four sine oscillators
(including release tails). No intermediary or Electric Sea changes are needed.

## Start and stop

1. Open `live-cwt.scd` in the SuperCollider IDE on the receiving Mac. Make sure UDP
   9000 is not owned by another application. Start with your speakers/headphones low.
2. Edit the configuration at the top if necessary. Evaluate the **entire block**
   (select all, Command-Return). The sketch boots the local audio server if needed;
   when doing so it disables unused microphone input to avoid input/output rate
   mismatches. It does not change an already-running server's audio configuration.
3. Look for `CWT running`. Ready active voices should appear in diagnostics within
   five seconds of the router's snapshot. Defaults are the browser's continuous
   pitch mapping and volume 0.8. No clicks or MIDI permissions are required.
4. Evaluate `~cwtStop.value;` to unsubscribe and immediately free this sketch's
   group, synths, receive callback, heartbeat and update routines. Command-period
   also cleans up. The shared audio server remains available to other sketches.
5. Evaluate `~cwtStart.value;` to restart, or re-evaluate the whole file. Re-evaluation
   stops the previous instance before installing another one. It resets controls.

SuperCollider's installed Main API opens additional UDP ports for the lifetime of
sclang and has no closeUDPPort method. Stop removes the callback and subscription;
9000 remains language-owned and is reused on restart. Quit/restart the language to
release the socket to another application. Do not run two native clients on the
same IP and port: the router lease is per destination, so either can unsubscribe it.

## Controls

Change these live in the IDE; updates take effect on the next 100 ms control tick:

```supercollider
~cwtConfig[\masterVolume] = 0.4;       // 0 mutes; browser default is 0.8
~cwtConfig[\pitchMode] = \continuous; // default, unquantized
~cwtConfig[\pitchMode] = \midi;       // browser audio's rounded MIDI pitches
~cwtConfig[\pitchMode] = \midiOutput; // actual MIDI-output pitch hysteresis
~cwtConfig[\deviceFilter] = "indoor-sky";
~cwtConfig[\signalFilter] = "temperature";
~cwtConfig[\deviceFilter] = nil;      // all devices
~cwtConfig[\signalFilter] = nil;      // all signals
~cwtConfig[\maxPolyphony] = 4;        // nonnegative integer
~cwtConfig[\frequencySmoothing] = 0.18; // exponential time constant, seconds
~cwtConfig[\amplitudeSmoothing] = 0.35;
```

Other controls: `baseOctave` (3), `pitchSpan` (3 octaves), `releaseSmoothing` (0.6 s),
`releaseSeconds` (2.5 s), `trafficTimeout` (15 s), `diagnosticsInterval` (5 s).
Use positive smoothing/timeout settings. Release settings apply to newly created
synths. Lowering polyphony releases excess synths before their slots are reused;
the old tails can persist for 2.5 seconds. Raising the cap above four explicitly
changes the instrument's default limit. Volume is not automatically limited.

Stop/start after changing `routerIP`, `routerPort` or `localPort`. The existing
router accepts **only localPort 9000** despite exposing this setting for future
routers/testing. A LAN or Tailscale IPv4 address works; use the address reachable
from this Mac. Allow inbound UDP 9000 and outbound UDP 5005. The router's UDP output
source port is ephemeral: the client filters the sender IP, not its source port.
Registration occurs after audio startup and handlers are installed. A native OSC
heartbeat every ten seconds renews the 30-second lease and obtains a fresh snapshot.

## Behavior and diagnostics

The full `device/signal/id` is the dictionary key. Repeated updates set existing
synth controls; they do not retrigger oscillators. Selection prioritizes confidence,
then incumbent synths on ties, then lexicographic full identity. Higher-confidence
voices can displace incumbents. New voices wait for outgoing release tails to finish,
so a steal never temporarily exceeds the cap. Selection is separate from mapping.

The sketch waits for a ready authoritative list before sounding a stream. Inactive
packets, missing IDs, unready lists and 15 seconds without stream/voice traffic
release voices. Timestamps remain source metadata; local monotonic receipt time
is used only for the watchdog. Unready state, silence and backwards source time
retire old identities. A subsequent reused ID gets a fresh synth after its old tail.
Diagnostics print every five seconds, not per packet, including identity, input Hz,
audio Hz, MIDI note in quantized modes, confidence and active/release state.

UDP has no ordering guarantee or epoch identifier. A reordered older frame can
cause a conservative release; an entirely missed restart with increasing timestamps
and identical IDs cannot be distinguished from continuity. Five-second router
snapshots and heartbeat snapshots repair ordinary loss. This sketch does not infer
sub-second onset times from the CWT summaries.

See [mapping parity](MAPPING-PARITY.md) for exact formulas and deliberate differences.

## Validation

With SuperCollider installed, run the native local fixture test:

```sh
/Applications/SuperCollider.app/Contents/MacOS/sclang -D tests/live-cwt-test.scd
```

It boots local audio **muted**, uses loopback OSC on 9000/50055 (no Pi subscription),
and tests mapping, selection, node continuity, release, readiness, ID reuse,
heartbeat, timeout and repeated cleanup. Run it without another client owning 9000.
For an audible check in the IDE, start the sketch normally, switch between
`continuous` and `midi`, and confirm gliding/quantized pitches without node restarts.
Check `~cwtRun[\synths].size` (at most four by default), then stop and confirm silence.

Validated on this Mac with SuperCollider 3.14.1: the native fixture suite passed,
and an 18-second muted live test against `192.168.0.41` received humidity, pressure,
RMS and temperature streams, with four synths selected from seven active records
at the final snapshot. It unsubscribed and shut down cleanly. Speaker listening
was not tested; use the IDE steps above for the audible check.
