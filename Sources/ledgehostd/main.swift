import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// Logs must reach files and journals unbuffered: a pairing code or a
// gate decision sitting in a stdio buffer helps nobody.
setvbuf(stdout, nil, _IONBF, 0)
// A dead helper's stdout pipe must never kill the daemon.
signal(SIGPIPE, SIG_IGN)

// ledgehostd — the Phase 0 host (identity, discovery, TLS doors, the
// session catalog) plus Phase 1 streaming (P1-M2): selectSource on the
// desktop spawns ledgehost-media and broadcasts kind 0/1 to every
// watcher, with byte-accounted per-session backpressure and coalesced
// forced IDRs.
//
// The TLS shape is the M0.5 spike's, generalized: the verification
// callback establishes only "P-256 peer" and the pin (SHA-256 of
// BoringSSL's SPKI bytes); the ALPN/pin gate runs after the handshake,
// and no application decoder touches bytes before the gate passes.

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 7455 : 7455

let configDir = configDirectory("ledgehost")
let identity: HostIdentity
let pins: PinStore
do {
    identity = try HostIdentity.loadOrCreate(in: configDir)
    pins = try PinStore(in: configDir)
} catch {
    fputs("ledgehostd: \(error)\n", stderr)
    exit(2)
}
print(Log.stamp(), "ledgehostd: \(identity.name) — mac id \(identity.macID), fingerprint \(Base64URL.encode(identity.fingerprint))")
print(Log.stamp(), "ledgehostd: \(pins.count) paired device(s); config in \(configDir.path)")

let pairing = PairingManager(identity: identity, pins: pins, port: port)

// MARK: - Discovery (Avahi subprocess for Phase 0)

var avahi: Process?
if let tag = RecognitionTag.make(recognitionKey: identity.recognitionKey) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/avahi-publish-service")
    process.arguments = [identity.name, "_sill._tcp", String(port), "p=1", "r=\(tag)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        avahi = process
        print(Log.stamp(), "ledgehostd: advertising _sill._tcp on port \(port) via avahi (p=1, r=\(tag))")
    } catch {
        print(Log.stamp(), "ledgehostd: avahi-publish-service not available; advertise manually:")
        print(Log.stamp(), "  avahi-publish-service '\(identity.name)' _sill._tcp \(port) p=1 r=\(tag)")
    }
}

// MARK: - TLS

let p256SPKIHead: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]

func peerFingerprint(_ certificate: NIOSSLCertificate) -> Data? {
    guard let spki = try? certificate.extractPublicKey().toSPKIBytes(), spki.count == 91,
          [UInt8](spki.prefix(p256SPKIHead.count)) == p256SPKIHead else { return nil }
    return Data(SHA256.hash(data: spki))
}

final class PeerBox: @unchecked Sendable {
    var fingerprint: Data?
}

// MARK: - Sessions and the media service
//
// Every session handler runs on the single event loop, so the watcher
// registry needs no locking.

var settings = StreamSettings(maxFPS: 60, bitrate: 15_000_000, captureScale: 1,
                              prioritizeSpeed: true, virtualDisplay: false,
                              directWireless: nil, sendAudio: nil)

final class SessionRegistry {
    var sessions: [ObjectIdentifier: ConnectionHandler] = [:]

    var watchers: [ConnectionHandler] { sessions.values.filter { $0.watchingDesktop } }

    var maxWantedFPS: Int {
        watchers.map { $0.watcher.wantedFPS }.max() ?? 60
    }
}
let registry = SessionRegistry()

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let eventLoop = group.next()

let processEnv = ProcessInfo.processInfo.environment
let targetDisplay = processEnv["DISPLAY"] ?? ""
let media = MediaService(group: group,
                         display: targetDisplay,
                         xauthority: processEnv["XAUTHORITY"],
                         fpsSource: { registry.maxWantedFPS })
let input = InputService(group: group,
                         display: targetDisplay,
                         xauthority: processEnv["XAUTHORITY"])
// A foreign client's CLIPBOARD text → every subscribed connection,
// unless it is the text a device itself just set (echo suppression).
input.onClipboard = { text in
    if text == deviceSetText {
        deviceSetText = nil
        print(Log.stamp(), "ledgehostd: clipboard: \(text.utf8.count) byte(s) match the device's own set — not broadcast")
        return
    }
    guard let payload = ClipboardPolicy.payload(text: text) else {
        print(Log.stamp(), "ledgehostd: clipboard: host text \(text.utf8.count) byte(s) not sendable — dropped")
        return
    }
    var n = 0
    for session in registry.sessions.values where session.clipboardSubscribed {
        session.send(kind: .clipboard, payload: payload); n += 1
    }
    print(Log.stamp(), "ledgehostd: clipboard: host text \(text.utf8.count) byte(s) -> \(n) subscriber(s)")
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

/// The last text a device set: the helper's own tracking is the
/// primary echo guard; this is the daemon-side defence in depth
/// (dropped when the helper reports the same text back).
private var deviceSetText: String?

/// A small arrow PNG for the one static cursorShape (kind 14) sent on
/// selectSource (decision 5; whether the client can draw a usable
/// pointer from it is observed in P1-M3).
let cursorPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAVUlEQVR4nKXQ2woAIAgD0P3/Ty96KLpoOR0EPayDBgBEMawi7KkgHMkiXJNBeEZFLkBFTEBBXCAKfYEf5BWt857gvEf2n8DyQP9EoyghXiG1TmS6LQ15ZQEO0cXuMgAAAABJRU5ErkJggg==")!

func buildMessage(_ kind: StreamMessageKind, timestamp: Double, keyframe: Bool, payload: Data) -> ByteBuffer {
    let message = StreamMessage(kind: kind, timestamp: timestamp, isKeyframe: keyframe, payload: payload)
    var buf = ByteBufferAllocator().buffer(capacity: payload.count + StreamMessage.headerLength)
    buf.writeBytes(message.serialized())
    return buf
}

func wireMediaService() {
    media.onSetsChanged = { payload in
        var buf = buildMessage(.parameterSets, timestamp: Date().timeIntervalSince1970,
                               keyframe: true, payload: payload)
        // kind 0 is never dropped — a session that cannot take it must
        // wait for the resume path's copy, not lose the sets.
        for session in registry.watchers {
            session.deliver(buf.readSlice(length: buf.readableBytes) ?? buf)
        }
    }
    media.onFrame = { ts, au, isIDR in
        var frameBuf = buildMessage(.frame, timestamp: ts, keyframe: isIDR, payload: au.frame)
        for session in registry.watchers {
            switch session.watcher.state {
            case .live:
                session.deliver(frameBuf.readSlice(length: frameBuf.readableBytes) ?? frameBuf)
            case .dropping:
                session.watcher.droppedAUs += 1
            case .needsIDR:
                guard isIDR else {
                    session.watcher.droppedAUs += 1
                    continue
                }
                // Resume atomically: kind 0 then the IDR, one flush.
                if let sets = media.setsPayload {
                    session.writeNoFlush(buildMessage(.parameterSets,
                                                      timestamp: Date().timeIntervalSince1970,
                                                      keyframe: true, payload: sets))
                }
                session.deliver(frameBuf.readSlice(length: frameBuf.readableBytes) ?? frameBuf)
                session.watcher.state = .live
                session.watcher.resumedAUs += 1
                print(Log.stamp(), "ledgehostd: session \(session.label) resumed on IDR (\(session.watcher.droppedAUs) AUs dropped)")
            }
        }
    }
    media.onGiveUp = {
        let goodbye = Wire.encode(Goodbye(reason: "quit",
                                          message: "The desktop stream could not start on this host.",
                                          reconnect: true))
        for session in registry.sessions.values {
            session.send(kind: .goodbye, payload: goodbye)
            session.closeSoon()
        }
    }
}

// MARK: - Connection handling

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
    private var buffer = Data()
    private var tick: RepeatedTask?
    private var deadline: Scheduled<()>?
    private weak var channel: Channel?
    var label = "?"
    var watchingDesktop = false
    var watcher = MediaService.Watcher()
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
        guard let channel, watchingDesktop else { return }
        if !channel.isWritable && watcher.state == .live {
            watcher.state = .dropping
            print(Log.stamp(), "ledgehostd: session \(label) over the water mark — dropping AUs, forcing IDR")
            media.requestKeyframe()
        } else if channel.isWritable && watcher.state == .dropping {
            watcher.state = .needsIDR
            print(Log.stamp(), "ledgehostd: session \(label) writable again — rejoin on next IDR")
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted(let negotiated) = tlsEvent {
            guard let fp = peer.fingerprint else {
                context.close(promise: nil); return
            }
            switch negotiated {
            case "sill-pair/1":
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
        if let bytes = buf.readBytes(length: buf.readableBytes) { buffer.append(contentsOf: bytes) }
        drain(context: context)
    }

    private func drain(context: ChannelHandlerContext) {
        while state != .done {
            guard buffer.count >= StreamMessage.headerLength,
                  let header = StreamMessage.parseHeader(buffer) else { return }
            let cap = state == .pairing ? StreamMessage.maxPairingPayload : StreamMessage.maxClientPayload
            guard header.payloadLength <= cap else {
                print(Log.stamp(), "ledgehostd: payload over the cap (\(header.payloadLength) > \(cap)) — closing")
                context.close(promise: nil); state = .done; return
            }
            guard buffer.count >= StreamMessage.headerLength + header.payloadLength else { return }
            let payload = buffer.subdata(in: buffer.startIndex + StreamMessage.headerLength
                                         ..< buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            handle(context: context, kind: header.kind, payload: payload)
        }
    }

    private func send(context: ChannelHandlerContext, kind: StreamMessageKind, payload: Data,
                      keyframe: Bool = false) {
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: keyframe, payload: payload)
        var out = context.channel.allocator.buffer(capacity: message.serialized().count)
        out.writeBytes(message.serialized())
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    /// Same, for call sites outside channel callbacks (registry fan-out
    /// uses deliver() on already-built buffers instead).
    func send(kind: StreamMessageKind, payload: Data, keyframe: Bool = false) {
        guard let channel else { return }
        var out = channel.allocator.buffer(capacity: payload.count + StreamMessage.headerLength)
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: keyframe, payload: payload)
        out.writeBytes(message.serialized())
        channel.writeAndFlush(out, promise: nil)
    }

    private func handle(context: ChannelHandlerContext, kind: StreamMessageKind, payload: Data) {
        switch state {
        case .pairing:
            deadline?.cancel()
            state = .done
            guard kind == .pairRequest, let request = Wire.decode(PairRequest.self, from: payload),
                  let fp = peer.fingerprint else {
                context.close(promise: nil); return
            }
            let result = pairing.answer(request, deviceFingerprint: fp)
            send(context: context, kind: .pairResult, payload: Wire.encode(result))
            context.close(promise: nil)

        case .awaitingHello:
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
                // the service coalesces forced IDRs globally at 250 ms.
                if Date().timeIntervalSince(watcher.lastKeyframeRequest) >= 1 {
                    watcher.lastKeyframeRequest = Date()
                    media.requestKeyframe()
                }
            case .clientStats:
                if let stats = Wire.decode(ClientStats.self, from: payload) {
                    print(Log.stamp(), "ledgehostd: stats \(label): fps \(stats.fps) frameAge \(stats.frameAgeMs) ms rtt \(stats.rttMs) ms")
                }
            case .input:
                handleInput(payload: payload)
            case .clipboard:
                handleClipboard(context: context, payload: payload)
            case .changeSettings:
                handleChangeSettings(context: context, payload: payload)
            case .pairingWanted:
                print(Log.stamp(), "ledgehostd: pairingWanted on a session — ignored")
            default:
                print(Log.stamp(), "ledgehostd: session message kind \(kind.rawValue) (\(payload.count) bytes)")
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
            if registry.injector !== self && registry.injector != nil {
                // Arbitration moved: release what the previous injector
                // held before the new one takes over.
                input.releaseHeld()
                print(Log.stamp(), "ledgehostd: input injector -> \(label)")
            }
            registry.injector = self
            if !watchingDesktop {
                watchingDesktop = true
                watcher = MediaService.Watcher()       // .needsIDR
                try? channel?.setOption(ChannelOptions.writeBufferWaterMark,
                                        value: .init(low: MediaService.highWaterBytes / 2,
                                                     high: MediaService.highWaterBytes))
                send(context: context, kind: .cursorShape,
                     payload: CursorShapeBlob.encode(hotspot: CGPoint(x: 0, y: 0),
                                                     size: CGSize(width: 16, height: 16),
                                                     png: cursorPNG))
                if let sets = media.setsPayload {
                    send(context: context, kind: .parameterSets, payload: sets,
                         keyframe: true)
                }
                media.watcherJoined()
                input.watcherJoined()
                media.requestKeyframe()
            }
            sendWindowList(context: context, active: .desktop)
        case .none:
            if watchingDesktop {
                watchingDesktop = false
                if registry.injector === self {
                    registry.injector = nil
                    input.releaseHeld()
                }
                media.watcherLeft(hasWatchers: !registry.watchers.isEmpty)
                input.watcherLeft(hasWatchers: !registry.watchers.isEmpty)
                print(Log.stamp(), "ledgehostd: \(label) unselected the desktop")
            }
            sendWindowList(context: context, active: .none)
        case .window(let id):
            // This host lists no windows; the client re-asserts the
            // current source through the list.
            print(Log.stamp(), "ledgehostd: \(label) selected window \(id) — no windows on this host")
            sendWindowList(context: context, active: watchingDesktop ? .desktop : .none)
        }
    }

    /// kind 8 → op records for the input helper. Only the injector
    /// session (most recent .desktop selector) may inject; events are
    /// rate-capped at 240/s and validated by the translator before
    /// they reach XTest (the helper re-validates, defence in depth).
    /// Logging shows the SHAPE only — event kind, HID usage, modifier
    /// bits — never text payloads or key identities beyond usages.
    private func handleInput(payload: Data) {
        guard let ev = Wire.decode(InputEvent.self, from: payload) else { return }
        switch ev {
        case .pointer(let a, let x, let y):
            print(Log.stamp(), "ledgehostd: input \(label): pointer \(a.rawValue) x\(Int(x*1000))y\(Int(y*1000))")
        case .scroll(_, _, let dx, let dy):
            print(Log.stamp(), "ledgehostd: input \(label): scroll dx\(Int(dx*1000)) dy\(Int(dy*1000))")
        case .text(let s):
            print(Log.stamp(), "ledgehostd: input \(label): text (n=\(s.utf8.count))")
        case .key(let u, let d, let m):
            print(Log.stamp(), "ledgehostd: input \(label): key hid=0x\(String(u, radix: 16)) down=\(d) mods=0x\(String(m, radix: 16))")
        case .scrollGesture(let phase, _, _):
            print(Log.stamp(), "ledgehostd: input \(label): scrollGesture \(phase.rawValue)")
        }
        guard registry.injector === self else { return }
        guard watcher.rateLimiter.allow(now: Date().timeIntervalSince1970) else { return }
        if let records = watcher.translator.translate(ev) {
            input.send(records)
        }
    }

    /// kind 32 clipboard (ClipboardPolicy): a decodable message
    /// subscribes; a non-empty text becomes the host clipboard and is
    /// relayed verbatim to every OTHER subscriber; stop wins. Refusals
    /// (undecodable, oversize, rate) are silent. Content is never
    /// logged — sizes and counts only.
    private func handleClipboard(context: ChannelHandlerContext, payload: Data) {
        guard payload.count <= ClipboardPolicy.maxPayload else { return }
        let (ask, kept) = ClipboardPolicy.hostReceives(payload,
                                                       arrivals: clipboardArrivals,
                                                       now: Date().timeIntervalSince1970)
        clipboardArrivals = kept
        switch ask {
        case .subscribe:
            if !clipboardSubscribed {
                clipboardSubscribed = true
                print(Log.stamp(), "ledgehostd: \(label) subscribed to the clipboard")
            }
        case .set(let text):
            clipboardSubscribed = true
            print(Log.stamp(), "ledgehostd: \(label) set the clipboard (\(text.utf8.count) bytes)")
            deviceSetText = text          // echo suppression, defence in depth
            input.setClipboard(text)
            for other in registry.sessions.values where other !== self && other.clipboardSubscribed {
                other.send(kind: .clipboard, payload: payload)
            }
        case .stop:
            if clipboardSubscribed {
                clipboardSubscribed = false
                print(Log.stamp(), "ledgehostd: \(label) unsubscribed from the clipboard")
            }
        case .refuse(let why):
            print(Log.stamp(), "ledgehostd: \(label) clipboard refused (\(why))")
        }
    }

    private func handleViewport(payload: Data) {
        guard let v = Wire.decode(Viewport.self, from: payload) else {
            print(Log.stamp(), "ledgehostd: viewport from \(label): undecodable — ignored")
            return
        }
        if let why = ViewportBounds.refusal(v) {
            print(Log.stamp(), "ledgehostd: viewport from \(label) refused: \(why)")
            return
        }
        let wanted = min(max(v.fps ?? 60, 24), settings.maxFPS)
        if wanted != watcher.wantedFPS {
            watcher.wantedFPS = wanted
            print(Log.stamp(), "ledgehostd: \(label) wants \(wanted) fps (stream max \(registry.maxWantedFPS))")
            if registry.maxWantedFPS != media.runningInfo.fps {
                media.restart()
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
        if let v = change.maxFPS, SettingsChoices.maxFPS.contains(v) {
            if settings.maxFPS != v {
                settings.maxFPS = v
                applied.append("maxFPS=\(v)")
            }
        }
        if let v = change.bitrate, SettingsChoices.bitrate.contains(v) {
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
        if let v = change.bitrate, SettingsChoices.bitrate.contains(v) {
            media.setBitrate(v)
        }
        if applied.contains(where: { $0.hasPrefix("maxFPS") }) {
            for w in registry.watchers { w.watcher.wantedFPS = min(w.watcher.wantedFPS, settings.maxFPS) }
            if registry.maxWantedFPS != media.runningInfo.fps { media.restart() }
        }
        print(Log.stamp(), "ledgehostd: \(label) changed settings: \(applied.isEmpty ? "none applied" : applied.joined(separator: " "))\(ignored.isEmpty ? "" : " — ignored: \(ignored.joined(separator: ", "))")")
        send(context: context, kind: .hostSettings, payload: Wire.encode(settingsState(answering: change.token)))
    }

    private func sendWindowList(context: ChannelHandlerContext, active: StreamSource) {
        let list = WindowList(macName: identity.name, windows: [], active: active,
                              launchID: identity.launchID, hostVersion: "0.0.0-linux",
                              protocol: 1, clipboard: ClipboardPolicy.generation)
        send(context: context, kind: .windowList, payload: Wire.encode(list))
    }

    private func settingsState(answering: Int? = nil) -> HostSettingsState {
        HostSettingsState(
            settings: settings,
            // Settings live in memory only — a daemon restart returns to
            // compiled defaults, so the client must not mark them saved.
            persistent: false, virtualDisplayAvailable: false,
            virtualDisplayNote: "virtual display is not available on this host",
            softwareEncoder: false,
            stream: media.runningInfo.fps > 0
                ? RunningStream(width: media.runningInfo.width, height: media.runningInfo.height,
                                fps: media.runningInfo.fps, mbps: media.runningInfo.mbps,
                                onVirtualDisplay: false)
                : nil,
            answering: answering,
            sessionPaired: true)
    }

    private func sendCatalog(context: ChannelHandlerContext) {
        sendWindowList(context: context, active: .none)
        send(context: context, kind: .hostSettings, payload: Wire.encode(settingsState()))
        let info = MacInfo(v: 1, macID: identity.macID, name: identity.name,
                           issuedAt: Date().timeIntervalSince1970, remoteAccess: false,
                           remotePort: port, internet: false, addresses: [])
        if let signed = SignedMacInfo.signing(info, with: identity.privateKey) {
            send(context: context, kind: .macInfo, payload: Wire.encode(signed))
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        channel = context.channel
        label = peer.fingerprint.map { RemoteIdentityShortName($0) } ?? context.channel.remoteAddress.map { "\($0)" } ?? "?"
        context.fireChannelActive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        updateDropping()
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        tick?.cancel()
        deadline?.cancel()
        if watchingDesktop {
            watchingDesktop = false
            if registry.injector === self {
                registry.injector = nil
                input.releaseHeld()
            }
            media.watcherLeft(hasWatchers: !registry.watchers.isEmpty)
            input.watcherLeft(hasWatchers: !registry.watchers.isEmpty)
        }
        clipboardSubscribed = false
        clipboardArrivals = []
        registry.sessions.removeValue(forKey: key)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print(Log.stamp(), "ledgehostd: connection error \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Server

wireMediaService()
defer {
    media.shutdown()
    input.shutdown()
    try? group.syncShutdownGracefully()
}

// Live revocation: re-read the pin store every 2 s; a fingerprint that
// disappeared loses its live sessions and any input it held.
eventLoop.scheduleRepeatedTask(initialDelay: .seconds(2), delay: .seconds(2)) { _ in
    pins.reload()
    for session in registry.sessions.values {
        if let fp = session.peerFingerprint, !pins.isPinned(fp) {
            print(Log.stamp(), "ledgehostd: revoked pin — closing session \(session.label)")
            session.send(kind: .goodbye, payload: Wire.encode(Goodbye(reason: "removed", reconnect: false)))
            session.closeSoon()
        }
    }
}

let cert = try NIOSSLCertificate(bytes: [UInt8](identity.certificateDER), format: .der)
let keyPEM = "-----BEGIN EC PRIVATE KEY-----\n"
    + identity.privateKey.derRepresentation.base64EncodedString()
    + "\n-----END EC PRIVATE KEY-----\n"
let privateKey = try NIOSSLPrivateKey(bytes: [UInt8](keyPEM.utf8), format: .pem)

var tlsConfig = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.certificate(cert)],
    privateKey: .privateKey(privateKey)
)
tlsConfig.minimumTLSVersion = .tlsv13
tlsConfig.maximumTLSVersion = .tlsv13
tlsConfig.certificateVerification = .noHostnameVerification
tlsConfig.applicationProtocols = ["sill/1", "sill-pair/1"]
let sslContext = try NIOSSLContext(configuration: tlsConfig)

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 8)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        let peer = PeerBox()
        let callback: NIOSSLCustomVerificationCallback = { certs, promise in
            guard let first = certs.first, let fp = peerFingerprint(first) else {
                promise.succeed(.failed)
                return
            }
            peer.fingerprint = fp
            promise.succeed(.certificateVerified)
        }
        return channel.pipeline.addHandler(
            try! NIOSSLServerHandler(context: sslContext, customVerificationCallback: callback)
        ).flatMap {
            channel.pipeline.addHandler(ConnectionHandler(peer: peer))
        }
    }

let server = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
print(Log.stamp(), "ledgehostd: listening on port \(port)")

// Clean shutdown: stop advertising, close the listener.
let cleanup: @convention(c) (Int32) -> Void = { _ in
    avahi?.terminate()
    exit(0)
}
signal(SIGINT, cleanup)
signal(SIGTERM, cleanup)

try server.closeFuture.wait()
