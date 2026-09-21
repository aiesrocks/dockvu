import AVFoundation
import AudioToolbox
import Combine
import CoreAudio
import Foundation

/// Publishes display-ready peak levels for the current microphone and system output.
///
/// Audio is inspected in memory and immediately discarded. Nothing is recorded or written to disk.
@MainActor
final class AudioMonitor: NSObject, ObservableObject {
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLeftLevel: Float = 0
    @Published private(set) var outputRightLevel: Float = 0

    @Published private(set) var inputName = "Default Input"
    @Published private(set) var outputName = "Default Output"
    @Published private(set) var status = "Stopped"
    @Published private(set) var isRunning = false

    private let microphone = MicrophoneCapture()
    private var inputIsActive = false
    private var outputIsActive = false
    private var wantsToRun = false
    private var inputError: String?
    private var outputError: String?

    private let deviceVolume = OutputVolume()
    private var rawInputLevel: Float = 0
    private var rawOutputLeftLevel: Float = 0
    private var rawOutputRightLevel: Float = 0
    private var outputGain = OutputVolume.StereoGain.unity
    private var inputAudibility: Float = 1
    private var inputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastDeviceLevelRefresh: TimeInterval = -.infinity
    private var inputCaptureGeneration: UInt64 = 0
    private var outputCaptureGeneration: UInt64 = 0

    private var tapDescription: CATapDescription?
    private var processTapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var outputIOProcID: AudioDeviceIOProcID?
    private let outputQueue = DispatchQueue(label: "app.dockvu.output-meter", qos: .userInteractive)

    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private let captureMailbox = AudioCaptureMailbox()
    private let deviceListenerQueue = DispatchQueue(label: "app.dockvu.device-changes")
    private var captureSession: UInt64 = 0
    private var inputRestartAt: TimeInterval?
    private var outputRestartAt: TimeInterval?

    override init() {
        super.init()
        refreshDeviceNames()
    }

    func start() {
        guard !wantsToRun else { return }
        wantsToRun = true
        inputRestartAt = nil
        outputRestartAt = nil
        inputError = nil
        outputError = nil
        status = "Requesting audio permissions…"
        captureSession = captureMailbox.beginSession()
        installDeviceListeners()

        // Creating the process tap is the system-provided request for System Audio Recording
        // permission. Core Audio does not expose a separate preflight/request API for this access.
        do {
            try startOutputTap()
            outputIsActive = true
        } catch {
            outputIsActive = false
            outputError = "System audio unavailable: \(error.localizedDescription)"
        }
        refreshRunningState()

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startInput()
        case .notDetermined:
            let mailbox = captureMailbox
            let session = captureSession
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                mailbox.microphonePermission(granted, session: session)
            }
        case .denied, .restricted:
            inputIsActive = false
            inputError = "Microphone access denied"
            refreshRunningState()
        @unknown default:
            inputIsActive = false
            inputError = "Microphone permission unavailable"
            refreshRunningState()
        }
    }

    func stop() {
        guard wantsToRun || isRunning else { return }
        wantsToRun = false
        inputRestartAt = nil
        outputRestartAt = nil
        captureSession = captureMailbox.beginSession()
        removeDeviceListeners()
        stopInput()
        stopOutputTap()

        inputIsActive = false
        outputIsActive = false
        inputLevel = 0
        outputLeftLevel = 0
        outputRightLevel = 0
        resetDeviceLevels()
        isRunning = false
        status = "Stopped"
    }

    /// Polls hardware controls off the real-time audio threads and reapplies them to the most
    /// recent raw peaks. The latter makes a volume or mute change visible even during silence.
    func refreshDeviceLevels(now: TimeInterval) {
        guard wantsToRun else { return }
        processCaptureEvents(now: now)
        let levels = captureMailbox.levels(now: now)
        rawInputLevel = levels.input
        rawOutputLeftLevel = levels.left
        rawOutputRightLevel = levels.right
        guard now - lastDeviceLevelRefresh >= 0.1 else {
            applyDeviceLevels()
            return
        }
        lastDeviceLevelRefresh = now

        if inputDeviceID != kAudioObjectUnknown {
            inputAudibility = deviceVolume.inputAudibility(deviceID: inputDeviceID)
        } else {
            inputAudibility = 1
        }
        if outputDeviceID != kAudioObjectUnknown {
            outputGain = deviceVolume.gains(deviceID: outputDeviceID)
        } else {
            outputGain = .unity
        }
        applyDeviceLevels()
    }

    func diagnostics() -> String {
        let counts = captureMailbox.callbackCounts()
        return "inputCallbacks=\(counts.input) outputCallbacks=\(counts.output) inputGeneration=\(inputCaptureGeneration) outputGeneration=\(outputCaptureGeneration) inputDevice=\(inputDeviceID) outputDevice=\(outputDeviceID) input=\(inputLevel) left=\(outputLeftLevel) right=\(outputRightLevel) status=\(status)"
    }

    // MARK: - Microphone

    private func startInput() {
        guard wantsToRun, !inputIsActive else { return }
        inputCaptureGeneration &+= 1
        let generation = inputCaptureGeneration
        let session = captureSession
        let mailbox = captureMailbox
        mailbox.resetInput(generation: generation)

        do {
            // Native setup contains Objective-C exceptions before they can unwind this timer.
            // Every attempt owns a fresh engine and negotiates the current hardware format.
            try microphone.start(levelHandler: { level in
                mailbox.publishInput(level, generation: generation,
                                     now: ProcessInfo.processInfo.systemUptime)
            }, configurationChangeHandler: {
                mailbox.inputConfigurationChanged(generation: generation, session: session)
            })
            inputIsActive = true
            inputDeviceID = microphone.deviceID
            if inputDeviceID == kAudioObjectUnknown {
                inputDeviceID = Self.defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
                    ?? AudioObjectID(kAudioObjectUnknown)
            }
            lastDeviceLevelRefresh = -.infinity
            inputError = nil
            refreshDeviceNames()
            refreshRunningState()
        } catch {
            stopInput()
            inputError = "Microphone unavailable: \(error.localizedDescription)"
            refreshRunningState()
            // Hardware may still be settling after a disconnect/rate change. Retry at a
            // bounded rate while monitoring remains requested; output continues meanwhile.
            if wantsToRun { inputRestartAt = ProcessInfo.processInfo.systemUptime + 1 }
        }
    }

    private func stopInput() {
        inputCaptureGeneration &+= 1
        captureMailbox.resetInput(generation: inputCaptureGeneration)
        microphone.stop()
        inputIsActive = false
        rawInputLevel = 0
        inputLevel = 0
        inputAudibility = 1
        inputDeviceID = AudioObjectID(kAudioObjectUnknown)
        lastDeviceLevelRefresh = -.infinity
    }

    /// Runs on the selector timer, independently of main dispatch/Swift task delivery.
    private func processCaptureEvents(now: TimeInterval) {
        let events = captureMailbox.takeEvents()
        if let granted = events.microphonePermission {
            if granted {
                startInput()
            } else {
                inputError = "Microphone access denied"
                refreshRunningState()
            }
        }
        guard wantsToRun else { return }
        if events.inputChanged || events.outputChanged { refreshDeviceNames() }
        if events.inputChanged,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            inputRestartAt = now + 0.25
        }
        if events.outputChanged { outputRestartAt = now + 0.25 }
        if let deadline = inputRestartAt, now >= deadline {
            inputRestartAt = nil
            stopInput()
            startInput()
        }
        if let deadline = outputRestartAt, now >= deadline {
            outputRestartAt = nil
            stopOutputTap()
            do {
                try startOutputTap()
                outputIsActive = true
                outputError = nil
            } catch {
                outputIsActive = false
                outputError = "System audio unavailable: \(error.localizedDescription)"
            }
            refreshRunningState()
        }
    }

    // MARK: - System output

    @available(macOS 14.2, *)
    private func createOutputTap() throws {
        guard processTapID == kAudioObjectUnknown else { return }

        guard let selectedOutputDeviceID = Self.defaultDeviceID(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ), let outputUID = Self.deviceUID(deviceID: selectedOutputDeviceID) else {
            throw MonitorError.noDefaultOutput
        }
        outputDeviceID = selectedOutputDeviceID
        lastDeviceLevelRefresh = -.infinity
        outputCaptureGeneration &+= 1
        let captureGeneration = outputCaptureGeneration
        let mailbox = captureMailbox
        mailbox.resetOutput(generation: captureGeneration)
        let description = CATapDescription(
            excludingProcesses: [],
            deviceUID: outputUID,
            stream: 0
        )
        description.name = "DockVu System Output"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            operation: "create the system audio tap"
        )
        processTapID = newTapID
        tapDescription = description

        do {
            let tapFormat = try Self.audioFormat(forTap: newTapID)
            guard tapFormat.mFormatID == kAudioFormatLinearPCM,
                  tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  tapFormat.mBitsPerChannel == 32 else {
                throw MonitorError.unsupportedOutputFormat
            }

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "DockVu Output Monitor",
                kAudioAggregateDeviceUIDKey: "app.dockvu.monitor.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
                operation: "create the output meter device"
            )
            aggregateDeviceID = newAggregateID

            var newIOProcID: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &newIOProcID,
                    newAggregateID,
                    outputQueue
                ) { _, inputData, _, _, _ in
                    let levels = Self.stereoPeakLevels(in: inputData)
                    mailbox.publishOutput(left: levels.left, right: levels.right,
                                          generation: captureGeneration,
                                          now: ProcessInfo.processInfo.systemUptime)
                },
                operation: "connect the output meter"
            )
            outputIOProcID = newIOProcID

            try Self.check(
                AudioDeviceStart(newAggregateID, newIOProcID),
                operation: "start the output meter"
            )
            refreshDeviceNames()
        } catch {
            stopOutputTap()
            throw error
        }
    }

    private func startOutputTap() throws {
        guard #available(macOS 14.2, *) else {
            throw MonitorError.unsupportedSystem
        }
        try createOutputTap()
    }

    private func stopOutputTap() {
        outputCaptureGeneration &+= 1
        captureMailbox.resetOutput(generation: outputCaptureGeneration)
        if aggregateDeviceID != kAudioObjectUnknown, let outputIOProcID {
            AudioDeviceStop(aggregateDeviceID, outputIOProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, outputIOProcID)
        }
        outputIOProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if processTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(processTapID)
            }
            processTapID = kAudioObjectUnknown
        }
        tapDescription = nil
        outputIsActive = false
        rawOutputLeftLevel = 0
        rawOutputRightLevel = 0
        outputLeftLevel = 0
        outputRightLevel = 0
        outputGain = .unity
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        lastDeviceLevelRefresh = -.infinity
    }

    // MARK: - Device changes and display state

    private func installDeviceListeners() {
        guard defaultDeviceListener == nil else { return }

        let mailbox = captureMailbox
        let session = captureSession
        let listener: AudioObjectPropertyListenerBlock = { count, addresses in
            var inputChanged = false
            var outputChanged = false
            for index in 0..<Int(count) {
                inputChanged = inputChanged
                    || addresses[index].mSelector == kAudioHardwarePropertyDefaultInputDevice
                outputChanged = outputChanged
                    || addresses[index].mSelector == kAudioHardwarePropertyDefaultOutputDevice
            }
            mailbox.deviceChanged(input: inputChanged, output: outputChanged, session: session)
        }
        defaultDeviceListener = listener

        var inputAddress = Self.defaultDeviceAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
        var outputAddress = Self.defaultDeviceAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectAddPropertyListenerBlock(systemObject, &inputAddress, deviceListenerQueue, listener)
        AudioObjectAddPropertyListenerBlock(systemObject, &outputAddress, deviceListenerQueue, listener)
    }

    private func removeDeviceListeners() {
        guard let listener = defaultDeviceListener else { return }
        var inputAddress = Self.defaultDeviceAddress(selector: kAudioHardwarePropertyDefaultInputDevice)
        var outputAddress = Self.defaultDeviceAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(systemObject, &inputAddress, deviceListenerQueue, listener)
        AudioObjectRemovePropertyListenerBlock(systemObject, &outputAddress, deviceListenerQueue, listener)
        defaultDeviceListener = nil
    }

    private func refreshDeviceNames() {
        inputName = Self.defaultDeviceName(selector: kAudioHardwarePropertyDefaultInputDevice)
            ?? "Default Input"
        outputName = Self.defaultDeviceName(selector: kAudioHardwarePropertyDefaultOutputDevice)
            ?? "Default Output"
    }

    private func refreshRunningState() {
        isRunning = inputIsActive || outputIsActive
        switch (inputIsActive, outputIsActive) {
        case (true, true):
            status = "Monitoring input and output"
        case (true, false):
            status = outputError.map { "Monitoring input only. \($0)" }
                ?? "Monitoring input; system audio unavailable"
        case (false, true):
            status = inputError.map { "Monitoring output only. \($0)" }
                ?? "Monitoring output; microphone unavailable"
        case (false, false):
            status = [inputError, outputError].compactMap { $0 }.joined(separator: ". ")
            if status.isEmpty { status = "Audio monitoring unavailable" }
            if inputError != nil, outputError != nil {
                wantsToRun = false
                inputRestartAt = nil
                outputRestartAt = nil
                removeDeviceListeners()
            }
        }
    }

    private func applyDeviceLevels() {
        inputLevel = min(1, rawInputLevel * inputAudibility)
        outputLeftLevel = min(1, rawOutputLeftLevel * outputGain.left)
        outputRightLevel = min(1, rawOutputRightLevel * outputGain.right)
    }

    private func resetDeviceLevels() {
        rawInputLevel = 0
        rawOutputLeftLevel = 0
        rawOutputRightLevel = 0
        outputGain = .unity
        inputAudibility = 1
        inputDeviceID = AudioObjectID(kAudioObjectUnknown)
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        lastDeviceLevelRefresh = -.infinity
    }

    // MARK: - Audio helpers

    nonisolated static func stereoPeakLevels(
        in audioBufferList: UnsafePointer<AudioBufferList>
    ) -> (left: Float, right: Float) {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        guard !buffers.isEmpty else { return (0, 0) }

        var leftPeak: Float = 0
        var rightPeak: Float = 0

        if buffers.count >= 2 {
            leftPeak = linearPeak(in: buffers[0], channel: 0)
            rightPeak = linearPeak(in: buffers[1], channel: 0)
        } else {
            let buffer = buffers[0]
            let channelCount = max(1, Int(buffer.mNumberChannels))
            leftPeak = linearPeak(in: buffer, channel: 0)
            rightPeak = channelCount > 1
                ? linearPeak(in: buffer, channel: 1)
                : leftPeak
        }

        return (min(1, leftPeak), min(1, rightPeak))
    }

    nonisolated private static func linearPeak(in buffer: AudioBuffer, channel: Int) -> Float {
        guard let data = buffer.mData else { return 0 }
        let channelCount = max(1, Int(buffer.mNumberChannels))
        guard channel < channelCount else { return 0 }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride
        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return 0 }

        let samples = data.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for frame in 0..<frameCount {
            let magnitude = abs(samples[(frame * channelCount) + channel])
            if magnitude.isFinite { peak = max(peak, magnitude) }
        }
        return peak
    }

    nonisolated private static func audioFormat(
        forTap tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            operation: "read the output audio format"
        )
        return format
    }

    nonisolated private static func defaultDeviceAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func defaultDeviceName(
        selector: AudioObjectPropertySelector
    ) -> String? {
        guard let deviceID = defaultDeviceID(selector: selector) else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &size,
            &deviceName
        ) == noErr else {
            return nil
        }
        guard let deviceName else { return nil }
        return deviceName.takeRetainedValue() as String
    }

    nonisolated private static func deviceUID(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceUID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &deviceUID
        ) == noErr else {
            return nil
        }
        guard let deviceUID else { return nil }
        return deviceUID.takeRetainedValue() as String
    }

    nonisolated private static func defaultDeviceID(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectID? {
        var address = defaultDeviceAddress(selector: selector)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    nonisolated private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw MonitorError.coreAudio(operation: operation, status: status)
        }
    }
}

private enum MonitorError: LocalizedError {
    case unsupportedSystem
    case noDefaultOutput
    case unsupportedOutputFormat
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem:
            return "System audio monitoring requires macOS 14.2 or newer."
        case .noDefaultOutput:
            return "No default output device is available."
        case .unsupportedOutputFormat:
            return "The default output uses an unsupported audio format."
        case let .coreAudio(operation, status):
            let code = UInt32(bitPattern: status)
            let bytes: [UInt8] = [
                UInt8((code >> 24) & 0xff),
                UInt8((code >> 16) & 0xff),
                UInt8((code >> 8) & 0xff),
                UInt8(code & 0xff),
            ]
            let printable = bytes.allSatisfy { (32...126).contains($0) }
            let detail = printable ? "'\(String(bytes: bytes, encoding: .ascii) ?? "?")'" : "\(status)"
            return "Could not \(operation) (Core Audio \(detail))."
        }
    }
}
