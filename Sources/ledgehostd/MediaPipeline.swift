import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// MediaPipeline — one capture+encode pipeline for one capture source
// (phase-2-plan.md): a helper child, the LHM1 reader, the kind 0 sets
// cache, restart backoff and the restart debounce. Extracted from
// phase 1's MediaService so MediaService can own one per source;
// the POLICY is unchanged: give up after 5 restarts, STOP stdin
// command, terminate immediately on stop, [1,2,5,10,30] backoff.

final class MediaPipeline {
    struct RunningInfo { var width: Int = 0, height: Int = 0, fps: Int = 0, mbps: Int = 0 }

    private let loop: EventLoop
    private let fpsSource: () -> Int      // max wanted fps across THIS source's sessions
    private let supervisor: HelperSupervisor

    private var reader = MediaRecordReader()
    private var running = false
    private var stopTask: Scheduled<Void>?
    private var backoff = RestartBackoff()
    private var lastForcedIDR: Date = .distantPast
    /// Pipeline-restart debounce (audit S7): fps changes and window
    /// resizes could otherwise churn the encoder continuously — at
    /// most one restart per window, latest wins.
    private var pendingRestart: Scheduled<Void>?
    private var lastRequestedRestart: Date = .distantPast
    private static let restartDebounce: TimeInterval = 3

    /// Current parameter sets as the wire carries them (kind 0 payload).
    private(set) var setsPayload: Data?
    /// Encoder geometry/bitrate actually running, for kind 16 `stream`.
    private(set) var runningInfo = RunningInfo()

    /// A helper that cannot stay up after this many tries gives up.
    private static let maxRestarts = 5

    init(group: EventLoopGroup,
         display: String,
         xauthority: String?,
         arguments: @escaping () -> [String],
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
                        arguments: arguments,
                        stopCommand: "STOP\n",
                        stopGrace: 0))
        supervisor.onStdoutData = { [weak self] data in self?.feed(data) }
        supervisor.onStdoutEOF = { [weak self] in self?.helperEOF() }
        supervisor.onDied = { [weak self] status in self?.helperExited(status: status) }
        supervisor.onAttachFailed = { [weak self] in self?.helperFailed() }
    }

    /// Settings changes that cannot retune live (fps, source resize)
    /// restart the pipeline; watchers rejoin through kind 0 + IDR.
    /// Called only on the event loop. Debounced (audit S7).
    func restart() {
        guard running else { return }
        let wait = Self.restartDebounce - Date().timeIntervalSince(lastRequestedRestart)
        if wait > 0 {
            guard pendingRestart == nil else { return }   // latest already queued
            print(Log.stamp(), "ledgehostd: media: restart debounced \(Int(wait * 1000)) ms")
            pendingRestart = loop.scheduleTask(in: .milliseconds(Int64(wait * 1000))) { [weak self] in
                self?.doRestart()
            }
            return
        }
        doRestart()
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

    /// The first watcher on this source starts the pipeline; the last
    /// one stopping arms a 5 s debounce before STOP.
    func watcherJoined() {
        stopTask?.cancel(); stopTask = nil
        if !running { start() }
    }

    func watcherLeft(hasWatchers: Bool) {
        guard !hasWatchers, running, stopTask == nil else { return }
        stopTask = loop.scheduleTask(in: .seconds(5)) { [weak self] in
            guard let self, self.running else { return }
            print(Log.stamp(), "ledgehostd: media: no watchers for 5 s — stopping pipeline")
            self.stop(restart: false)
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

    /// Called when the helper cannot be kept alive.
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

    // MARK: - Events out

    /// kind 0 payload changed (once per subscriber broadcast).
    var onSetsChanged: ((Data) -> Void)?
    /// kind 1: capture timestamp, converted AU, keyframe flag.
    var onFrame: ((Double, ConvertedAU, Bool) -> Void)?

    // MARK: - Control

    /// Forced IDRs coalesce: at most one request per 250 ms per
    /// pipeline no matter how many sessions ask.
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
