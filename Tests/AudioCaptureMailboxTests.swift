import Foundation

@main enum AudioCaptureMailboxTests {
    static func main() {
        let mailbox = AudioCaptureMailbox()
        mailbox.resetInput(generation: 1)
        mailbox.resetOutput(generation: 1)
        // Simulate a stalled UI while both capture callbacks continue for millions of buffers.
        DispatchQueue.concurrentPerform(iterations: 2) { producer in
            for index in 0..<1_000_000 {
                let value = Float(index % 100) / 100
                if producer == 0 {
                    mailbox.publishInput(value, generation: 1, now: 10)
                } else {
                    mailbox.publishOutput(left: value, right: value / 2, generation: 1, now: 10)
                }
            }
        }
        var levels = mailbox.levels(now: 10)
        precondition(levels.input == 0.99 && levels.left == 0.99 && levels.right == 0.495)
        levels = mailbox.levels(now: 11)
        precondition(levels.input == 0 && levels.left == 0 && levels.right == 0)

        mailbox.resetInput(generation: 2)
        mailbox.resetOutput(generation: 2)
        mailbox.publishInput(0.25, generation: 2, now: 20)
        mailbox.publishOutput(left: 0.5, right: 0.75, generation: 2, now: 20)
        // A late old callback cannot overwrite the new session's values.
        mailbox.publishInput(1, generation: 1, now: 20)
        mailbox.publishOutput(left: 1, right: 1, generation: 1, now: 20)
        levels = mailbox.levels(now: 20)
        precondition(levels.input == 0.25 && levels.left == 0.5 && levels.right == 0.75)
        mailbox.resetInput(generation: 3)
        precondition(mailbox.levels(now: 20).input == 0)
        precondition(mailbox.levels(now: 20).left == 0.5)

        let session = mailbox.beginSession()
        mailbox.inputConfigurationChanged(generation: 2, session: session)
        precondition(!mailbox.takeEvents().inputChanged, "discard retired engine notifications")
        mailbox.inputConfigurationChanged(generation: 3, session: session)
        precondition(mailbox.takeEvents().inputChanged, "accept current engine notifications")
        mailbox.deviceChanged(input: true, output: false, session: session)
        mailbox.deviceChanged(input: false, output: true, session: session)
        mailbox.microphonePermission(true, session: session)
        let events = mailbox.takeEvents()
        precondition(events.inputChanged && events.outputChanged && events.microphonePermission == true)
        precondition(!mailbox.takeEvents().inputChanged)
        _ = mailbox.beginSession()
        mailbox.deviceChanged(input: true, output: true, session: session)
        mailbox.microphonePermission(true, session: session)
        let stale = mailbox.takeEvents()
        precondition(!stale.inputChanged && !stale.outputChanged && stale.microphonePermission == nil)

        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            for index in 0..<100_000 {
                if worker == 0 {
                    let value = Float(index % 100) / 100
                    mailbox.publishOutput(left: value, right: value / 2, generation: 2, now: 30)
                } else {
                    let pair = mailbox.levels(now: 30)
                    precondition(pair.right == pair.left / 2)
                }
            }
        }
        print("PASS: bounded callback handoff, freshness, generation isolation, event coalescing, concurrent stereo reads")
    }
}
