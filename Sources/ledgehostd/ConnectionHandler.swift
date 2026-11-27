import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import StreamProtocol
import LedgehostCore

// The session layer (audit R1/R-1): the registry that owns session
// state and the per-connection state machine — awaitingGate → pairing
// | awaitingHello → session → done. Wire parsing, deadlines, input
// arbitration, media wiring and clipboard fan-out all hang off this
// file; Catalog.swift carries the catalog/settings replies and
// ClipboardRelay.swift the kind 32 handling.

// MARK: - Session registry

/// Every session handler runs on the single event loop, so the
/// registry needs no locking. It also owns the injector slot
/// (decision 10): only the session that most recently selected the
/// desktop may inject input.
final class SessionRegistry {
    var sessions: [ObjectIdentifier: ConnectionHandler] = [:]

    /// Open sill-pair/1 connections (audit S5/F3-lite): the pairing door
    /// is unauthenticated, so its concurrency is capped — extra
    /// connections are refused at handshake time. Sessions that leave
    /// the pairing state or die decrement this.
    var pairingDoors = 0
    static let maxPairingDoors = 4

    var watchers: [ConnectionHandler] { sessions.values.filter { $0.source != nil } }
    func watchers(of source: CaptureSource) -> [ConnectionHandler] {
        sessions.values.filter { $0.source == source }
    }

    func maxWantedFPS(of source: CaptureSource) -> Int {
        watchers(of: source).map { $0.inputGate.wantedFPS }.max() ?? 60
    }
}

extension SessionRegistry {
    /// The one serialized input stream (decision 10): only the session
    /// that most recently selected the desktop injects.
    var injector: ConnectionHandler? {
        get { injectorStorage }
        set { injectorStorage = newValue }
    }
}
private var injectorStorage: ConnectionHandler?

/// Per-session input state (audit R7): the wire-event translator, the
/// 240/s rate limiter and the viewport fps preference are the
/// connection's business — MediaService.Watcher keeps only media
/// resume state.
struct InputGate {
    var translator = InputTranslator()
    var rateLimiter = InputRateLimiter()
    var wantedFPS = 60
}

/// A small arrow PNG for the one static cursorShape (kind 14) sent on
/// selectSource (decision 5; whether the client can draw a usable
/// pointer from it is observed in P1-M3).
let cursorPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAVUlEQVR4nKXQ2woAIAgD0P3/Ty96KLpoOR0EPayDBgBEMawi7KkgHMkiXJNBeEZFLkBFTEBBXCAKfYEf5BWt857gvEf2n8DyQP9EoyghXiG1TmS6LQ15ZQEO0cXuMgAAAABJRU5ErkJggg==")!

// MARK: - Connection state machine

final class ConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    enum State {
        case awaitingGate
        case pairing          // sill-pair/1: one kind 19, one kind 20, close
        case awaitingHello    // sill/1, pinned: the first message must be Hello
        case session
        case done
    }

    private let peer: PeerBox
    private var state: State = .awaitingGate
    /// Wire framing (FramedReader, audit Fable R-2). The payload cap is
    /// re-read per record so it tightens/loosens with `state`.
    private lazy var reader = FramedReader<StreamHeader>.streamMessages { [weak self] in
        guard let self, self.state == .pairing else { return StreamMessage.maxClientPayload }
        return StreamMessage.maxPairingPayload
    }
    private var tick: RepeatedTask?
    /// Deadline for whichever pre-session wait is current: TLS handshake,
    /// pair request, or first Hello (audit S5/F3-lite/F12). Reused so a
    /// connection can never hold more than one pending deadline.
    private var deadline: Scheduled<()>?
    private weak var channel: Channel?
    /// This connection holds a pairing-door slot (audit S5 cap).
    private var holdsPairingDoor = false
    /// Bounded per-message logging (audit S6/F5).
    private var inputLog = LogSampler()
    var msgLog = LogSampler()
    var label = "?"
    /// What this session streams; nil watches nothing (phase 2:
    /// sources generalize — desktop is no longer the only one).
    var source: CaptureSource?
    var watcher = MediaService.Watcher()
    var inputGate = InputGate()
    /// kind 32: this connection asked for the host's copies.
    var clipboardSubscribed = false
    /// Timestamps of the connection's kind 32s taken in the last
    /// second (ClipboardPolicy.hostReceives' rate state).
    var clipboardArrivals: [Double] = []

    init(peer: PeerBox) { self.peer = peer }

    var key: ObjectIdentifier { ObjectIdentifier(self) }
    var peerFingerprint: Data? { peer.fingerprint }

    /// Deliver one already-built message buffer (media fan-out).
    func deliver(_ buf: ByteBuffer) {
        channel?.writeAndFlush(buf, promise: nil)
    }

    func writeNoFlush(_ buf: ByteBuffer) { channel?.write(buf, promise: nil) }

    func closeSoon() { channel?.close(promise: nil) }

    /// Byte-accounted backpressure (decision 4): when the channel's
    /// outbound buffer passes the high-water mark the session drops AUs;
    /// on becoming writable it rejoins via kind 0 + the next IDR.
    private func updateDropping() {
        guard let channel, source != nil else { return }
        if !channel.isWritable && watcher.state == .live {
            watcher.state = .dropping
            print(Log.stamp(), "ledgehostd: session \(label) over the water mark — dropping AUs, forcing IDR")
            if let source { media.requestKeyframe(source) }
        } else if channel.isWritable && watcher.state == .dropping {
            watcher.state = .needsIDR
            print(Log.stamp(), "ledgehostd: session \(label) writable again — rejoin on next IDR")
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted(let negotiated) = tlsEvent {
            deadline?.cancel()          // TLS handshake deadline served
            guard let fp = peer.fingerprint else {
                context.close(promise: nil); return
            }
            switch negotiated {
            case "sill-pair/1":
                // Cap concurrent unauthenticated doors (audit S5/F3-lite):
                // a connect flood may not hold unbounded handshake slots.
                guard registry.pairingDoors < SessionRegistry.maxPairingDoors else {
                    print(Log.stamp(), "ledgehostd: pairing door busy (\(registry.pairingDoors) open) — refusing extra connection")
                    context.close(promise: nil); return
                }
                registry.pairingDoors += 1
                holdsPairingDoor = true
                state = .pairing
                // 30 s, not the protocol's nominal 10: a debug-build
                // client spends ~11 s deriving the 600k-round pairing
                // key before it can send its one message. Still a
                // bounded half-open window for the door-hardening the
                // timeout exists for.
                deadline = context.eventLoop.scheduleTask(in: .seconds(30)) { [weak self] in
                    guard let self, self.state == .pairing else { return }
                    print(Log.stamp(), "ledgehostd: pairing connection timed out")
                    context.close(promise: nil)
                }
            case "sill/1":
                if pins.isPinned(fp) {
                    state = .awaitingHello
                    print(Log.stamp(), "ledgehostd: session from paired \(RemoteIdentityShortName(fp))")
                    // A pinned client that never says Hello holds a
                    // slot forever otherwise (audit S5/F12).
                    deadline = context.eventLoop.scheduleTask(in: .seconds(60)) { [weak self] in
                        guard let self, self.state == .awaitingHello else { return }
                        print(Log.stamp(), "ledgehostd: no Hello within 60 s — closing")
                        context.close(promise: nil)
                    }
                } else {
                    print(Log.stamp(), "ledgehostd: session from unpaired \(RemoteIdentityShortName(fp)) — closing")
                    context.close(promise: nil)
                }
            default:
                context.close(promise: nil)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) { reader.append(Data(bytes)) }
        drain(context: context)
    }

    private func drain(context: ChannelHandlerContext) {
        do {
            // next() interleaves parse and handle so a state change
            // inside handle() (pairing -> session) takes effect for the
            // very next record's cap, as before.
            while state != .done, let (header, payload) = try reader.next() {
                handle(context: context, kind: header.kind, payload: payload)
            }
        } catch FrameViolation.oversized(let n, let cap) {
            print(Log.stamp(), "ledgehostd: payload over the cap (\(n) > \(cap)) — closing")
            context.close(promise: nil); state = .done
        } catch {
            print(Log.stamp(), "ledgehostd: bad client framing — closing")
            context.close(promise: nil); state = .done
        }
    }

    /// The one StreamMessage serializer (audit R6): every send path is
    /// a thin Channel adapter over this.
    private func send(_ channel: Channel, kind: StreamMessageKind, payload: Data,
                      keyframe: Bool = false) {
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: keyframe, payload: payload)
        var out = channel.allocator.buffer(capacity: message.serialized().count)
        out.writeBytes(message.serialized())
        channel.writeAndFlush(out, promise: nil)
    }

    func send(context: ChannelHandlerContext, kind: StreamMessageKind, payload: Data,
              keyframe: Bool = false) {
        send(context.channel, kind: kind, payload: payload, keyframe: keyframe)
    }

    /// Same, for call sites outside channel callbacks (registry fan-out
    /// uses deliver() on already-built buffers instead).
    func send(kind: StreamMessageKind, payload: Data, keyframe: Bool = false) {
        guard let channel else { return }
        send(channel, kind: kind, payload: payload, keyframe: keyframe)
    }

    private func handle(context: ChannelHandlerContext, kind: StreamMessageKind, payload: Data) {
        switch state {
        case .pairing:
            deadline?.cancel()
            if holdsPairingDoor { registry.pairingDoors -= 1; holdsPairingDoor = false }
            state = .done
            guard kind == .pairRequest, let request = Wire.decode(PairRequest.self, from: payload),
                  let fp = peer.fingerprint else {
                context.close(promise: nil); return
            }
            let result = pairing.answer(request, deviceFingerprint: fp,
                                        source: context.channel.remoteAddress?.ipAddress ?? "?")
            send(context: context, kind: .pairResult, payload: Wire.encode(result))
            context.close(promise: nil)

        case .awaitingHello:
            deadline?.cancel()          // Hello arrived (or the payload proves it won't)
            guard kind == .hello, let hello = Wire.decode(Hello.self, from: payload) else {
                print(Log.stamp(), "ledgehostd: session's first message was not a Hello — closing")
                context.close(promise: nil); state = .done; return
            }
            print(Log.stamp(), "ledgehostd: hello: app \(hello.appVersion ?? "?") protocol \(hello.protocol ?? -1) device \(hello.device ?? "?") audio \(hello.audio ?? [])")
            label = SafeText.label(hello.device ?? "?", limit: 32)
            state = .session
            registry.sessions[key] = self
            sendCatalog(context: context)
            tick = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(10)) { [weak self] _ in
                guard let self, self.state == .session else { return }
                self.send(context: context, kind: .tick, payload: Data())
                // Poll the water mark too — writabilityChanged alone is
                // transition-driven; a stalled reader must be caught.
                self.updateDropping()
            }

        case .session:
            switch kind {
            case .ping:
                send(context: context, kind: .pong, payload: payload)
            case .selectSource:
                handleSelectSource(context: context, payload: payload)
            case .viewport:
                handleViewport(payload: payload)
            case .keyframeRequest:
                // At most one a second per connection (the wire rule);
                // the service coalesces forced IDRs per pipeline at 250 ms.
                if let source, Date().timeIntervalSince(watcher.lastKeyframeRequest) >= 1 {
                    watcher.lastKeyframeRequest = Date()
                    media.requestKeyframe(source)
                }
            case .clientStats:
                if let stats = Wire.decode(ClientStats.self, from: payload),
                   let held = msgLog.emit() {
                    let more = held > 0 ? " (+\(held) held)" : ""
                    print(Log.stamp(), "ledgehostd: stats \(label): fps \(stats.fps) frameAge \(stats.frameAgeMs) ms rtt \(stats.rttMs) ms\(more)")
                }
            case .input:
                handleInput(payload: payload)
            case .clipboard:
                handleClipboard(context: context, payload: payload)
            case .changeSettings:
                handleChangeSettings(context: context, payload: payload)
            case .pairingWanted:
                if msgLog.emit() != nil {
                    print(Log.stamp(), "ledgehostd: pairingWanted on a session — ignored")
                }
            default:
                if msgLog.emit() != nil {
                    print(Log.stamp(), "ledgehostd: session message kind \(kind.rawValue) (\(payload.count) bytes)")
                }
            }

        case .awaitingGate, .done:
            break
        }
    }

    // MARK: selectSource / viewport / settings

    private func handleSelectSource(context: ChannelHandlerContext, payload: Data) {
        guard let source = Wire.decode(StreamSource.self, from: payload) else {
            print(Log.stamp(), "ledgehostd: selectSource: undecodable payload — ignored")
            return
        }
        switch source {
        case .desktop:
            print(Log.stamp(), "ledgehostd: \(label) selected the desktop")
            becomeWatcher(of: .desktop, context: context)
        case .none:
            print(Log.stamp(), "ledgehostd: \(label) unselected its source")
            leaveSource()
            sendWindowList(context: context, active: .none)
        case .window(let id):
            guard windows.window(id) != nil else {
                // Stale or unknown id: refuse by re-asserting the
                // current source through a fresh list (same pattern
                // as phase 1's refusal).
                if msgLog.emit() != nil {
                    print(Log.stamp(), "ledgehostd: \(label) selected unknown window \(String(id, radix: 16)) — list resent")
                }
                sendWindowList(context: context, active: self.source?.wire ?? .none)
                return
            }
            print(Log.stamp(), "ledgehostd: \(label) selected window \(String(id, radix: 16))")
            becomeWatcher(of: .window(id), context: context)
        }
    }

    /// Track the watched window's last known rect so geometry events
    /// can tell a move (input rect only) from a resize (pipeline
    /// restart + input rect).
    private var watchedRect: (x: Int, y: Int, w: Int, h: Int)?

    /// The screen rectangle the injector's input fractions map onto
    /// (input op 9): the watched window's current rect, or the root
    /// rect for the desktop source.
    private func pushSourceRect() {
        guard registry.injector === self, let source else { return }
        switch source {
        case .desktop:
            if let root = windows.rootSize {
                input.setSourceRect(x: 0, y: 0, width: root.w, height: root.h)
            }
        case .window(let id):
            if let w = windows.window(id) {
                input.setSourceRect(x: w.x, y: w.y, width: w.width, height: w.height)
            }
        }
    }

    /// This session starts (or switches to) watching `s`: injector
    /// arbitration, per-source pipeline join, resume state reset.
    private func becomeWatcher(of s: CaptureSource, context: ChannelHandlerContext) {
        if registry.injector !== self && registry.injector != nil {
            // Arbitration moved: release what the previous injector
            // held before the new one takes over.
            input.releaseHeld()
            print(Log.stamp(), "ledgehostd: input injector -> \(label)")
        }
        registry.injector = self
        if source != s {
            if let old = source {
                media.watcherLeft(old, hasWatchers: !registry.watchers(of: old).isEmpty)
            }
            let wasWatching = source != nil
            source = s
            watchedRect = nil
            watcher = MediaService.Watcher()       // .needsIDR
            inputGate = InputGate()
            try? channel?.setOption(ChannelOptions.writeBufferWaterMark,
                                    value: .init(low: MediaService.highWaterBytes / 2,
                                                 high: MediaService.highWaterBytes))
            send(context: context, kind: .cursorShape,
                 payload: CursorShapeBlob.encode(hotspot: CGPoint(x: 0, y: 0),
                                                 size: CGSize(width: 16, height: 16),
                                                 png: cursorPNG))
            if let sets = media.setsPayload(s) {
                send(context: context, kind: .parameterSets, payload: sets,
                     keyframe: true)
            }
            media.watcherJoined(s)
            if !wasWatching { input.watcherJoined() }
            media.requestKeyframe(s)
        }
        if case .window(let id) = s, let w = windows.window(id) {
            watchedRect = (w.x, w.y, w.width, w.height)
        }
        pushSourceRect()
        sendWindowList(context: context, active: s.wire)
    }

    /// This session stops watching its source: leave its pipeline,
    /// release the injector slot if held. (Also the destroyed-window
    /// path — same end state, per the phase-2 plan.)
    private func leaveSource() {
        guard let s = source else { return }
        source = nil
        watchedRect = nil
        if registry.injector === self {
            registry.injector = nil
            input.releaseHeld()
        }
        media.watcherLeft(s, hasWatchers: !registry.watchers(of: s).isEmpty)
        input.watcherLeft(hasWatchers: !registry.watchers.isEmpty)
    }

    /// The tracker's window list changed: follow a watched window's
    /// geometry, drop a watched window that is gone, push every
    /// session the fresh list (phase 2 requirement: live lists).
    func windowListChanged() {
        if case .window(let id) = source {
            if let w = windows.window(id) {
                let r = (x: w.x, y: w.y, w: w.width, h: w.height)
                if watchedRect == nil || watchedRect! != r {
                    let resized = watchedRect.map { $0.w != r.w || $0.h != r.h } ?? false
                    watchedRect = r
                    if resized {
                        print(Log.stamp(), "ledgehostd: window \(String(id, radix: 16)) resized to \(r.w)x\(r.h) — restarting its pipeline")
                        media.sourceResized(.window(id))
                    }
                    pushSourceRect()
                }
            } else {
                print(Log.stamp(), "ledgehostd: window \(String(id, radix: 16)) gone — \(label) back to no source")
                leaveSource()
                // A destroyed window's pipeline has nothing to capture:
                // kill it now rather than after the 5 s no-watchers
                // debounce — its xid target can never come back.
                media.sourceGone(.window(id))
            }
        }
        sendWindowList(active: self.source?.wire ?? .none)
    }

    /// kind 8 → op records for the input helper. Only the injector
    /// session (most recent .desktop selector) may inject — the gate
    /// runs BEFORE any logging (audit S6/F5: per-event logging before
    /// arbitration is a journal-flood surface); events are rate-capped
    /// at 240/s and validated by the translator before they reach
    /// XTest. Logging shows the SHAPE only — event kind, HID usage,
    /// modifier bits — never text payloads, and is bounded by
    /// LogSampler. Double fields are formatted via the trap-safe
    /// ViewportBounds.number — an Int() conversion here was the S1/F1
    /// daemon-crash primitive.
    private func handleInput(payload: Data) {
        guard let ev = Wire.decode(InputEvent.self, from: payload) else { return }
        guard registry.injector === self else { return }
        if let held = inputLog.emit() {
            let more = held > 0 ? " (+\(held) held)" : ""
            switch ev {
            case .pointer(let a, let x, let y):
                print(Log.stamp(), "ledgehostd: input \(label): pointer \(a.rawValue) x\(ViewportBounds.number(x))y\(ViewportBounds.number(y))\(more)")
            case .scroll(_, _, let dx, let dy):
                print(Log.stamp(), "ledgehostd: input \(label): scroll dx\(ViewportBounds.number(dx)) dy\(ViewportBounds.number(dy))\(more)")
            case .text(let s):
                print(Log.stamp(), "ledgehostd: input \(label): text (n=\(s.utf8.count))\(more)")
            case .key(let u, let d, let m):
                print(Log.stamp(), "ledgehostd: input \(label): key hid=0x\(String(u, radix: 16)) down=\(d) mods=0x\(String(m, radix: 16))\(more)")
            case .scrollGesture(let phase, _, _):
                print(Log.stamp(), "ledgehostd: input \(label): scrollGesture \(phase.rawValue)\(more)")
            }
        }
        guard inputGate.rateLimiter.allow(now: Date().timeIntervalSince1970) else { return }
        if let records = inputGate.translator.translate(ev) {
            input.send(records)
        }
    }

    private func handleViewport(payload: Data) {
        guard let v = Wire.decode(Viewport.self, from: payload) else {
            print(Log.stamp(), "ledgehostd: viewport from \(label): undecodable — ignored")
            return
        }
        if let why = ViewportBounds.refusal(v) {
            if msgLog.emit() != nil {
                print(Log.stamp(), "ledgehostd: viewport from \(label) refused: \(why)")
            }
            return
        }
        let wanted = min(max(v.fps ?? 60, 24), settings.maxFPS)
        if wanted != inputGate.wantedFPS {
            inputGate.wantedFPS = wanted
            if let source {
                let maxFPS = registry.maxWantedFPS(of: source)
                print(Log.stamp(), "ledgehostd: \(label) wants \(wanted) fps (stream max \(maxFPS))")
                media.restartIfWantedFPSMoved()
            } else {
                print(Log.stamp(), "ledgehostd: \(label) wants \(wanted) fps")
            }
        }
    }

    private func handleChangeSettings(context: ChannelHandlerContext, payload: Data) {
        guard let change = Wire.decode(HostSettingsChange.self, from: payload) else {
            print(Log.stamp(), "ledgehostd: changeSettings from \(label): undecodable — ignored")
            return
        }
        // Whitelist against SettingsChoices (the contract). Fields this
        // host cannot honour keep their advertised values in the answer:
        // virtualDisplay is advertised unavailable, and directWireless /
        // sendAudio are advertised absent (nil), so a device showing
        // those rows never sends them; if one arrives anyway it is
        // ignored and the answer still carries the advertised value.
        var applied: [String] = []
        var fpsChanged = false            // audit R-9: tracked, not prefix-matched
        var bitrateToApply: Int?          // whitelist once, use twice
        if let v = change.maxFPS, SettingsChoices.maxFPS.contains(v) {
            if settings.maxFPS != v {
                settings.maxFPS = v
                applied.append("maxFPS=\(v)")
                fpsChanged = true
            }
        }
        if let v = change.bitrate, SettingsChoices.bitrate.contains(v) {
            bitrateToApply = v
            if settings.bitrate != v {
                settings.bitrate = v
                applied.append("bitrate=\(v)")
            }
        }
        if let v = change.captureScale, SettingsChoices.captureScale.contains(v) {
            if settings.captureScale != v {
                settings.captureScale = v
                applied.append("captureScale=\(v) (no effect on X capture)")
            }
        }
        if let v = change.prioritizeSpeed {
            settings.prioritizeSpeed = v
            applied.append("prioritizeSpeed=\(v)")
        }
        var ignored: [String] = []
        if change.virtualDisplay != nil { ignored.append("virtualDisplay (unavailable on this host)") }
        if change.directWireless != nil { ignored.append("directWireless (not a setting here)") }
        if change.sendAudio != nil { ignored.append("sendAudio (no audio on this host)") }
        // Apply: bitrate retunes the encoder live (decision 12); a new
        // fps ceiling re-clamps each watcher's rate and restarts the
        // pipeline via the standard kind 0 + IDR rejoin path.
        if let v = bitrateToApply {
            media.setBitrate(v)
        }
        if fpsChanged {
            for w in registry.watchers { w.inputGate.wantedFPS = min(w.inputGate.wantedFPS, settings.maxFPS) }
            media.restartIfWantedFPSMoved()
        }
        print(Log.stamp(), "ledgehostd: \(label) changed settings: \(applied.isEmpty ? "none applied" : applied.joined(separator: " "))\(ignored.isEmpty ? "" : " — ignored: \(ignored.joined(separator: ", "))")")
        send(context: context, kind: .hostSettings, payload: Wire.encode(settingsState(answering: change.token)))
    }

    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
        label = peer.fingerprint.map { RemoteIdentityShortName($0) } ?? context.channel.remoteAddress.map { "\($0)" } ?? "?"
        // Bound the TLS handshake (audit S5/F3-lite): crypto runs on this
        // same event loop, so an unfinished handshake cannot idle here.
        deadline = context.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
            guard let self, self.state == .awaitingGate else { return }
            print(Log.stamp(), "ledgehostd: TLS handshake deadline — closing")
            context.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        updateDropping()
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        tick?.cancel()
        deadline?.cancel()
        if holdsPairingDoor { registry.pairingDoors -= 1; holdsPairingDoor = false }
        leaveSource()
        let wasSubscribed = clipboardSubscribed
        clipboardSubscribed = false
        clipboardArrivals = []
        registry.sessions.removeValue(forKey: key)
        if wasSubscribed { pushClipboardWatch() }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print(Log.stamp(), "ledgehostd: connection error \(error)")
        context.close(promise: nil)
    }
}
