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
// One pipeline broadcasts to every session watching the desktop. Spawn
// plumbing lives in HelperSupervisor (audit R2/R-5); this file keeps
// the media POLICY: give up after 5 restarts, STOP stdin command,
// terminate immediately on stop, [1,2,5,10,30] backoff via
// RestartBackoff.

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
        var translator = InputTranslator()
        var rateLimiter = InputRateLimiter()
    }

    struct RunningInfo { var width: Int = 0, height: Int = 0, fps: Int = 0, mbps: Int = 0 }

    private let loop: EventLoop
    private let fpsSource: () -> Int      // max wanted fps across sessions
    private let supervisor: HelperSupervisor

    private var reader = MediaRecordReader()
    private var running = false
    private var stopTask: Scheduled<Void>?
    private var backoff = RestartBackoff()
    private var lastForcedIDR: Date = .distantPast
    /// Global pipeline-restart debounce (audit S7): viewport and
    /// changeSettings storms could otherwise churn the encoder
    /// continuously — at most one restart per window, latest wins.
    /// (Distinct from backoff, which throttles crash-loops.)
    private var pendingRestart: Scheduled<Void>?
    private var lastRequestedRestart: Date = .distantPast
    private static let restartDebounce: TimeInterval = 3

    /// Current parameter sets as the wire carries them (kind 0 payload).
    private(set) var setsPayload: Data?
    /// Encoder geometry/bitrate actually running, for kind 16 `stream`.
    private(set) var runningInfo = RunningInfo()

    /// high-water per decision 4: max(4 MiB, 2× the P1-M1 IDR size).
    static let highWaterBytes = max(4 << 20, 2 * 31249)
    /// kind 0 is never dropped; this is where a session stops counting.
    static let watermark = ChannelOptions.writeBufferWaterMark

    /// A helper that cannot stay up after this many tries gives up:
    /// the daemon sends kind 22 goodbye (reconnect: true) to every
    /// watcher (media policy — input restarts indefinitely).
    private static let maxRestarts = 5

    init(group: EventLoopGroup,
         display: String,
         xauthority: String?,
         fpsSource: @escaping () -> Int) {
        self.loop = group.next()
        self.fpsSource = fpsSource
        supervisor = HelperSupervisor(
            loop: loop,
            display: display,
            xauthority: xauthority,
            spec: .init(tag: "media",
                        name: "ledgehost-media",
                        systemPath: "/usr/bin/ledgehost-media",
                        arguments: { ["--source", "x11",
                                      "--fps", String(fpsSource()),
                                      "--bitrate", "15000000"] },
                        stopCommand: "STOP\n",
                        stopGrace: 0))
        supervisor.onStdoutData = { [weak self] data in self?.feed(data) }
        supervisor.onStdoutEOF = { [weak self] in self?.helperEOF() }
        supervisor.onDied = { [weak self] status in self?.helperExited(status: status) }
        supervisor.onAttachFailed = { [weak self] in self?.helperFailed() }
    }

    /// A settings change that cannot retune live (today: fps) restarts
    /// the pipeline; watchers rejoin through the standard kind 0 + IDR
    /// path. Called only on the event loop. Debounced globally
    /// (audit S7): at most one restart per `restartDebounce` window —
    /// a later request inside the window schedules one restart at the
    /// window's edge (latest wins), never a restart storm.
    func restart() {
        loop.execute {
            guard self.running else { return }
            let wait = Self.restartDebounce - Date().timeIntervalSince(self.lastRequestedRestart)
            if wait > 0 {
                guard self.pendingRestart == nil else { return }   // latest already queued
                print(Log.stamp(), "ledgehostd: media: restart debounced \(Int(wait * 1000)) ms")
                self.pendingRestart = self.loop.scheduleTask(in: .milliseconds(Int64(wait * 1000))) { [weak self] in
                    self?.doRestart()
                }
                return
            }
            self.doRestart()
        }
    }

    private func doRestart() {
        pendingRestart = nil
        lastRequestedRestart = Date()
        guard running else { return }
        print(Log.stamp(), "ledgehostd: media: restarting pipeline (fps now \(fpsSource()))")
        stop(restart: true)
        loop.scheduleTask(in: .milliseconds(300)) { [weak self] in self?.start() }
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

    private func start() {
        reader = MediaRecordReader()
        guard supervisor.start() else { helperFailed(); return }
        running = true
        runningInfo = RunningInfo(width: 0, height: 0, fps: fpsSource(), mbps: 15)
        print(Log.stamp(), "ledgehostd: media: pipeline starting (fps \(fpsSource()))")
    }

    private func stop(restart: Bool) {
        running = false
        supervisor.stop()
        setsPayload = nil
        if !restart { backoff.reset() }
    }

    private func helperExited(status: Int32) {
        guard running else { return }          // an orderly stop is not a failure
        print(Log.stamp(), "ledgehostd: media: helper exited (status \(status))")
        helperFailed()
    }

    private func helperFailed() {
        stop(restart: true)
        let delay = backoff.nextDelay()
        if backoff.attempts > Self.maxRestarts {
            print(Log.stamp(), "ledgehostd: media: helper failed \(backoff.attempts) times — goodbye to watchers")
            onGiveUp?()
            return
        }
        print(Log.stamp(), "ledgehostd: media: restart \(backoff.attempts) in \(Int(delay)) s")
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
        supervisor.send(command: "KEYFRAME\n")
    }

    /// Live encoder retune (decision 12): msdkh265enc accepts the
    /// bitrate property mid-stream — `stream.mbps` reflects the new
    /// target immediately; no restart needed.
    func setBitrate(_ bps: Int) {
        supervisor.send(command: "SET_BITRATE \(bps)\n")
        runningInfo.mbps = Int((Double(bps) * Double(runningInfo.fps) / 60 / 1e6).rounded())
    }
}
