import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// MediaService — the media helper's lifecycle and the kind 0/1
// broadcast (phase-1-plan.md decisions 1–4, 6, 7, 11).
//
// One pipeline broadcasts to every session watching the desktop. The
// helper is spawned by absolute path with a minimal environment
// (DISPLAY, XAUTHORITY, PATH, HOME — every GST_* variable unset), its
// stdout/stdin ride NIO pipe channels on the daemon's event loop, and
// it dies on our death (PR_SET_PDEATHSIG in the helper), on stdin EOF,
// or on stdout EPIPE.

final class MediaService {
    /// What a session needs to see next, in order.
    enum ResumeState {
        case live          // frames flow normally
        case needsIDR      // dropped/joined: send kind 0 + next IDR
        case dropping      // over the write water mark: AUs dropped
    }

    struct Watcher {
        var state: ResumeState = .needsIDR
        var wantedFPS: Int = 60
        var lastKeyframeRequest: Date = .distantPast
        var droppedAUs: Int = 0
        var resumedAUs: Int = 0
    }

    struct RunningInfo { var width: Int = 0, height: Int = 0, fps: Int = 0, mbps: Int = 0 }

    private let group: EventLoopGroup
    private let loop: EventLoop
    private let display: String
    private let xauthority: String?
    private let fpsSource: () -> Int      // max wanted fps across sessions

    private var helperProcess: Process?
    private var outChannel: Channel?      // helper stdout → us
    private var inChannel: Channel?       // us → helper stdin
    private var reader = MediaRecordReader()
    private var running = false
    private var stopTask: Scheduled<Void>?
    private var restarts = 0
    private var lastRestart: Date = .distantPast
    private var lastForcedIDR: Date = .distantPast

    /// Current parameter sets as the wire carries them (kind 0 payload).
    private(set) var setsPayload: Data?
    /// Encoder geometry/bitrate actually running, for kind 16 `stream`.
    private(set) var runningInfo = RunningInfo()

    /// high-water per decision 4: max(4 MiB, 2× the P1-M1 IDR size).
    static let highWaterBytes = max(4 << 20, 2 * 31249)
    /// kind 0 is never dropped; this is where a session stops counting.
    static let watermark = ChannelOptions.writeBufferWaterMark

    init(group: EventLoopGroup,
         display: String,
         xauthority: String?,
         fpsSource: @escaping () -> Int) {
        self.group = group
        self.loop = group.next()
        self.display = display
        self.xauthority = xauthority
        self.fpsSource = fpsSource
    }

    /// A settings change that cannot retune live (today: fps) restarts
    /// the pipeline; watchers rejoin through the standard kind 0 + IDR
    /// path. Called only on the event loop.
    func restart() {
        loop.execute {
            guard self.running else { return }
            print(Log.stamp(), "ledgehostd: media: restarting pipeline (fps now \(self.fpsSource()))")
            self.stop(restart: true)
            self.loop.scheduleTask(in: .milliseconds(300)) { [weak self] in self?.start() }
        }
    }

    // MARK: - Lifecycle

    /// The first desktop watcher starts the pipeline; the last one
    /// stopping arms a 5 s debounce before STOP (the client opens a
    /// short-lived session at connect that is immediately replaced).
    func watcherJoined() {
        loop.execute {
            self.stopTask?.cancel(); self.stopTask = nil
            if !self.running { self.start() }
        }
    }

    func watcherLeft(hasWatchers: Bool) {
        loop.execute {
            guard !hasWatchers, self.running, self.stopTask == nil else { return }
            self.stopTask = self.loop.scheduleTask(in: .seconds(5)) { [weak self] in
                guard let self, self.running else { return }
                print(Log.stamp(), "ledgehostd: media: no watchers for 5 s — stopping pipeline")
                self.stop(restart: false)
            }
        }
    }

    func shutdown() { stop(restart: false) }

    private static let mediaHelperPaths: [String] = {
        var paths: [String] = []
        if let exe = Bundle.main.executableURL {
            paths.append(exe.deletingLastPathComponent().appendingPathComponent("ledgehost-media").path)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/bin/ledgehost-media")
        paths.append("/usr/bin/ledgehost-media")
        return paths
    }()

    private static func helperURL() -> URL? {
        mediaHelperPaths.lazy.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func start() {
        guard let url = Self.helperURL() else {
            print(Log.stamp(), "ledgehostd: media: ledgehost-media not found (looked next to the executable, then ./bin, /usr/bin)")
            helperFailed(); return
        }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--source", "x11",
                             "--fps", String(fpsSource()),
                             "--bitrate", "15000000"]
        var env: [String: String] = ["DISPLAY": display,
                                     "PATH": "/usr/bin:/bin",
                                     "HOME": NSHomeDirectory()]
        if let xauthority { env["XAUTHORITY"] = xauthority }
        process.environment = env
        let outPipe = Pipe(), inPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardInput = inPipe
        process.standardError = errPipe
        reader = MediaRecordReader()
        do { try process.run() } catch {
            print(Log.stamp(), "ledgehostd: media: spawn failed: \(error)")
            helperFailed(); return
        }
        helperProcess = process
        running = true
        runningInfo = RunningInfo(width: 0, height: 0, fps: fpsSource(), mbps: 15)
        outPipe.fileHandleForReading.readabilityHandler = nil
        let outFD = dup(outPipe.fileHandleForReading.fileDescriptor)
        let inFD = dup(inPipe.fileHandleForWriting.fileDescriptor)
        attachPipes(outFD: outFD, inFD: inFD)
        // The helper logs to stderr; relay it line-by-line into our log.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                print(Log.stamp(), "ledgehostd: media:", line)
            }
        }
        process.terminationHandler = { [weak self] p in
            self?.loop.execute { self?.helperExited(status: p.terminationStatus) }
        }
        print(Log.stamp(), "ledgehostd: media: pipeline starting (pid \(process.processIdentifier), fps \(fpsSource()), :\(display) capture)")
    }

    private func attachPipes(outFD: Int32, inFD: Int32) {
        // The pipe channel needs a pollable descriptor on BOTH sides
        // (/dev/null cannot be epoll-registered): a socketpair supplies
        // the direction the helper doesn't use.
        var dummy: (read: Int32, write: Int32) = (-1, -1)
        var pair: [Int32] = [-1, -1]
        if socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair) == 0 {
            dummy = (pair[0], pair[1])
        } else {
            print(Log.stamp(), "ledgehostd: media: socketpair failed — \(String(cString: strerror(errno)))")
            close(outFD); close(inFD); helperFailed(); return
        }
        let handler = HelperOutputHandler(service: self)
        NIOPipeBootstrap(group: loop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in channel.pipeline.addHandler(handler) }
            .takingOwnershipOfDescriptors(input: outFD, output: dummy.write)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    print(Log.stamp(), "ledgehostd: media: stdout pipe channel failed: \(error)")
                    close(inFD); close(dummy.read)
                    self.helperFailed()
                case .success(let out):
                    self.outChannel = out
                    NIOPipeBootstrap(group: self.loop)
                        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .takingOwnershipOfDescriptors(input: dummy.read, output: inFD)
                        .whenComplete { [weak self] result in
                            guard let self else { return }
                            switch result {
                            case .failure(let error):
                                print(Log.stamp(), "ledgehostd: media: stdin pipe channel failed: \(error)")
                                self.helperFailed()
                            case .success(let inCh):
                                self.inChannel = inCh
                            }
                        }
                }
            }
    }

    private func stop(restart: Bool) {
        running = false
        helperProcess?.terminationHandler = nil
        if let inChannel {
            inChannel.eventLoop.execute {
                var buf = inChannel.allocator.buffer(capacity: 5)
                buf.writeString("STOP\n")
                inChannel.writeAndFlush(buf).whenComplete { _ in inChannel.close(promise: nil) }
            }
        }
        outChannel?.close(promise: nil)
        outChannel = nil; inChannel = nil
        if let p = helperProcess, p.isRunning { p.terminate() }
        helperProcess = nil
        setsPayload = nil
        if !restart { restarts = 0 }
    }

    private func helperExited(status: Int32) {
        guard running else { return }          // an orderly stop is not a failure
        print(Log.stamp(), "ledgehostd: media: helper exited (status \(status))")
        helperFailed()
    }

    private func helperFailed() {
        stop(restart: true)
        let now = Date()
        restarts = now.timeIntervalSince(lastRestart) > 60 ? 1 : restarts + 1
        lastRestart = now
        if restarts > 5 {
            print(Log.stamp(), "ledgehostd: media: helper failed \(restarts) times — goodbye to watchers")
            onGiveUp?()
            return
        }
        let delay: TimeInterval = [1, 2, 5, 10, 30][min(restarts - 1, 4)]
        print(Log.stamp(), "ledgehostd: media: restart \(restarts) in \(Int(delay)) s")
        loop.scheduleTask(in: .milliseconds(Int64(delay * 1000))) { [weak self] in self?.start() }
    }

    /// Called when the helper cannot be kept alive: the daemon sends
    /// kind 22 goodbye (reconnect: true) to every watcher.
    var onGiveUp: (() -> Void)?

    // MARK: - Records in

    fileprivate func feed(_ bytes: Data) {
        do {
            for record in try reader.feed(bytes) {
                switch record.tag {
                case .parameterSets: handleSets(record)
                case .accessUnit: handleAU(record)
                }
            }
        } catch {
            print(Log.stamp(), "ledgehostd: media: protocol violation \(error) — restarting helper")
            helperFailed()
        }
    }

    fileprivate func helperEOF() {
        guard running else { return }
        print(Log.stamp(), "ledgehostd: media: helper stdout closed")
        helperFailed()
    }

    private func handleSets(_ record: MediaRecord) {
        guard let payload = AnnexBConverter.parameterSetsPayload(record.payload) else {
            print(Log.stamp(), "ledgehostd: media: sets record held no parameter NALs — ignored")
            return
        }
        if payload != setsPayload {
            setsPayload = payload
            onSetsChanged?(payload)
        }
    }

    private func handleAU(_ record: MediaRecord) {
        let converted = AnnexBConverter.convert(record.payload)
        // In-band sets are authoritative: refresh the cache the same way
        // a sets record does.
        if !converted.parameterSets.isEmpty {
            let payload = ParameterSets(nalUnitHeaderLength: 4, sets: converted.parameterSets).encoded()
            if payload != setsPayload {
                setsPayload = payload
                onSetsChanged?(payload)
            }
        }
        onFrame?(record.captureTimestamp, converted, record.isKeyframe || converted.isIDR)
    }

    // MARK: - Events out (wired to the session layer)

    /// kind 0 payload changed (once per subscriber broadcast).
    var onSetsChanged: ((Data) -> Void)?
    /// kind 1: capture timestamp, converted AU, keyframe flag.
    var onFrame: ((Double, ConvertedAU, Bool) -> Void)?

    // MARK: - Control

    /// Forced IDRs coalesce globally: at most one request per 250 ms no
    /// matter how many sessions ask.
    func requestKeyframe() {
        let now = Date()
        guard now.timeIntervalSince(lastForcedIDR) >= 0.25 else {
            print(Log.stamp(), "ledgehostd: media: keyframe request coalesced")
            return
        }
        lastForcedIDR = now
        guard let inChannel else { return }
        var buf = inChannel.allocator.buffer(capacity: 9)
        buf.writeString("KEYFRAME\n")
        inChannel.writeAndFlush(buf, promise: nil)
    }
}

/// Reads framed records off the helper's stdout.
private final class HelperOutputHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private weak var service: MediaService?

    init(service: MediaService) { self.service = service }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            service?.feed(Data(bytes))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        service?.helperEOF()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print(Log.stamp(), "ledgehostd: media: helper channel error \(error)")
        context.close(promise: nil)
    }
}
