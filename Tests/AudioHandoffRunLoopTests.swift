import AppKit
import Foundation

@MainActor
private final class Harness: NSObject {
    private let mailbox = AudioCaptureMailbox()
    private var timer: Timer?
    private var producer: DispatchSourceTimer?
    private var deliveredTasks = 0
    private var taskCountAtHoldStart = 0
    private var tasksDeliveredDuringHold = 0
    private var holdActive = false
    private var markerRanDuringHold = false
    private var ticksDuringHold = 0
    private var firstSequenceDuringHold: UInt64?
    private var lastSequenceDuringHold: UInt64 = 0

    func run() {
        timer = Timer(timeInterval: 1.0 / 30.0, target: self,
                      selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)

        let mailbox = mailbox
        let producer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mailbox.producer"))
        var sequence: UInt64 = 0
        producer.schedule(deadline: .now(), repeating: .milliseconds(1))
        producer.setEventHandler { [self] in
            sequence &+= 1
            mailbox.publishInput(Float(sequence), generation: 0,
                                 now: ProcessInfo.processInfo.systemUptime)
            mailbox.publishOutput(left: Float(sequence), right: Float(sequence), generation: 0,
                                  now: ProcessInfo.processInfo.systemUptime)
            // The old per-buffer handoff cannot deliver during the held-main-queue repro.
            Task { @MainActor in self.deliveredTasks += 1 }
        }
        producer.resume()
        self.producer = producer

        DispatchQueue.main.async { [self] in
            holdActive = true
            taskCountAtHoldStart = deliveredTasks
            DispatchQueue.main.async { [self] in
                if holdActive { markerRanDuringHold = true }
            }

            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            tasksDeliveredDuringHold = deliveredTasks - taskCountAtHoldStart
            holdActive = false

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                finish()
            }
        }
    }

    @objc private func tick() {
        guard holdActive else { return }
        let snapshot = mailbox.levels(now: ProcessInfo.processInfo.systemUptime)
        precondition(snapshot.left == snapshot.right)
        ticksDuringHold += 1
        if firstSequenceDuringHold == nil { firstSequenceDuringHold = UInt64(snapshot.left) }
        lastSequenceDuringHold = UInt64(snapshot.left)
    }

    private func finish() {
        timer?.invalidate()
        producer?.cancel()
        let first = firstSequenceDuringHold ?? 0
        let advanced = lastSequenceDuringHold > first
        let passed = ticksDuringHold >= 20 && advanced && !markerRanDuringHold && tasksDeliveredDuringHold == 0
        print("ticks=\(ticksDuringHold) first=\(first) last=\(lastSequenceDuringHold) markerDuringHold=\(markerRanDuringHold) oldTasksDelivered=\(tasksDeliveredDuringHold)")
        print(passed ? "PASS" : "FAIL")
        exit(passed ? 0 : 1)
    }
}

@main
private enum Main {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let harness = Harness()
        harness.run()
        withExtendedLifetime(harness) { app.run() }
    }
}
