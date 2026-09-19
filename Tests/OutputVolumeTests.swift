import CoreAudio
import Foundation

private struct PropertyKey: Hashable {
    let deviceID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement
}

private final class FakePropertyReader: AudioPropertyReading {
    var floats: [PropertyKey: Float32] = [:]
    var uints: [PropertyKey: UInt32] = [:]

    func setFloat(
        _ value: Float32,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        floats[PropertyKey(deviceID: 42, selector: selector, scope: scope, element: element)] = value
    }

    func setUInt(
        _ value: UInt32,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        uints[PropertyKey(deviceID: 42, selector: selector, scope: scope, element: element)] = value
    }

    func floatValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        floats[PropertyKey(deviceID: deviceID, selector: selector, scope: scope, element: element)]
    }

    func uintValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        uints[PropertyKey(deviceID: deviceID, selector: selector, scope: scope, element: element)]
    }
}

private func expectClose(
    _ actual: Float,
    _ expected: Float,
    accuracy: Float = 0.0001,
    _ message: String
) {
    precondition(abs(actual - expected) <= accuracy, "\(message): got \(actual), expected \(expected)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func runDeterministicTests() {
    do {
        let reader = FakePropertyReader()
        reader.setFloat(-6, kAudioDevicePropertyVolumeDecibels)
        reader.setFloat(0.9, kAudioDevicePropertyVolumeScalar)
        let gain = OutputVolume(reader: reader).gains(deviceID: 42)
        let expected = Float(pow(10.0, -6.0 / 20.0))
        expectClose(gain.left, expected, "main dB gain should drive left")
        expectClose(gain.right, expected, "main dB gain should drive right")
    }

    do {
        let reader = FakePropertyReader()
        reader.setFloat(780.8003, kAudioDevicePropertyVolumeDecibels)
        reader.setFloat(0.625, kAudioDevicePropertyVolumeScalar)
        let gain = OutputVolume(reader: reader).gains(deviceID: 42)
        expectClose(gain.left, 0.625, "implausible device dB should fall back to scalar")
        expectClose(gain.right, 0.625, "broken-driver dB should not publish infinity")
    }

    do {
        let reader = FakePropertyReader()
        reader.setFloat(0.25, kAudioDevicePropertyVolumeScalar, element: 1)
        reader.setFloat(0.75, kAudioDevicePropertyVolumeScalar, element: 2)
        let gain = OutputVolume(reader: reader).gains(deviceID: 42)
        expectClose(gain.left, 0.25, "channel scalar should drive left without main volume")
        expectClose(gain.right, 0.75, "channel scalar should drive right without main volume")
    }

    do {
        let reader = FakePropertyReader()
        reader.setFloat(-12, kAudioDevicePropertyVolumeDecibels, element: 1)
        reader.setFloat(0.8, kAudioDevicePropertyVolumeScalar, element: 2)
        reader.setUInt(1, kAudioDevicePropertyMute, element: 1)
        let gain = OutputVolume(reader: reader).gains(deviceID: 42)
        expectClose(gain.left, 0, "left channel mute should silence left")
        expectClose(gain.right, 0.8, "left channel mute should not silence right")
    }

    do {
        let reader = FakePropertyReader()
        reader.setFloat(0.8, kAudioDevicePropertyVolumeScalar)
        reader.setUInt(1, kAudioDevicePropertyMute)
        let gain = OutputVolume(reader: reader).gains(deviceID: 42)
        expect(gain == .init(left: 0, right: 0), "main mute should silence both channels")
    }

    do {
        let gain = OutputVolume(reader: FakePropertyReader()).gains(deviceID: 42)
        expect(gain == .unity, "unsupported output controls should use unity gain")
    }

    do {
        let reader = FakePropertyReader()
        reader.setFloat(
            0.2,
            kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeInput
        )
        let volume = OutputVolume(reader: reader)
        expectClose(
            volume.inputAudibility(deviceID: 42),
            1,
            "input hardware gain must not be applied a second time"
        )

        reader.setUInt(
            1,
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput,
            element: 1
        )
        expectClose(
            volume.inputAudibility(deviceID: 42),
            1,
            "one muted input channel must not silence other channels"
        )
        reader.setUInt(
            1,
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput
        )
        expectClose(volume.inputAudibility(deviceID: 42), 0, "main input mute should silence input")
    }
}

private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
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

private func printRawControls(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) {
    let reader = CoreAudioPropertyReader()
    for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
        let decibels = reader.floatValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeDecibels,
            scope: scope,
            element: element
        )
        let scalar = reader.floatValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: element
        )
        let mute = reader.uintValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: element
        )
        print("  element \(element): dB=\(String(describing: decibels)) scalar=\(String(describing: scalar)) mute=\(String(describing: mute))")
    }
}

@main
private enum OutputVolumeTestRunner {
    static func main() {
        runDeterministicTests()
        print("Output volume tests passed")

        guard CommandLine.arguments.contains("--live") else { return }
        let volume = OutputVolume()
        if let outputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice) {
            print("Raw output controls for device \(outputID):")
            printRawControls(deviceID: outputID, scope: kAudioDevicePropertyScopeOutput)
            let gain = volume.gains(deviceID: outputID)
            print("Live default output \(outputID): left gain \(gain.left), right gain \(gain.right)")
        } else {
            print("Live default output: unavailable")
        }
        if let inputID = defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice) {
            print("Raw input controls for device \(inputID):")
            printRawControls(deviceID: inputID, scope: kAudioDevicePropertyScopeInput)
            print("Live default input \(inputID): audibility \(volume.inputAudibility(deviceID: inputID))")
        } else {
            print("Live default input: unavailable")
        }
    }
}
