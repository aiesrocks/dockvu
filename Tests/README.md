# Stability checks

The September 19 crash reports showed two main-thread failures:

- `MeterView.draw` → `NSString.size(withAttributes:)` → CoreText `TAttributes::ApplyFont` → an Objective-C exception inserting a nil font-feature value.
- Timer callback → `MainActor.assumeIsolated` → invalid object access in `swift_task_isMainExecutorImpl`.

The first path is eliminated by vector lettering in the animated meter. The second is eliminated by a main-run-loop selector timer and an explicit `@MainActor` app entry point. Core Audio capture remains unchanged.

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
