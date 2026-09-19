import Foundation

/// Display gain only; never changes audio capture or a device's volume setting.
enum MeterSensitivity: String, CaseIterable {
    case low, normal, high

    var title: String { rawValue.capitalized }

    var gain: Float {
        switch self {
        case .low: return 0.5
        case .normal: return 1
        case .high: return 2
        }
    }
}
