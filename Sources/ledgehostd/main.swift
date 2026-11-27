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

// ledgehostd — wiring only (audit R1/R-1): identity + stores, discovery,
// the shared session state, service construction, the media fan-out,
// timers, and the event-loop entry. The session state machine lives in
// ConnectionHandler.swift, TLS in TlsBootstrap.swift, the catalog in
// Catalog.swift, kind 32 in ClipboardRelay.swift.
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

// MARK: - Shared session state
//
// Globals owned by main: the advertised settings and the session
// registry. Per-connection state lives on ConnectionHandler; the
// injector slot lives in ConnectionHandler.swift's registry extension;
// the clipboard echo token lives in ClipboardRelay.swift.

var settings = StreamSettings(maxFPS: 60, bitrate: 15_000_000, captureScale: 1,
                              prioritizeSpeed: true, virtualDisplay: false,
                              directWireless: nil, sendAudio: nil)
let registry = SessionRegistry()

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let eventLoop = group.next()

// MARK: - Services

let processEnv = ProcessInfo.processInfo.environment
let targetDisplay = processEnv["DISPLAY"] ?? ""
let media = MediaService(group: group,
                         display: targetDisplay,
                         xauthority: processEnv["XAUTHORITY"],
                         fpsSource: { registry.maxWantedFPS(of: $0) })
let input = InputService(group: group,
                         display: targetDisplay,
                         xauthority: processEnv["XAUTHORITY"])
let windows = WindowTracker(loop: eventLoop,
                            display: targetDisplay,
                            xauthority: processEnv["XAUTHORITY"])
wireClipboardRelay()      // input.onClipboard -> subscribed sessions

// MARK: - Media fan-out (kind 0/1 to every watcher)

func buildMessage(_ kind: StreamMessageKind, timestamp: Double, keyframe: Bool, payload: Data) -> ByteBuffer {
    let message = StreamMessage(kind: kind, timestamp: timestamp, isKeyframe: keyframe, payload: payload)
    var buf = ByteBufferAllocator().buffer(capacity: payload.count + StreamMessage.headerLength)
    buf.writeBytes(message.serialized())
    return buf
}

func wireMediaService() {
    media.onSetsChanged = { source, payload in
        var buf = buildMessage(.parameterSets, timestamp: Date().timeIntervalSince1970,
                               keyframe: true, payload: payload)
        // kind 0 is never dropped — a session that cannot take it must
        // wait for the resume path's copy, not lose the sets.
        for session in registry.watchers(of: source) {
            session.deliver(buf.readSlice(length: buf.readableBytes) ?? buf)
        }
    }
    media.onFrame = { source, ts, au, isIDR in
        var frameBuf = buildMessage(.frame, timestamp: ts, keyframe: isIDR, payload: au.frame)
        for session in registry.watchers(of: source) {
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
                if let sets = media.setsPayload(source) {
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
    media.onGiveUp = { source in
        // A pipeline that cannot stay up gives up only its own
        // watchers — sessions on other sources are unaffected.
        let goodbye = Wire.encode(Goodbye(reason: "quit",
                                          message: "The stream could not start on this host.",
                                          reconnect: true))
        for session in registry.watchers(of: source) {
            session.send(kind: .goodbye, payload: goodbye)
            session.closeSoon()
        }
    }
    // Live window lists: tracker changes fan out to every session
    // (each also follows its watched window or drops a gone one).
    windows.onChange = {
        for session in registry.sessions.values {
            session.windowListChanged()
        }
    }
    windows.start()
}

// MARK: - Server

wireMediaService()
defer {
    media.shutdown()
    input.shutdown()
    try? group.syncShutdownGracefully()
}

// Pairing credential expiry (audit S11/F4): while unpaired a printed
// code stays valid indefinitely, so code + QR secret rotate on a timer
// independent of pairing attempts — a code's lifetime is ≤ 10 min.
eventLoop.scheduleRepeatedTask(initialDelay: .seconds(600), delay: .seconds(600)) { _ in
    pairing.rotate()
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

let sslContext = try serverTLSContext(identity: identity)
let bootstrap = makeServerBootstrap(group: group, sslContext: sslContext,
                                    throttle: ConnThrottle())
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
