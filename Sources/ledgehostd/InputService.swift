import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// InputService — the input helper's lifecycle and the one serialized
// input stream (phase-1-plan.md decisions 8–10, IPC spec). Only the
// session that most recently selected the desktop injects; on session
// end, helper restart or daemon shutdown its held input is released
// (op 5), and the helper itself releases everything on exit.
//
// Spawn plumbing lives in HelperSupervisor (audit R2/R-5); the input
// POLICY stays here: restarts are unbounded (the helper must come back
// whenever watchers exist), and stop() gives the helper a 2 s window
// to run its release-all exit path before terminate.

final class InputService {
    let loop: EventLoop
    private let supervisor: HelperSupervisor

    var onClipboard: ((String) -> Void)?  // a foreign client's text
    private var running = false
    private var backoff = RestartBackoff()
    private var outputReader = InputRecord.outputReader()

    init(group: EventLoopGroup, display: String, xauthority: String?) {
        self.loop = group.next()
        supervisor = HelperSupervisor(
            loop: loop,
            display: display,
            xauthority: xauthority,
            spec: .init(tag: "input",
                        name: "ledgehost-input",
                        extraEnvironment: {
                            ProcessInfo.processInfo.environment["LH_CLIP_DEBUG"] != nil
                                ? ["LH_CLIP_DEBUG": "1"] : [:]
                        },
                        stopGrace: 2))
        supervisor.onStdoutData = { [weak self] data in self?.feed(data) }
        supervisor.onDied = { [weak self] _ in self?.failed() }
        supervisor.onAttachFailed = { [weak self] in self?.failed() }
    }

    /// Called when the first desktop watcher appears / the last leaves:
    /// the helper runs while anyone watches.
    func watcherJoined() { loop.execute { if !self.running { self.start() } } }
    func watcherLeft(hasWatchers: Bool) {
        loop.execute { if !hasWatchers { self.stop() } }
    }

    func shutdown() { stop() }

    private func start() {
        guard supervisor.start() else { return }
        running = true
    }

    private func stop() {
        running = false
        supervisor.stop()      // 2 s grace: release-all runs on EOF exit
    }

    /// Helper died: it released all held input on the way out; restart
    /// with the shared [1,2,5,10,30] backoff — but forever (input
    /// policy: the helper must return while watchers exist, media's
    /// 5-strike give-up does not apply here).
    private func failed() {
        guard running else { return }
        stop()
        let delay = backoff.nextDelay()
        print(Log.stamp(), "ledgehostd: input: restart \(backoff.attempts) in \(Int(delay)) s")
        loop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) { [weak self] in self?.start() }
    }

    /// One event worth of op records from the injecting session.
    func send(_ records: [Data]) {
        supervisor.send(records.reduce(into: Data()) { $0.append($1) })
    }

    /// op 7: a device's text becomes the host CLIPBOARD selection.
    func setClipboard(_ text: String) { send([InputRecord.clipboard(text)]) }

    /// The injecting session ended (or the arbitration moved): release
    /// everything it held.
    func releaseHeld() { send([InputRecord.releaseAll]) }

    /// Framed records off the helper's stdout (currently op 1,
    /// CLIPBOARD text changed under a foreign owner). Framing is the
    /// shared FramedReader (audit Fable R-2).
    private func feed(_ bytes: Data) {
        outputReader.append(bytes)
        do {
            while let (_, rec) = try outputReader.next() {
                let op = rec[rec.startIndex]
                let body = rec.subdata(in: rec.index(after: rec.startIndex)..<rec.endIndex)
                guard op == InputRecord.recordClipboardText else { continue }
                guard let text = String(data: body, encoding: .utf8) else {
                    print(Log.stamp(), "ledgehostd: input: clipboard record not UTF-8 — dropped")
                    continue
                }
                let onClipboard = self.onClipboard
                loop.execute { onClipboard?(text) }
            }
        } catch {
            print(Log.stamp(), "ledgehostd: input: bad output record — dropping rest")
            outputReader.clearBuffer()
        }
    }
}
