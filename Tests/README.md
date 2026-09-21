# Stability checks

The September 19 crash reports showed two main-thread failures:

- `MeterView.draw` → `NSString.size(withAttributes:)` → CoreText `TAttributes::ApplyFont` → an Objective-C exception inserting a nil font-feature value.
- Timer callback → `MainActor.assumeIsolated` → invalid object access in `swift_task_isMainExecutorImpl`.

The first path is eliminated by vector lettering in the animated meter. The second is eliminated by a main-run-loop selector timer and an explicit `@MainActor` app entry point. Those fixes addressed rendering and timer crashes; the September 21 capture handoff fix is described below.

Build, then stress the actual meter renderer:

```sh
bash scripts/build.sh
xcrun swiftc -module-cache-path build/module-cache Sources/MeterView.swift Tests/MeterScaleTests.swift -o build/meter-scale-tests -framework AppKit
build/meter-scale-tests
xcrun swiftc -O -module-cache-path build/module-cache Sources/MeterView.swift Tests/MeterStress.swift -o build/meter-stress -framework AppKit
build/meter-stress
```

The scale test checks rendered height and lit-segment boundaries across the green,
yellow, and red ranges. It also covers the −42 dBFS floor, silence, invalid values,
and overrange clamping.

Run the complete app for longer than the reported 14–102 second crash intervals:

```sh
python3 Tests/app_soak.py --seconds 180
```

Quit an existing DockVU instance first. The check leaves a successful instance open. `--demo` runs the same UI without audio capture. Logs go to `build/diagnostics/soak.log`.

The original crash is intermittent: the standalone draw stress also passed before the fix. It is a stress check, not a deterministic reproduction. The captured crash stacks establish the failing call sites; the full-app soak checks stability after their removal.

## Camera activity

```sh
xcrun swiftc -module-cache-path build/module-cache Sources/CameraMonitor.swift Tests/CameraMonitorTests.swift -o build/camera-tests -framework CoreMediaIO
build/camera-tests --live
```

The tests cover any-active-camera precedence, unknown device states, idle, no cameras, and failed enumeration. `--live` also prints the current passive hardware reading without activating a camera. The meter stress cycles gray, red, and amber cues. A physical camera-on/off transition requires a connected camera and another app using it.

## Device volume and mute

```sh
xcrun swiftc -module-cache-path build/module-cache Sources/OutputVolume.swift Tests/OutputVolumeTests.swift -o build/output-volume-tests -framework CoreAudio
build/output-volume-tests --live
```

The deterministic checks use an injected property reader and never alter device settings. They
cover dB preference over scalar volume, main and per-channel output controls and mute,
unsupported-control unity fallback, and main input mute without applying input hardware gain twice.
`--live` optionally prints the current read-only result for the default devices.

## Stale audio / bounded callback delivery

On September 21 the live app's selector timer was still drawing, but its heap held
7,148,406 pairs of Swift task-stack allocations (about 10 GB including closures).
The output IOProc kept producing tasks; an AVAudioEngine configuration notification
was blocked waiting for `OperationQueue.main`. The trigger that stopped main-queue
servicing was not established. Capture callbacks now overwrite fixed-size mailbox
slots; the common-mode display timer reads them directly. Device and permission
callbacks use coalesced mailbox events too, and the engine observer runs on the
posting thread without waiting for the main queue. Samples expire after 0.5 seconds.

```sh
xcrun swiftc -O -module-cache-path build/module-cache Sources/AudioCaptureMailbox.swift Tests/AudioCaptureMailboxTests.swift -o build/audio-mailbox-tests
build/audio-mailbox-tests
xcrun swiftc -O -module-cache-path build/module-cache Sources/AudioCaptureMailbox.swift Tests/AudioHandoffRunLoopTests.swift -o build/audio-runloop-tests -framework AppKit
build/audio-runloop-tests
```

The first test floods both capture slots while the consumer is stopped, then checks
latest values, stale-sample clearing, restart generations, coalesced events, and
concurrent stereo reads. The second holds main dispatch inside a nested run loop:
the old per-buffer MainActor tasks deliver zero updates, but the real mailbox
continues feeding fresh stereo values to a common-mode selector timer.

After quitting any existing instance, verify actual audio callbacks as well as
process survival:

```sh
python3 Tests/app_soak.py --verify-audio --seconds 185
```

This requires granted audio permissions and working input/output devices. Every
30 seconds it asserts that both callback counts advanced and checks the full
physical footprint against a 200 MiB budget (including compressed/swapped memory).
Override the budget with `--max-footprint-mb` when deliberately profiling. `--diagnostics` on the app prints callback counts, displayed peaks, and
status every five seconds; it never logs audio samples. A short soak checks the
handoff but does not replace overnight or sleep/wake validation.

## Hourly memory watch

`scripts/memory_watch.py` performs one read-only check of every running DockVU
process owned by the current user. The installed per-user LaunchAgent
`local.dockvu.memory-watch` runs it on the hour and at login/load. Calendar checks
missed during sleep coalesce into one check on wake. It follows new process IDs
after app restarts and compares growth only within the same process lifetime.

Reports are in `build/diagnostics/memory-watch/`: `latest.json`, a bounded
90-day `history.jsonl`, and `latest-vmmap.txt`. A local macOS notification is
requested for a footprint over 100 MiB, a check failure, or four successively
larger readings spanning at least 2.5 hours and at least 10 MiB total growth.
Growth is a signal to investigate, not proof of a leak. Notifications depend on
macOS notification settings; the reports are always retained.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/MemoryWatchTests.py
python3 scripts/memory_watch.py  # manual check
launchctl print gui/$(id -u)/local.dockvu.memory-watch
```

To disable the installed watch:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.dockvu.memory-watch.plist
rm ~/Library/LaunchAgents/local.dockvu.memory-watch.plist
```

## Microphone format changes must not stop the display timer

At 09:28:45 on September 21, device reconfiguration changed input hardware from
44.1 kHz to 48 kHz. The reused engine still supplied a 44.1 kHz client format.
`installTapOnBus` raised `Failed to create tap due to format mismatch` through
`startInput` and the display timer. AppKit swallowed the exception, leaving the
process and output IOProc alive but the refresh timer stalled. Memory remained
about 28 MiB; memory-only health checks could not detect this failure.

`MicrophoneCapture` now owns a fresh AVAudioEngine for each capture attempt and
installs its tap with a nil format, allowing native format negotiation. Objective-C
setup/teardown catches NSException before it can unwind Swift or the run loop.
Setup errors become NSError, and a transient microphone failure is retried while
output monitoring continues. The native file is built with ARC exception cleanup.
Configuration callbacks do not take the control lock or wait for the main queue;
mailbox generation checks reject notifications from retired engines.

```sh
xcrun clang -fobjc-arc -fobjc-arc-exceptions -fmodules -fmodules-cache-path=build/module-cache -mmacosx-version-min=14.4 Sources/MicrophoneCapture.m Tests/MicrophoneCaptureTests.m -o build/microphone-capture-tests -framework AVFoundation -framework CoreAudio -framework AudioToolbox -framework Foundation
build/microphone-capture-tests
```

The app now overwrites `~/Library/Caches/local.dockvu.app/health.json` every five
seconds after a successful display refresh. The hourly watcher checks this
heartbeat as well as the 100 MiB memory budget; a heartbeat older than 30 seconds
is reported as `display_stalled`. A missing record is reported separately.

## Invalid negative output-volume readings

The Shanling UP5 output reported a finite `-1.437647e+28` dB value alongside a
valid `0.5625` scalar volume and no mute. Converting that dB value underflowed to
zero, silencing the output meters despite ongoing callbacks. Finite hardware dB
values outside -160...+60 now fall back to scalar volume; negative infinity still
represents legitimate silence. `OutputVolumeTests` covers the captured value,
main/per-channel controls, quiet valid dB levels, and infinity behavior. Opt-in
app diagnostics now include raw output peaks and applied gains, so live tests
can distinguish actual capture silence from volume scaling.
