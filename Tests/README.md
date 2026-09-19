# Stability checks

The September 19 crash reports showed two main-thread failures:

- `MeterView.draw` → `NSString.size(withAttributes:)` → CoreText `TAttributes::ApplyFont` → an Objective-C exception inserting a nil font-feature value.
- Timer callback → `MainActor.assumeIsolated` → invalid object access in `swift_task_isMainExecutorImpl`.

The first path is eliminated by vector lettering in the animated meter. The second is eliminated by a main-run-loop selector timer and an explicit `@MainActor` app entry point. Core Audio capture remains unchanged.

Build, then stress the actual meter renderer:

```sh
bash scripts/build.sh
xcrun swiftc -O -module-cache-path build/module-cache Sources/MeterView.swift Tests/MeterStress.swift -o build/meter-stress -framework AppKit
build/meter-stress
```

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
