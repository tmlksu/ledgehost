import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// MediaService — the media pipelines' manager (phase-2-plan.md): one
// MediaPipeline per distinct selected source, shared by the sessions
// watching it. The desktop is just another source. Per-session resume
// state, watermarks and drop accounting stay on the connection's
// Watcher; the service routes each pipeline's frames to the sessions
// on its source.
//
// Sources are `CaptureSource` (the wire's StreamSource minus .none —
// a session that selects nothing watches no pipeline).

/// What a pipeline captures. `.window` is the xid — stable for the
/// life of the window, which is exactly the id the wire echoes.
enum CaptureSource: Hashable {
    case desktop
    case window(UInt32)

    init?(_ wire: StreamSource) {
        switch wire {
        case .desktop: self = .desktop
        case .window(let id): self = .window(id)
        case .none: return nil
        }
    }

    var wire: StreamSource {
        switch self {
        case .desktop: return .desktop
        case .window(let id): return .window(id)
        }
    }
}

final class MediaService {
    /// What a session needs to see next, in order.
    enum ResumeState {
        case live          // frames flow normally
        case needsIDR      // dropped/joined: send kind 0 + next IDR
        case dropping      // over the write water mark: AUs dropped
    }

    /// Per-session MEDIA state only: resume position and
    /// the keyframe-request rate state. Input translation, input rate
    /// limiting and the fps preference live on the connection
    /// (ConnectionHandler.inputGate).
    struct Watcher {
        var state: ResumeState = .needsIDR
        var lastKeyframeRequest: Date = .distantPast
        var droppedAUs: Int = 0
        var resumedAUs: Int = 0
    }

    typealias RunningInfo = MediaPipeline.RunningInfo

    private let loop: EventLoop
    private let group: EventLoopGroup
    private let display: String
    private let xauthority: String?
    /// max wanted fps among the sessions watching a given source.
    private let fpsSource: (CaptureSource) -> Int

    private var pipelines: [CaptureSource: MediaPipeline] = [:]

    /// high-water per decision 4: max(4 MiB, 2× the P1-M1 IDR size).
    static let highWaterBytes = max(4 << 20, 2 * 31249)

    init(group: EventLoopGroup,
         display: String,
         xauthority: String?,
         fpsSource: @escaping (CaptureSource) -> Int) {
        self.loop = group.next()
        self.group = group
        self.display = display
        self.xauthority = xauthority
        self.fpsSource = fpsSource
    }

    private func pipeline(for source: CaptureSource) -> MediaPipeline {
        if let p = pipelines[source] { return p }
        let p = MediaPipeline(group: group, display: display, xauthority: xauthority,
                              arguments: {
                                  var args = ["--source", "x11",
                                              "--fps", String(self.fpsSource(source)),
                                              "--bitrate", "15000000"]
                                  if case .window(let xid) = source {
                                      args += ["--xid", String(xid)]
                                  }
                                  return args
                              },
                              fpsSource: { self.fpsSource(source) })
        p.onSetsChanged = { [weak self] payload in self?.onSetsChanged?(source, payload) }
        p.onFrame = { [weak self] ts, au, idr in self?.onFrame?(source, ts, au, idr) }
        p.onGiveUp = { [weak self] in self?.onGiveUp?(source) }
        pipelines[source] = p
        return p
    }

    func pipelineIfRunning(_ source: CaptureSource) -> MediaPipeline? { pipelines[source] }

    // MARK: - Watcher tracking (the event loop calls these)

    func watcherJoined(_ source: CaptureSource) {
        loop.execute { self.pipeline(for: source).watcherJoined() }
    }

    func watcherLeft(_ source: CaptureSource, hasWatchers: Bool) {
        loop.execute { self.pipeline(for: source).watcherLeft(hasWatchers: hasWatchers) }
    }

    /// A watched window was resized: that pipeline restarts (the
    /// debounce inside covers geometry storms).
    func sourceResized(_ source: CaptureSource) {
        loop.execute { self.pipelines[source]?.restart() }
    }

    /// A watched window vanished: its pipeline keeps no meaning —
    /// stop it (watchers were already moved off by the session layer).
    func sourceGone(_ source: CaptureSource) {
        loop.execute { self.pipelines[source]?.shutdown() }
    }

    /// A settings change that cannot retune live (today: fps) restarts
    /// every running pipeline.
    func restart() {
        loop.execute { self.pipelines.values.forEach { $0.restart() } }
    }

    /// Restart only the pipelines whose watchers' max wanted fps now
    /// differs from the fps they run at (fps ceiling changes).
    func restartIfWantedFPSMoved() {
        loop.execute {
            for (source, p) in self.pipelines where self.fpsSource(source) != p.runningInfo.fps {
                p.restart()
            }
        }
    }

    func shutdown() {
        loop.execute { self.pipelines.values.forEach { $0.shutdown() } }
    }

    /// Live encoder retune on every running pipeline.
    func setBitrate(_ bps: Int) {
        loop.execute { self.pipelines.values.forEach { $0.setBitrate(bps) } }
    }

    /// Forced IDRs coalesce per pipeline: 250 ms each.
    func requestKeyframe(_ source: CaptureSource) {
        loop.execute { self.pipelines[source]?.requestKeyframe() }
    }

    func setsPayload(_ source: CaptureSource) -> Data? { pipelines[source]?.setsPayload }
    func runningInfo(_ source: CaptureSource) -> RunningInfo {
        pipelines[source]?.runningInfo ?? RunningInfo()
    }

    // MARK: - Events out (wired to the session layer)

    /// kind 0 payload changed; the source identifies the pipeline.
    var onSetsChanged: ((CaptureSource, Data) -> Void)?
    /// kind 1: source, capture timestamp, converted AU, keyframe flag.
    var onFrame: ((CaptureSource, Double, ConvertedAU, Bool) -> Void)?
    /// A pipeline's helper cannot be kept alive.
    var onGiveUp: ((CaptureSource) -> Void)?
}
