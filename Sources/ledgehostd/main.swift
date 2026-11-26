import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import StreamProtocol
#if canImport(Glibc)
import Glibc
#endif

// Logs must reach files and journals unbuffered: a pairing code or a
// gate decision sitting in a stdio buffer helps nobody.
setvbuf(stdout, nil, _IONBF, 0)

// ledgehostd — the Phase 0 host: identity (M2), discovery, the TLS
// doors and the session catalog (M3). No streaming yet (Phase 1);
// a paired device connects, gets the Desktop catalog, and can ping.
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
print("ledgehostd: \(identity.name) — mac id \(identity.macID), fingerprint \(Base64URL.encode(identity.fingerprint))")
print("ledgehostd: \(pins.count) paired device(s); config in \(configDir.path)")

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
        print("ledgehostd: advertising _sill._tcp on port \(port) via avahi (p=1, r=\(tag))")
    } catch {
        print("ledgehostd: avahi-publish-service not available; advertise manually:")
        print("  avahi-publish-service '\(identity.name)' _sill._tcp \(port) p=1 r=\(tag)")
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

    init(peer: PeerBox) { self.peer = peer }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted(let negotiated) = tlsEvent {
            guard let fp = peer.fingerprint else {
                context.close(promise: nil); return
            }
            switch negotiated {
            case "sill-pair/1":
                state = .pairing
                deadline = context.eventLoop.scheduleTask(in: .seconds(10)) { [weak self] in
                    guard let self, self.state == .pairing else { return }
                    print("ledgehostd: pairing connection timed out")
                    context.close(promise: nil)
                }
            case "sill/1":
                if pins.isPinned(fp) {
                    state = .awaitingHello
                    print("ledgehostd: session from paired \(RemoteIdentityShortName(fp))")
                } else {
                    print("ledgehostd: session from unpaired \(RemoteIdentityShortName(fp)) — closing")
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
                print("ledgehostd: payload over the cap (\(header.payloadLength) > \(cap)) — closing")
                context.close(promise: nil); state = .done; return
            }
            guard buffer.count >= StreamMessage.headerLength + header.payloadLength else { return }
            let payload = buffer.subdata(in: buffer.startIndex + StreamMessage.headerLength
                                         ..< buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            handle(context: context, kind: header.kind, payload: payload)
        }
    }

    private func send(context: ChannelHandlerContext, kind: StreamMessageKind, payload: Data) {
        let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
                                    isKeyframe: false, payload: payload)
        var out = context.channel.allocator.buffer(capacity: message.serialized().count)
        out.writeBytes(message.serialized())
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
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
                print("ledgehostd: session's first message was not a Hello — closing")
                context.close(promise: nil); state = .done; return
            }
            print("ledgehostd: hello: app \(hello.appVersion ?? "?") protocol \(hello.protocol ?? -1) device \(hello.device ?? "?") audio \(hello.audio ?? [])")
            state = .session
            sendCatalog(context: context)
            tick = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(10)) { [weak self] _ in
                guard let self, self.state == .session else { return }
                self.send(context: context, kind: .tick, payload: Data())
            }

        case .session:
            switch kind {
            case .ping:
                send(context: context, kind: .pong, payload: payload)
            case .selectSource:
                print("ledgehostd: selectSource \(String(data: payload, encoding: .utf8) ?? "?") (streaming arrives in Phase 1)")
            case .pairingWanted:
                print("ledgehostd: pairingWanted on a session — ignored")
            default:
                print("ledgehostd: session message kind \(kind.rawValue) (\(payload.count) bytes)")
            }

        case .awaitingGate, .done:
            break
        }
    }

    private func sendCatalog(context: ChannelHandlerContext) {
        let list = WindowList(macName: identity.name, windows: [], active: .desktop,
                              launchID: identity.launchID, hostVersion: "0.0.0-linux", protocol: 1)
        send(context: context, kind: .windowList, payload: Wire.encode(list))
        let settings = HostSettingsState(
            settings: StreamSettings(maxFPS: 60, bitrate: 12_000_000, captureScale: 1,
                                     prioritizeSpeed: true, virtualDisplay: false,
                                     directWireless: nil, sendAudio: nil),
            persistent: true, virtualDisplayAvailable: false,
            virtualDisplayNote: "virtual display is not available on this host",
            softwareEncoder: false, sessionPaired: true)
        send(context: context, kind: .hostSettings, payload: Wire.encode(settings))
        let info = MacInfo(v: 1, macID: identity.macID, name: identity.name,
                           issuedAt: Date().timeIntervalSince1970, remoteAccess: false,
                           remotePort: port, internet: false, addresses: [])
        if let signed = SignedMacInfo.signing(info, with: identity.privateKey) {
            send(context: context, kind: .macInfo, payload: Wire.encode(signed))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tick?.cancel()
        deadline?.cancel()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("ledgehostd: connection error \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Server

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

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
print("ledgehostd: listening on port \(port)")

// Clean shutdown: stop advertising, close the listener.
let cleanup: @convention(c) (Int32) -> Void = { _ in
    avahi?.terminate()
    exit(0)
}
signal(SIGINT, cleanup)
signal(SIGTERM, cleanup)

try server.closeFuture.wait()
