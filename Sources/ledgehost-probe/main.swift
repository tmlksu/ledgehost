import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import StreamProtocol

// ledgehost-probe — the reference client (Phase 0 plan, M3): a headless
// Linux client speaking the same protocol, so the host's handshake can
// be regression-tested without a device.
//
//   ledgehost-probe pair    --host H --port P --code 482913557208
//   ledgehost-probe connect --host H --port P
//
// Fingerprints always come from the TLS session, never from a message.
// After pairing, the probe saves the host's fingerprint, Mac ID and
// recognition key; `connect` refuses a host whose TLS fingerprint
// differs from the saved pin.

struct Args {
    var mode: String = ""
    var host: String = "127.0.0.1"
    var port: Int = 7455
    var code: String?
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    args.mode = it.next() ?? ""
    while let a = it.next() {
        switch a {
        case "--host": args.host = it.next() ?? args.host
        case "--port": args.port = Int(it.next() ?? "") ?? args.port
        case "--code": args.code = it.next()
        default: break
        }
    }
    return args
}

let args = parseArgs()
guard args.mode == "pair" || args.mode == "connect" else {
    fputs("usage: ledgehost-probe pair --code <12 digits> [--host H] [--port P]\n       ledgehost-probe connect [--host H] [--port P]\n", stderr)
    exit(64)
}

// MARK: - Probe identity and saved host

func probeConfigDirectory() -> URL {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        base = URL(fileURLWithPath: xdg)
    } else {
        base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }
    return base.appendingPathComponent("ledgehost-probe")
}

struct ProbeIdentityFile: Codable { var keyX963: String }
struct SavedHost: Codable {
    var fingerprint: String   // base64url
    var macID: String
    var recognitionKey: String
    var name: String
}

let dir = probeConfigDirectory()
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
let identityURL = dir.appendingPathComponent("identity.json")
let deviceKey: P256.Signing.PrivateKey
if let data = try? Data(contentsOf: identityURL),
   let file = try? JSONDecoder().decode(ProbeIdentityFile.self, from: data),
   let raw = Data(base64Encoded: file.keyX963),
   let key = try? P256.Signing.PrivateKey(x963Representation: raw) {
    deviceKey = key
} else {
    deviceKey = P256.Signing.PrivateKey()
    let file = ProbeIdentityFile(keyX963: deviceKey.x963Representation.base64EncodedString())
    try? JSONEncoder().encode(file).write(to: identityURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
}
let deviceFingerprint = SPKI.fingerprint(of: deviceKey)
print("probe: device fingerprint \(Base64URL.encode(deviceFingerprint))")

let savedHostURL = dir.appendingPathComponent("host.json")
var savedHost: SavedHost?
if let data = try? Data(contentsOf: savedHostURL) {
    savedHost = try? JSONDecoder().decode(SavedHost.self, from: data)
}

// MARK: - TLS client

let p256SPKIHead: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]

final class HostBox: @unchecked Sendable { var fingerprint: Data? }

func makeClientContext(alpn: String, hostBox: HostBox) throws -> NIOSSLContext {
    // The probe presents its own self-signed certificate (built by the
    // vendored code) as its client identity.
    let der = SelfSignedCertificate.make(key: deviceKey)!
    let cert = try NIOSSLCertificate(bytes: [UInt8](der), format: .der)
    let keyPEM = "-----BEGIN EC PRIVATE KEY-----\n"
        + deviceKey.derRepresentation.base64EncodedString()
        + "\n-----END EC PRIVATE KEY-----\n"
    let key = try NIOSSLPrivateKey(bytes: [UInt8](keyPEM.utf8), format: .pem)
    var config = TLSConfiguration.makeClientConfiguration()
    config.minimumTLSVersion = .tlsv13
    config.maximumTLSVersion = .tlsv13
    config.certificateVerification = .noHostnameVerification
    config.applicationProtocols = [alpn]
    config.certificateChain = [.certificate(cert)]
    config.privateKey = .privateKey(key)
    return try NIOSSLContext(configuration: config)
}

// MARK: - Message channel

final class Collector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    var onMessage: ((StreamMessageKind, Data) -> Void)?
    var onClose: (() -> Void)?
    private var buffer = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) { buffer.append(contentsOf: bytes) }
        while buffer.count >= StreamMessage.headerLength,
              let header = StreamMessage.parseHeader(buffer),
              buffer.count >= StreamMessage.headerLength + header.payloadLength {
            let payload = buffer.subdata(in: buffer.startIndex + StreamMessage.headerLength
                                         ..< buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + StreamMessage.headerLength + header.payloadLength)
            onMessage?(header.kind, payload)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose?()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("probe: error \(error)")
        context.close(promise: nil)
    }
}

func send(_ channel: Channel, kind: StreamMessageKind, payload: Data) {
    let message = StreamMessage(kind: kind, timestamp: Date().timeIntervalSince1970,
                                isKeyframe: false, payload: payload)
    var buf = channel.allocator.buffer(capacity: message.serialized().count)
    buf.writeBytes(message.serialized())
    channel.writeAndFlush(buf, promise: nil)
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

func connect(alpn: String, hostBox: HostBox, collector: Collector) throws -> Channel {
    let context = try makeClientContext(alpn: alpn, hostBox: hostBox)
    let callback: NIOSSLCustomVerificationCallback = { certs, promise in
        guard let first = certs.first,
              let spki = try? first.extractPublicKey().toSPKIBytes(), spki.count == 91,
              [UInt8](spki.prefix(p256SPKIHead.count)) == p256SPKIHead else {
            promise.succeed(.failed)
            return
        }
        hostBox.fingerprint = Data(SHA256.hash(data: spki))
        promise.succeed(.certificateVerified)
    }
    return try ClientBootstrap(group: group)
        .channelInitializer { channel in
            channel.pipeline.addHandler(
                try! NIOSSLClientHandler(context: context, serverHostname: nil, customVerificationCallback: callback)
            ).flatMap { channel.pipeline.addHandler(collector) }
        }
        .connect(host: args.host, port: args.port).wait()
}

func waitFor(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}

// MARK: - Modes

if args.mode == "pair" {
    guard let code = args.code, PairingCode.check(code) == .success(code) else {
        fputs("probe: --code must be a valid 12-digit pairing code\n", stderr)
        exit(64)
    }
    let hostBox = HostBox()
    let collector = Collector()
    var result: PairResult?
    var closed = false
    collector.onMessage = { kind, payload in
        if kind == .pairResult { result = Wire.decode(PairResult.self, from: payload) }
    }
    collector.onClose = { closed = true }
    let channel = try connect(alpn: "sill-pair/1", hostBox: hostBox, collector: collector)
    guard waitFor(5, until: { hostBox.fingerprint != nil }) else {
        fputs("probe: handshake did not complete\n", stderr); exit(1)
    }
    let hostFP = hostBox.fingerprint!
    print("probe: host fingerprint (from TLS) \(Base64URL.encode(hostFP))")
    guard let key = PairingProof.codeKey(code: code, macFingerprint: hostFP) else {
        fputs("probe: code refused locally\n", stderr); exit(1)
    }
    let proof = PairingProof.deviceProof(key: key, deviceFingerprint: deviceFingerprint, macFingerprint: hostFP)
    let request = PairRequest(method: PairRequest.code, proof: Base64URL.encode(proof),
                              name: "ledgehost-probe", model: "linux")
    send(channel, kind: .pairRequest, payload: Wire.encode(request))
    guard waitFor(15, until: { result != nil || closed }) else {
        fputs("probe: no pair result\n", stderr); exit(1)
    }
    guard let result else { fputs("probe: connection closed without a result\n", stderr); exit(1) }
    guard result.ok, let proofM = result.proof.flatMap(Base64URL.decode),
          PairingProof.isValidMacProof(proofM, key: key, macFingerprint: hostFP, deviceFingerprint: deviceFingerprint),
          let macID = result.macID, macID == MacID.make(fingerprint: hostFP),
          let rk = result.recognitionKey else {
        print("probe: PAIRING REFUSED: \(result.reason ?? "?") triesLeft \(result.triesLeft.map(String.init) ?? "-")")
        exit(1)
    }
    let saved = SavedHost(fingerprint: Base64URL.encode(hostFP), macID: macID,
                          recognitionKey: rk, name: result.name ?? "")
    try JSONEncoder().encode(saved).write(to: savedHostURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: savedHostURL.path)
    print("probe: PAIRED with \(saved.name) (\(macID)); pin saved")
    try? channel.close().wait()
} else {
    guard let saved = savedHost else {
        fputs("probe: no saved host — pair first\n", stderr); exit(64)
    }
    let hostBox = HostBox()
    let collector = Collector()
    var kinds: [StreamMessageKind] = []
    var list: WindowList?
    var settingsOK = false
    var macInfoOK = false
    var pong = false
    collector.onMessage = { kind, payload in
        kinds.append(kind)
        switch kind {
        case .windowList: list = Wire.decode(WindowList.self, from: payload)
        case .hostSettings: settingsOK = Wire.decode(HostSettingsState.self, from: payload) != nil
        case .macInfo:
            if let signed = Wire.decode(SignedMacInfo.self, from: payload),
               let verified = signed.verified() {
                macInfoOK = Base64URL.encode(verified.fingerprint) == saved.fingerprint
            }
        case .pong: pong = true
        default: break
        }
    }
    let channel = try connect(alpn: "sill/1", hostBox: hostBox, collector: collector)
    guard waitFor(5, until: { hostBox.fingerprint != nil }) else {
        fputs("probe: handshake did not complete\n", stderr); exit(1)
    }
    guard Base64URL.encode(hostBox.fingerprint!) == saved.fingerprint else {
        print("probe: PIN MISMATCH — the host's TLS fingerprint is not the saved one; refusing")
        try? channel.close().wait()
        exit(1)
    }
    send(channel, kind: .hello, payload: Wire.encode(Hello(appVersion: "0.0.0-probe", protocol: 1,
                                                           device: "ledgehost-probe", audio: [])))
    guard waitFor(5, until: { list != nil }) else {
        fputs("probe: no window list received (kinds so far: \(kinds.map { $0.rawValue }))\n", stderr); exit(1)
    }
    print("probe: window list: mac \(list!.macName), windows \(list!.windows.count), active \(list!.active)")
    send(channel, kind: .ping, payload: Data([1, 2, 3, 4, 5, 6, 7, 8]))
    _ = waitFor(3, until: { pong })
    print("probe: settings \(settingsOK ? "ok" : "MISSING"), signed mac info \(macInfoOK ? "verified" : "MISSING"), pong \(pong ? "ok" : "MISSING")")
    let pass = settingsOK && macInfoOK && pong
    print(pass ? "probe: SESSION PASS" : "probe: SESSION INCOMPLETE")
    try? channel.close().wait()
    exit(pass ? 0 : 1)
}
