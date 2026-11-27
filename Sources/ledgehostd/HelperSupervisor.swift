import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// Helper supervision shared by MediaService and InputService
//: path resolution, the minimal environment,
// the socketpair plumbing NIO pipe channels need, the stderr relay,
// and the termination callback are identical for both helpers — what
// differs is POLICY (restart limits, stop grace, stdin commands), which
// stays in the services as Spec parameters.

/// The [1,2,5,10,30] crash-loop schedule An attempt older
/// than a minute does not count — a helper that ran a while is not
/// crash-looping; an orderly stop() resets the count.
struct RestartBackoff {
    static let schedule: [TimeInterval] = [1, 2, 5, 10, 30]
    private(set) var attempts = 0
    private var lastAttempt: Date = .distantPast

    /// The delay before the next try, counting this failure.
    mutating func nextDelay(now: Date = Date()) -> TimeInterval {
        attempts = now.timeIntervalSince(lastAttempt) > 60 ? 1 : attempts + 1
        lastAttempt = now
        return Self.schedule[min(attempts - 1, Self.schedule.count - 1)]
    }

    mutating func reset() { attempts = 0 }
}

/// One spawned helper process and its two pipe channels. All callbacks
/// fire on `loop`. The supervisor never restarts on its own — that
/// decision (and how many retries are allowed) belongs to the service.
final class HelperSupervisor {
    struct Spec {
        /// Log tag, e.g. "media" → "ledgehostd: media: ...".
        var tag = ""
        /// Binary name; resolved next to the daemon executable, then
        /// ./bin/<name>, then `systemPath` when non-nil.
        var name = ""
        var systemPath: String?
        var arguments: () -> [String] = { [] }
        /// Entries added to the minimal environment
        /// (DISPLAY/PATH/HOME/XAUTHORITY are always set).
        var extraEnvironment: () -> [String: String] = { [:] }
        /// Line written to helper stdin before it is closed on stop()
        /// (media's STOP; input relies on EOF alone).
        var stopCommand: String?
        /// Seconds between an orderly stop() and terminate(): input's
        /// helper releases held keys on its EOF exit path and needs the
        /// window; media terminates immediately.
        var stopGrace: TimeInterval = 0
    }

    let loop: EventLoop
    private let display: String
    private let xauthority: String?
    private let spec: Spec

    private var process: Process?
    private var stdinChannel: Channel?
    private var stdoutChannel: Channel?
    /// Guards the death callback: an orderly stop() is not a failure.
    private var live = false

    /// Helper stdout bytes, on the loop.
    var onStdoutData: ((Data) -> Void)?
    /// Helper stdout closed, on the loop.
    var onStdoutEOF: (() -> Void)?
    /// The process died while `live` (i.e. unexpectedly), on the loop.
    var onDied: ((Int32) -> Void)?
    /// Pipe-channel setup failed, on the loop.
    var onAttachFailed: (() -> Void)?

    init(loop: EventLoop, display: String, xauthority: String?, spec: Spec) {
        self.loop = loop
        self.display = display
        self.xauthority = xauthority
        self.spec = spec
    }

    private var candidatePaths: [String] {
        var paths: [String] = []
        if let exe = Bundle.main.executableURL {
            paths.append(exe.deletingLastPathComponent().appendingPathComponent(spec.name).path)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/bin/" + spec.name)
        if let systemPath = spec.systemPath { paths.append(systemPath) }
        return paths
    }

    private func helperURL() -> URL? {
        candidatePaths.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Returns false when the helper cannot be found or spawned; the
    /// service decides what a missing helper means.
    @discardableResult
    func start() -> Bool {
        guard let url = helperURL() else {
            print(Log.stamp(), "ledgehostd: \(spec.tag): \(spec.name) not found (looked: \(candidatePaths.joined(separator: ", ")))")
            return false
        }
        let process = Process()
        process.executableURL = url
        process.arguments = spec.arguments()
        var env: [String: String] = ["DISPLAY": display,
                                     "PATH": "/usr/bin:/bin",
                                     "HOME": NSHomeDirectory()]
        if let xauthority { env["XAUTHORITY"] = xauthority }
        for (k, v) in spec.extraEnvironment() { env[k] = v }
        process.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            print(Log.stamp(), "ledgehostd: \(spec.tag): spawn failed: \(error)")
            return false
        }
        self.process = process
        live = true
        let inFD = dup(inPipe.fileHandleForWriting.fileDescriptor)
        let outFD = dup(outPipe.fileHandleForReading.fileDescriptor)
        attachChannels(stdinFD: inFD, stdoutFD: outFD)
        // The helper logs to stderr; relay it line-by-line into our log.
        errPipe.fileHandleForReading.readabilityHandler = { [tag = spec.tag] fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                print(Log.stamp(), "ledgehostd: \(tag):", line)
            }
        }
        process.terminationHandler = { [weak self] p in
            self?.loop.execute {
                guard let self, self.live else { return }
                self.onDied?(p.terminationStatus)
            }
        }
        print(Log.stamp(), "ledgehostd: \(spec.tag): helper started (pid \(process.processIdentifier))")
        return true
    }

    /// The pipe channel needs a pollable descriptor on BOTH sides
    /// (/dev/null cannot be epoll-registered): one socketpair supplies
    /// the directions the helper doesn't use — stdout channel writes
    /// sink into pair[1], stdin channel reads source from pair[0].
    private func attachChannels(stdinFD: Int32, stdoutFD: Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0 else {
            print(Log.stamp(), "ledgehostd: \(spec.tag): socketpair failed — \(String(cString: strerror(errno)))")
            close(stdinFD); close(stdoutFD); onAttachFailed?(); return
        }
        let handler = HelperStdoutHandler(supervisor: self)
        NIOPipeBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
            .takingOwnershipOfDescriptors(input: stdoutFD, output: pair[1])
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    print(Log.stamp(), "ledgehostd: \(self.spec.tag): stdout pipe channel failed: \(error)")
                    close(stdinFD); close(pair[0])
                    self.onAttachFailed?()
                case .success(let out):
                    self.stdoutChannel = out
                    NIOPipeBootstrap(group: self.loop)
                        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .takingOwnershipOfDescriptors(input: pair[0], output: stdinFD)
                        .whenComplete { [weak self] result in
                            guard let self else { return }
                            switch result {
                            case .failure(let error):
                                print(Log.stamp(), "ledgehostd: \(self.spec.tag): stdin pipe channel failed: \(error)")
                                self.onAttachFailed?()
                            case .success(let ch):
                                self.stdinChannel = ch
                            }
                        }
                }
            }
    }

    /// An orderly stop: optional stdin command, stdin EOF, stdout
    /// channel closed, then terminate after the spec's grace.
    func stop() {
        live = false
        process?.terminationHandler = nil
        if let ch = stdinChannel {
            ch.eventLoop.execute {
                if let command = self.spec.stopCommand {
                    var buf = ch.allocator.buffer(capacity: command.utf8.count)
                    buf.writeString(command)
                    ch.writeAndFlush(buf).whenComplete { _ in ch.close(promise: nil) }
                } else {
                    ch.close(promise: nil)
                }
            }
        }
        stdoutChannel?.close(promise: nil)
        stdoutChannel = nil; stdinChannel = nil
        let p = process; process = nil
        guard let p, p.isRunning else { return }
        // SIGKILL/SIGTERM before the helper drains stdin would strand
        // held keys (observed: stuck keycode 38) — the grace window
        // covers its release-all exit path.
        if spec.stopGrace > 0 {
            loop.scheduleTask(in: .milliseconds(Int64(spec.stopGrace * 1000))) { [weak p] in
                if let p, p.isRunning { p.terminate() }
            }
        } else {
            p.terminate()
        }
    }

    /// Raw bytes to helper stdin (op records).
    func send(_ data: Data) {
        guard let ch = stdinChannel else { return }
        var buf = ch.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        ch.writeAndFlush(buf, promise: nil)
    }

    /// A control line to helper stdin (KEYFRAME / SET_BITRATE).
    func send(command: String) {
        guard let ch = stdinChannel else { return }
        var buf = ch.allocator.buffer(capacity: command.utf8.count)
        buf.writeString(command)
        ch.writeAndFlush(buf, promise: nil)
    }
}

/// Reads bytes off the helper's stdout and hands them to the
/// supervisor's callback; EOF likewise. Framing lives in the service.
private final class HelperStdoutHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var supervisor: HelperSupervisor?

    init(supervisor: HelperSupervisor) { self.supervisor = supervisor }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            supervisor?.onStdoutData?(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        supervisor?.onStdoutEOF?()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
