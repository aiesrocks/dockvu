# DockVU

A small native macOS app that turns its Dock icon into three live audio meters:

- **IN** — the default microphone (highest peak across its channels).
- **L / R** — the default output’s left and right audio channels.
- **Green → yellow → red**, with a short white peak-hold marker.
- **Camera cue** — a red light above the bars when any detected camera is active.

Requires **macOS 14.4 or newer** and Xcode Command Line Tools to build. No dependencies or audio driver to install.

## Build and run

```sh
bash scripts/build.sh
open build/DockVU.app
```

Click **Start audio**, then allow microphone and system-audio access when macOS asks. Close the window to leave just the live Dock meters. Click the Dock icon to reopen it; right-click for pause and resume. Quit with ⌘Q.

## Camera activity

The single cue dot above the audio bars turns **red** when a camera is running in any app. The window lists active camera names. **Gray** means no detected camera is active; **amber** means activity could not be checked fully.

Camera status updates once per second, detects connected/disconnected devices, and keeps working while audio is paused. DockVU reads camera activity flags through [Core Media I/O](https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceisrunningsomewhere); it never starts a camera, opens a video feed, or records images. It covers camera devices exposed by macOS, including virtual cameras whose drivers report activity. Devices that hide or misreport their state cannot be reliably detected.

To keep the app, copy `build/DockVU.app` to Applications. You can add it to Login Items in System Settings if you want it to launch at login. Move it before granting permissions to keep a consistent app location.

## What the bars mean

These are live **audio signal levels**, not the volume-slider percentages. The display spans −42 to 0 dBFS. Yellow begins above −9 dBFS and red above −1 dBFS, so background noise and ordinary listening levels occupy fewer bars while signals close to clipping remain easy to see. This changes only the display scale; it does not add gain or a noise gate. Output reflects the digital audio stream; it is not a measurement of speaker loudness. Turning a hardware volume knob down may not change the bars.

The app follows the default input and output devices. On a multichannel audio interface, output meters show the first two channels of its first output stream. Audio is processed in memory only: nothing is recorded to a file or sent over the network. macOS may show its microphone/audio-capture indicator while monitoring is active.

## Permissions and development

If a meter does not respond, check **System Settings → Privacy & Security → Microphone** and **Screen & System Audio Recording**, then pause and restart monitoring. Protected audio may be unavailable to capture.

The build uses local ad-hoc signing. Rebuilding may require granting permissions again. If you have a signing identity, use `DOCKVU_SIGN_IDENTITY="Your identity" bash scripts/build.sh`.

For a visual preview without capturing audio:

```sh
open build/DockVU.app --args --demo
```

The preview uses generated levels and is clearly marked as a demo. Quit an existing instance before launching it.

Built with AppKit, AVAudioEngine, and [Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).
