import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audio = AudioMonitor()
    private let camera = CameraMonitor()
    private var lastCameraRefresh: TimeInterval = -.infinity
    private let dockMeter = MeterView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private let windowMeter = MeterView(frame: NSRect(x: 0, y: 0, width: 176, height: 176))
    private var window: NSWindow!
    private var timer: Timer?
    private var labelState = ""
    private let inputLabel = NSTextField(labelWithString: "Default microphone")
    private let outputLabel = NSTextField(labelWithString: "Default output")
    private let cameraLabel = NSTextField(labelWithString: "Camera · Checking…")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let toggle = NSButton(title: "Start monitoring", target: nil, action: nil)
    private let inputSensitivityPopup = NSPopUpButton()
    private let outputSensitivityPopup = NSPopUpButton()
    private var inputSensitivity = MeterSensitivity(
        rawValue: UserDefaults.standard.string(forKey: "inputSensitivity") ?? ""
    ) ?? .normal
    private var outputSensitivity = MeterSensitivity(
        rawValue: UserDefaults.standard.string(forKey: "outputSensitivity") ?? ""
    ) ?? .normal
    private var demo = CommandLine.arguments.contains("--demo")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        camera.refresh()
        createMenu()
        createWindow()
        NSApp.dockTile.contentView = dockMeter
        timer = Timer(timeInterval: 1.0 / 30.0, target: self,
                      selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        showWindow()
        if demo {
            refreshLabels()
        } else if UserDefaults.standard.bool(forKey: "hasStarted") {
            audio.start()
        }
    }

    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DockVU", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show meters", action: #selector(showWindow), keyEquivalent: "1").target = self
        appMenu.addItem(withTitle: "Start / pause audio", action: #selector(toggleMonitoring), keyEquivalent: "p").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide DockVU", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DockVU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    private func createWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 585), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "DockVU"
        window.isReleasedWhenClosed = false
        window.center()
        let title = NSTextField(labelWithString: "Sound & camera, at a glance.")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "MIC  /  OUTPUT L + R  /  CAMERA")
        subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        subtitle.textColor = .secondaryLabelColor
        [inputLabel, outputLabel, cameraLabel].forEach {
            $0.font = .systemFont(ofSize: 12)
            $0.lineBreakMode = .byTruncatingMiddle
            $0.alignment = .center
            $0.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true
        }
        cameraLabel.toolTip = "Red: a camera is in use. Gray: idle. Amber: activity could not be checked. Camera status stays on when audio is paused."
        let inputSensitivityRow = makeSensitivityRow(
            title: "Input sensitivity",
            popup: inputSensitivityPopup,
            selection: inputSensitivity,
            action: #selector(changeInputSensitivity)
        )
        let outputSensitivityRow = makeSensitivityRow(
            title: "Output sensitivity",
            popup: outputSensitivityPopup,
            selection: outputSensitivity,
            action: #selector(changeOutputSensitivity)
        )
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = 326
        statusLabel.widthAnchor.constraint(equalToConstant: 326).isActive = true
        toggle.target = self
        toggle.action = #selector(toggleMonitoring)
        toggle.bezelStyle = .rounded
        toggle.controlSize = .large
        let privacy = NSButton(title: "Audio permissions…", target: self, action: #selector(openPrivacy))
        privacy.bezelStyle = .inline
        privacy.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [title, subtitle, windowMeter, inputLabel, outputLabel, cameraLabel, inputSensitivityRow, outputSensitivityRow, statusLabel, toggle, privacy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        windowMeter.widthAnchor.constraint(equalToConstant: 176).isActive = true
        windowMeter.heightAnchor.constraint(equalToConstant: 176).isActive = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor)
        ])
        refreshLabels()
    }

    private func makeSensitivityRow(
        title: String,
        popup: NSPopUpButton,
        selection: MeterSensitivity,
        action: Selector
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        popup.addItems(withTitles: MeterSensitivity.allCases.map(\.title))
        popup.selectItem(withTitle: selection.title)
        popup.target = self
        popup.action = action
        popup.controlSize = .small
        popup.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        if !demo { audio.refreshDeviceLevels(now: now) }
        if now - lastCameraRefresh >= 1 {
            camera.refresh()
            lastCameraRefresh = now
        }
        let cue: CameraCue = camera.isActive ? .active : camera.hasUnknownState ? .unknown : .idle
        dockMeter.cameraCue = cue
        windowMeter.cameraCue = cue
        let nextState = "\(audio.inputName)|\(audio.outputName)|\(audio.status)|\(audio.isRunning)|\(demo)|\(camera.status)"
        if nextState != labelState {
            labelState = nextState
            refreshLabels()
        }
        let levels: [Float]
        if demo {
            let time = Date.timeIntervalSinceReferenceDate
            levels = (0..<3).map { index in
                let frequency = 1.6 + Double(index) * 0.3
                let wave = sin(time * frequency + Double(index))
                let decibels = -26.0 + 23.0 * wave
                return Float(pow(10.0, decibels / 20.0))
            }
        } else {
            levels = [audio.inputLevel, audio.outputLeftLevel, audio.outputRightLevel]
        }
        let displayedLevels = [
            levels[0] * inputSensitivity.gain,
            levels[1] * outputSensitivity.gain,
            levels[2] * outputSensitivity.gain
        ]
        dockMeter.update(displayedLevels, active: demo || audio.isRunning)
        windowMeter.update(displayedLevels, active: demo || audio.isRunning)
        NSApp.dockTile.display()
    }

    @objc private func changeInputSensitivity() {
        guard MeterSensitivity.allCases.indices.contains(inputSensitivityPopup.indexOfSelectedItem) else { return }
        inputSensitivity = MeterSensitivity.allCases[inputSensitivityPopup.indexOfSelectedItem]
        UserDefaults.standard.set(inputSensitivity.rawValue, forKey: "inputSensitivity")
        resetMeterPeaksAndRefresh()
    }

    @objc private func changeOutputSensitivity() {
        guard MeterSensitivity.allCases.indices.contains(outputSensitivityPopup.indexOfSelectedItem) else { return }
        outputSensitivity = MeterSensitivity.allCases[outputSensitivityPopup.indexOfSelectedItem]
        UserDefaults.standard.set(outputSensitivity.rawValue, forKey: "outputSensitivity")
        resetMeterPeaksAndRefresh()
    }

    private func resetMeterPeaksAndRefresh() {
        dockMeter.peaks = [0, 0, 0]
        windowMeter.peaks = [0, 0, 0]
        refresh()
    }

    private func refreshLabels() {
        inputLabel.stringValue = "Input · \(audio.inputName)"
        outputLabel.stringValue = "Output · \(audio.outputName)"
        cameraLabel.stringValue = "Camera · \(camera.status)"
        cameraLabel.textColor = camera.isActive ? .systemRed : camera.hasUnknownState ? .systemOrange : .secondaryLabelColor
        statusLabel.stringValue = demo ? "Demo levels · no audio is being captured" : audio.isRunning ? audio.status : "\(audio.status)\nLive levels stay in your Dock when you close this window."
        toggle.title = demo ? "Start real audio" : audio.isRunning ? "Pause audio" : "Start audio"
    }

    @objc private func toggleMonitoring() {
        if audio.isRunning {
            audio.stop()
        } else {
            demo = false
            UserDefaults.standard.set(true, forKey: "hasStarted")
            audio.start()
        }
        refreshLabels()
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show meters", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: audio.isRunning ? "Pause audio" : "Start audio", action: #selector(toggleMonitoring), keyEquivalent: "").target = self
        let cameraItem = NSMenuItem(title: "Camera · \(camera.status)", action: nil, keyEquivalent: "")
        menu.addItem(cameraItem)
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        audio.stop()
    }
}

@main
enum DockVU {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
