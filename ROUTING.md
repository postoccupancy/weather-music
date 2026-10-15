# Multichannel routing into Ableton Live

Weather Music uses zero-based SuperCollider hardware output buses. Tracked voices
default to bus 0 (physical channels 1–2); full spectrum defaults to bus 2 (physical
channels 3–4). Routing is independent of OSC UDP ports and internal audio buses.

## BlackHole 16ch on macOS

Install and select BlackHole 16ch manually. Weather Music never changes the audio
device or reboots the server. Stop both instruments before changing server options:

```supercollider
~cwtStop.value;
~spectrumStop.value(true);
s.quit;
s.options.outDevice = "BlackHole 16ch";
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 16;
s.boot;
```

After the server reports ready, evaluate both instrument files and confirm:

```supercollider
~cwtSetOutputBus.value(0);       // BlackHole channels 1–2
~spectrumSetOutputBus.value(2);  // BlackHole channels 3–4
~cwtStatus.value;
~spectrumStatus.value;
```

In Ableton Live:

1. Open **Settings → Audio** and select **BlackHole 16ch** as the input device.
2. Use **Input Config** to enable stereo pairs 1/2 and 3/4.
3. Create a stereo audio track named “CWT Voices,” choose **Ext. In 1/2**.
4. Create a stereo audio track named “CWT Spectrum,” choose **Ext. In 3/4**.
5. Set each track's monitor to **In**, or use **Auto** and arm it for recording.
6. Select wired headphones or the desired physical interface as Ableton's output
   device. Monitor the two signals through Ableton, where effects and recording live.

For a Behringer UMC1820 or another multichannel interface, select its exact device
name from `ServerOptions.outDevices`, set `numOutputBusChannels` to the number the
driver exposes, reboot the server, and keep the same bus assignments. Ableton may
use that interface as both input and output if its driver exposes loopback channels;
ordinary physical outputs do not automatically become Ableton inputs. BlackHole is
the predictable software-routing path when the interface lacks loopback.

## Stereo fallback and validation

At startup and in the live output-bus setters, each instrument verifies that the
requested bus and the following channel exist. On a two-output device, spectrum bus
2 is invalid, so the sketch warns and uses explicit `fallbackOutputBus: 0`. This
means both instruments intentionally share outputs 1–2 in fallback mode. It is not
multichannel separation.

An invalid requested bus is never sent silently to the server. Change
`fallbackOutputBus` before startup if bus 0 is unsuitable. A live bus setter can
move an existing output synth, but changing the hardware device or channel count
requires stopping both instruments, quitting and rebooting the server, then
starting the instruments again.

## Preventing double monitoring and feedback

- Send SuperCollider to BlackHole only; monitor from Ableton's physical output.
- Do not also route the same SuperCollider signal directly to headphones through a
  macOS Multi-Output Device unless deliberate doubled monitoring is desired.
- Do not route Ableton's master output back into the same BlackHole input channels
  used by its monitored tracks. That creates a feedback loop.
- Start with Ableton track and master faders low, verify meters independently, then
  raise monitoring gain.
- Disable software monitoring in any additional recorder that is also listening to
  BlackHole.

The automated tests verified bus validation, warned stereo fallback, distinct
instrument output synths, shared concurrent OSC lease ownership, and limiter
placement. The BlackHole 16ch and UMC1820 channel layouts still require manual
verification on the user's selected hardware and Ableton configuration.
