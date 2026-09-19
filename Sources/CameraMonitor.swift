import CoreMediaIO
import Foundation

/// Passively reports whether any CoreMediaIO camera is already in use.
///
/// This class only reads device properties. It never opens a capture session, starts a
/// device, or requests camera permission.
@MainActor
final class CameraMonitor: NSObject {
    private(set) var isActive = false
    private(set) var hasUnknownState = false
    private(set) var status = "Checking…"
    private(set) var activeNames: [String] = []

    override init() {
        super.init()
        refresh()
    }

    /// Re-enumerates devices so cameras added or removed since the last poll are included.
    func refresh() {
        let result = Self.readCameraObservations()
        let snapshot = Self.evaluate(
            result.observations,
            enumerationFailed: result.enumerationFailed
        )
        isActive = snapshot.isActive
        hasUnknownState = snapshot.hasUnknownState
        activeNames = snapshot.activeNames
        status = snapshot.status
    }

    // MARK: - Snapshot evaluation

    enum Activity: Equatable {
        case active
        case idle
        case unknown
    }

    struct Observation: Equatable {
        let name: String
        let activity: Activity
    }

    struct Snapshot: Equatable {
        let isActive: Bool
        let hasUnknownState: Bool
        let status: String
        let activeNames: [String]
    }

    /// Kept separate from CoreMediaIO reads so precedence can be verified without hardware.
    static func evaluate(
        _ observations: [Observation],
        enumerationFailed: Bool = false
    ) -> Snapshot {
        let activeNames = observations
            .filter { $0.activity == .active }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let unknownNames = observations
            .filter { $0.activity == .unknown }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let hasUnknownState = enumerationFailed || !unknownNames.isEmpty

        if !activeNames.isEmpty {
            let names = activeNames.joined(separator: ", ")
            return Snapshot(
                isActive: true,
                hasUnknownState: hasUnknownState,
                status: "Active · \(names)",
                activeNames: activeNames
            )
        }

        if hasUnknownState {
            let detail = unknownNames.isEmpty
                ? "Unable to check camera activity"
                : "Activity unavailable · \(unknownNames.joined(separator: ", "))"
            return Snapshot(
                isActive: false,
                hasUnknownState: true,
                status: detail,
                activeNames: []
            )
        }

        if observations.isEmpty {
            return Snapshot(
                isActive: false,
                hasUnknownState: false,
                status: "No cameras found",
                activeNames: []
            )
        }

        return Snapshot(
            isActive: false,
            hasUnknownState: false,
            status: "Idle",
            activeNames: []
        )
    }

    // MARK: - CoreMediaIO property reads

    private struct ReadResult {
        var observations: [Observation] = []
        var enumerationFailed = false
    }

    private static func readCameraObservations() -> ReadResult {
        guard let deviceIDs = objectIDArray(
            objectID: CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            scope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
        ) else {
            return ReadResult(observations: [], enumerationFailed: true)
        }

        var result = ReadResult()
        for deviceID in deviceIDs {
            // Cameras supply input streams. Output-only CMIO devices are excluded.
            guard let inputStreams = objectIDArray(
                objectID: deviceID,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
            ) else {
                // A device whose direction cannot be read might be a camera. Preserve that
                // uncertainty instead of reporting an all-clear result.
                result.enumerationFailed = true
                continue
            }
            guard !inputStreams.isEmpty else { continue }

            let name = objectName(deviceID) ?? "Camera \(deviceID)"
            let activity: Activity
            if let running = uint32Property(
                objectID: deviceID,
                selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                scope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
            ) {
                activity = running == 0 ? .idle : .active
            } else {
                activity = .unknown
            }
            result.observations.append(Observation(name: name, activity: activity))
        }
        return result
    }

    private static func objectIDArray(
        objectID: CMIOObjectID,
        selector: CMIOObjectPropertySelector,
        scope: CMIOObjectPropertyScope
    ) -> [CMIOObjectID]? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else { return nil }

        var byteCount: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }
        guard byteCount % UInt32(MemoryLayout<CMIOObjectID>.stride) == 0 else { return nil }
        let count = Int(byteCount) / MemoryLayout<CMIOObjectID>.stride
        guard count > 0 else { return [] }

        var values = Array(repeating: CMIOObjectID(0), count: count)
        var bytesUsed: UInt32 = 0
        let status = values.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                byteCount,
                &bytesUsed,
                bytes.baseAddress!
            )
        }
        guard status == noErr,
              bytesUsed % UInt32(MemoryLayout<CMIOObjectID>.stride) == 0,
              bytesUsed <= byteCount else {
            return nil
        }
        values.removeSubrange((Int(bytesUsed) / MemoryLayout<CMIOObjectID>.stride)..<values.count)
        return values
    }

    private static func uint32Property(
        objectID: CMIOObjectID,
        selector: CMIOObjectPropertySelector,
        scope: CMIOObjectPropertyScope
    ) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else { return nil }
        var value: UInt32 = 0
        var bytesUsed: UInt32 = 0
        let byteCount = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            byteCount,
            &bytesUsed,
            &value
        )
        guard status == noErr, bytesUsed == byteCount else { return nil }
        return value
    }

    private static func objectName(_ objectID: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(objectID, &address) else { return nil }

        var unmanagedName: Unmanaged<CFString>?
        var bytesUsed: UInt32 = 0
        let byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = CMIOObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            byteCount,
            &bytesUsed,
            &unmanagedName
        )
        guard status == noErr, bytesUsed == byteCount, let unmanagedName else { return nil }
        return unmanagedName.takeRetainedValue() as String
    }
}
