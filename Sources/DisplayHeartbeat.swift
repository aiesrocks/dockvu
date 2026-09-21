import Foundation

/// A tiny, overwritten health record lets the hourly check distinguish a frozen UI
/// from a healthy process with low memory. No audio samples are written.
@MainActor
final class DisplayHeartbeat {
    private var lastWrite: TimeInterval = -.infinity
    private let url: URL

    init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.dockvu.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("health.json")
    }

    func record(now: TimeInterval) {
        guard now - lastWrite >= 5 else { return }
        let record: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "last_refresh": Date().timeIntervalSince1970
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: url, options: .atomic)
            lastWrite = now
        } catch {
            // Do not retry every display frame if cache storage is unavailable.
            lastWrite = now
            NSLog("DockVU could not write display heartbeat: %@", error.localizedDescription)
        }
    }
}
