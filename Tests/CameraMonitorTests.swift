import Foundation

@main
enum CameraMonitorTests {
    @MainActor
    static func main() {
        verifyEvaluation()

        if CommandLine.arguments.contains("--live") {
            let monitor = CameraMonitor()
            print("active=\(monitor.isActive) unknown=\(monitor.hasUnknownState) status=\(monitor.status)")
        }
    }

    @MainActor
    private static func verifyEvaluation() {
        let activeWins = CameraMonitor.evaluate([
            .init(name: "Idle Camera", activity: .idle),
            .init(name: "Unknown Camera", activity: .unknown),
            .init(name: "Studio Camera", activity: .active),
        ])
        precondition(activeWins.isActive)
        precondition(activeWins.hasUnknownState)
        precondition(activeWins.activeNames == ["Studio Camera"])

        let unknown = CameraMonitor.evaluate([
            .init(name: "Built-in Camera", activity: .unknown),
        ])
        precondition(!unknown.isActive)
        precondition(unknown.hasUnknownState)

        let idle = CameraMonitor.evaluate([
            .init(name: "Built-in Camera", activity: .idle),
        ])
        precondition(!idle.isActive)
        precondition(!idle.hasUnknownState)
        precondition(idle.status == "Idle")

        let noCameras = CameraMonitor.evaluate([])
        precondition(!noCameras.isActive)
        precondition(!noCameras.hasUnknownState)
        precondition(noCameras.status == "No cameras found")

        let failedEnumeration = CameraMonitor.evaluate([], enumerationFailed: true)
        precondition(!failedEnumeration.isActive)
        precondition(failedEnumeration.hasUnknownState)
    }
}
