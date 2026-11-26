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

final class InputService {
    private let loop: EventLoop
    private let display: String
    private let xauthority: String?

    private var process: Process?
    private var channel: Channel?         // us → helper stdin
    private var running = false
    private var restarts = 0
    private var lastRestart: Date = .distantPast

    init(group: EventLoopGroup, display: String, xauthority: String?) {
        self.loop = group.next()
        self.display = display
        self.xauthority = xauthority
    }

    private static func helperURL() -> URL? {
        var paths: [String] = []
        if let exe = Bundle.main.executableURL {
            paths.append(exe.deletingLastPathComponent().appendingPathComponent("ledgehost-input").path)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/bin/ledgehost-input")
        return paths.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Called when the first desktop watcher appears / the last leaves:
    /// the helper runs while anyone watches.
    func watcherJoined() { loop.execute { if !self.running { self.start() } } }
    func watcherLeft(hasWatchers: Bool) {
        loop.execute { if !hasWatchers { self.stop() } }
    }

    func shutdown() { stop() }

    private func start() {
        guard let url = Self.helperURL() else {
            print(Log.stamp(), "ledgehostd: input: ledgehost-input not found")
            return
        }
        let p = Process()
        p.executableURL = url
        var env: [String: String] = ["DISPLAY": display, "PATH": "/usr/bin:/bin",
                                     "HOME": NSHomeDirectory()]
        if let xauthority { env["XAUTHORITY"] = xauthority }
        p.environment = env
        let inPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        do { try p.run() } catch {
            print(Log.stamp(), "ledgehostd: input: spawn failed: \(error)")
            return
        }
        process = p
        running = true
        let inFD = dup(inPipe.fileHandleForWriting.fileDescriptor)
        var pair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) != 0 {
            close(inFD); failed(); return
        }
        NIOPipeBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .takingOwnershipOfDescriptors(input: pair[0], output: inFD)
            .whenComplete { [weak self] result in
                switch result {
                case .success(let ch): self?.channel = ch; close(pair[1])
                case .failure(let e):
                    print(Log.stamp(), "ledgehostd: input: pipe channel failed: \(e)")
                    close(pair[1]); self?.failed()
                }
            }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                print(Log.stamp(), "ledgehostd: input:", line)
            }
        }
        p.terminationHandler = { [weak self] _ in
            self?.loop.execute { self?.failed() }
        }
        print(Log.stamp(), "ledgehostd: input: helper started (pid \(p.processIdentifier))")
    }

    private func stop() {
        running = false
        let p = process
        channel?.close(promise: nil)         // stdin EOF → helper releases held state itself
        channel = nil
        process = nil
        // SIGKILL/SIGTERM before the helper drains stdin would strand
        // held keys (observed: stuck keycode 38). Give the graceful EOF
        // exit — which runs release_all + scratch-keycode restore — a
        // short window, then terminate whatever is still alive.
        if let p, p.isRunning {
            p.terminationHandler = nil
            loop.scheduleTask(in: .seconds(2)) { [weak p] in
                if let p, p.isRunning { p.terminate() }
            }
        }
    }

    /// Helper died: it released all held input on the way out; restart
    /// with the same backoff as the media helper (decision 3 applies
    /// to both helpers).
    private func failed() {
        guard running else { return }
        stop()
        let now = Date()
        restarts = now.timeIntervalSince(lastRestart) > 60 ? 1 : restarts + 1
        lastRestart = now
        let delay: TimeInterval = [1, 2, 5, 10, 30][min(restarts - 1, 4)]
        print(Log.stamp(), "ledgehostd: input: restart \(restarts) in \(Int(delay)) s")
        loop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) { [weak self] in self?.start() }
    }

    /// One event worth of op records from the injecting session.
    func send(_ records: [Data]) {
        guard let channel else { return }
        var buf = channel.allocator.buffer(capacity: records.reduce(0) { $0 + $1.count })
        for r in records { buf.writeBytes(r) }
        channel.writeAndFlush(buf, promise: nil)
    }

    /// The injecting session ended (or the arbitration moved): release
    /// everything it held.
    func releaseHeld() { send([InputRecord.releaseAll]) }
}
