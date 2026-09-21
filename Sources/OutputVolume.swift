import CoreAudio
import Foundation

/// The Core Audio reads needed to turn a device's volume controls into meter gains.
/// Kept behind a protocol so tests never have to change the machine's audio settings.
protocol AudioPropertyReading {
    func floatValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32?

    func uintValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32?
}

struct CoreAudioPropertyReader: AudioPropertyReading {
    func floatValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size else {
            return nil
        }
        return value
    }

    func uintValue(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else {
            return nil
        }
        return value
    }
}

struct OutputVolume {
    struct StereoGain: Equatable {
        let left: Float
        let right: Float

        static let unity = StereoGain(left: 1, right: 1)
    }

    private let reader: any AudioPropertyReading
    // Consumer output controls normally stay within this range. Finite values outside it are
    // treated as broken-driver sentinels; real devices have reported both +780.8003 dB and
    // -1.437647e+28 dB alongside a valid 0...1 scalar control. Negative infinity remains the
    // Core Audio representation of silence.
    private static let minimumPlausibleDecibels: Float32 = -160
    private static let maximumPlausibleDecibels: Float32 = 60

    init(reader: any AudioPropertyReading = CoreAudioPropertyReader()) {
        self.reader = reader
    }

    /// Reads the effective audible gain for the device output. Core Audio defines element 0
    /// as the main control and elements 1... as channel controls. A main volume wins when
    /// present; otherwise each channel is read separately. Mute controls remain per element.
    func gains(deviceID: AudioObjectID) -> StereoGain {
        let scope = kAudioDevicePropertyScopeOutput
        let main = kAudioObjectPropertyElementMain
        if isMuted(deviceID: deviceID, scope: scope, element: main) {
            return StereoGain(left: 0, right: 0)
        }

        let base: StereoGain
        if let mainGain = volumeGain(deviceID: deviceID, scope: scope, element: main) {
            base = StereoGain(left: mainGain, right: mainGain)
        } else {
            base = StereoGain(
                left: volumeGain(deviceID: deviceID, scope: scope, element: 1) ?? 1,
                right: volumeGain(deviceID: deviceID, scope: scope, element: 2) ?? 1
            )
        }

        return StereoGain(
            left: isMuted(deviceID: deviceID, scope: scope, element: 1) ? 0 : base.left,
            right: isMuted(deviceID: deviceID, scope: scope, element: 2) ? 0 : base.right
        )
    }

    /// AVAudioInputNode delivers samples after the input device's hardware gain. Applying its
    /// volume again would double attenuate the meter, so only hardware mute gates the reading.
    func inputAudibility(deviceID: AudioObjectID) -> Float {
        let scope = kAudioDevicePropertyScopeInput
        let main = kAudioObjectPropertyElementMain
        // Per-channel device gain and mute are already represented in the captured samples.
        // Only a device-wide mute needs an explicit gate for drivers whose tap stays pre-mute.
        return isMuted(deviceID: deviceID, scope: scope, element: main) ? 0 : 1
    }

    private func volumeGain(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        if let decibels = reader.floatValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeDecibels,
            scope: scope,
            element: element
        ), !decibels.isNaN, decibels <= Self.maximumPlausibleDecibels {
            if decibels == -.infinity { return 0 }
            if decibels.isFinite, decibels >= Self.minimumPlausibleDecibels {
                let amplitude = pow(10.0, Double(decibels) / 20.0)
                if amplitude.isFinite, amplitude <= Double(Float.greatestFiniteMagnitude) {
                    return Float(amplitude)
                }
            }
        }

        guard let scalar = reader.floatValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: element
        ), scalar.isFinite else {
            return nil
        }
        return min(1, max(0, scalar))
    }

    private func isMuted(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        reader.uintValue(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: scope,
            element: element
        ).map { $0 != 0 } ?? false
    }
}
