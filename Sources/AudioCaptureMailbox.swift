import Foundation
import os

/// A bounded handoff from capture/device callbacks to the display timer.
/// No audio buffers or queued work survive a callback; a newer peak replaces the old one.
final class AudioCaptureMailbox: @unchecked Sendable {
    struct Sample {
        var generation: UInt64 = 0
        var left: Float = 0
        var right: Float = 0
        var time: TimeInterval = -.infinity
    }

    struct Events {
        var inputChanged = false
        var outputChanged = false
        var microphonePermission: Bool?
    }

    private struct State {
        var input = Sample()
        var output = Sample()
        var events = Events()
        var inputCount: UInt64 = 0
        var outputCount: UInt64 = 0
        var session: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func resetInput(generation: UInt64) {
        state.withLock { $0.input = Sample(generation: generation) }
    }

    func resetOutput(generation: UInt64) {
        state.withLock { $0.output = Sample(generation: generation) }
    }

    func publishInput(_ level: Float, generation: UInt64, now: TimeInterval) {
        state.withLock {
            guard $0.input.generation == generation else { return }
            $0.inputCount &+= 1
            $0.input = Sample(generation: generation, left: level, right: level, time: now)
        }
    }

    func publishOutput(left: Float, right: Float, generation: UInt64, now: TimeInterval) {
        state.withLock {
            guard $0.output.generation == generation else { return }
            $0.outputCount &+= 1
            $0.output = Sample(generation: generation, left: left, right: right, time: now)
        }
    }

    func levels(now: TimeInterval) -> (input: Float, left: Float, right: Float) {
        state.withLock {
            // A stopped capture must not leave its last nonzero sample on screen forever.
            let inputFresh = now - $0.input.time <= 0.5
            let outputFresh = now - $0.output.time <= 0.5
            return (inputFresh ? $0.input.left : 0,
                    outputFresh ? $0.output.left : 0,
                    outputFresh ? $0.output.right : 0)
        }
    }

    func callbackCounts() -> (input: UInt64, output: UInt64) {
        state.withLock { ($0.inputCount, $0.outputCount) }
    }

    func beginSession() -> UInt64 {
        state.withLock {
            $0.session &+= 1
            $0.events = Events()
            return $0.session
        }
    }

    func deviceChanged(input: Bool, output: Bool, session: UInt64) {
        state.withLock {
            guard $0.session == session else { return }
            $0.events.inputChanged = $0.events.inputChanged || input
            $0.events.outputChanged = $0.events.outputChanged || output
        }
    }

    func inputConfigurationChanged(generation: UInt64, session: UInt64) {
        state.withLock {
            guard $0.session == session, $0.input.generation == generation else { return }
            $0.events.inputChanged = true
        }
    }

    func microphonePermission(_ granted: Bool, session: UInt64) {
        state.withLock {
            guard $0.session == session else { return }
            $0.events.microphonePermission = granted
        }
    }

    func takeEvents() -> Events {
        state.withLock {
            let events = $0.events
            $0.events = Events()
            return events
        }
    }
}
