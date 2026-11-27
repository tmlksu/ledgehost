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

// ledgehost-probe — the reference client (Phase 0 plan, M3): a headless
// Linux client speaking the same protocol, so the host's handshake can
// be regression-tested without a device.
//
//   ledgehost-probe pair    --host H --port P --code 482913557208
//   ledgehost-probe connect --host H --port P
//   ledgehost-probe record  --host H --port P --seconds N --out DIR
//                           (subscribes to the desktop, saves kind 0/1
//                           payloads plus a reassembled .h265 stream)
//   ledgehost-probe input   --host H --port P --script "SCRIPT"
//                           (subscribes to the desktop, sends the
//                           scripted kind 8 events; see inputScript)
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
    var seconds: Double = 10
    var out: String = "recording"
    var script: String = ""
    var stall: Double = 0
    var text: String = ""
    var show = false
    var count = 1
    var stop = false
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
        case "--seconds": args.seconds = Double(it.next() ?? "") ?? args.seconds
        case "--out": args.out = it.next() ?? args.out
        case "--script": args.script = it.next() ?? args.script
        case "--text": args.text = it.next() ?? args.text
        case "--show": args.show = true
        case "--count": args.count = Int(it.next() ?? "") ?? args.count
        case "--stop": args.stop = true
        case "--stall": args.stall = Double(it.next() ?? "") ?? args.stall
        default: break
        }
    }
    return args
}

let args = parseArgs()
guard ["pair", "connect", "record", "input", "clipboard"].contains(args.mode) else {
    fputs("usage: ledgehost-probe pair --code <12 digits> [--host H] [--port P]\n       ledgehost-probe connect [--host H] [--port P]\n       ledgehost-probe record [--host H] [--port P] [--seconds N] [--out DIR]\n", stderr)
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
    var onMessage: ((StreamMessageKind, Data, Double) -> Void)?
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
            onMessage?(header.kind, payload, header.timestamp)
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

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
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
    collector.onMessage = { kind, payload, _ts in
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
} else if args.mode == "record" {
    // P1-M1 record mode: subscribe to the desktop, save every kind 0/1
    // payload with its header flags and timestamp, and reassemble an
    // Annex B elementary stream for ffprobe verification.
    guard let saved = savedHost else {
        fputs("probe: no saved host — pair first\n", stderr); exit(64)
    }
    let outDir = URL(fileURLWithPath: args.out)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let framesURL = outDir.appendingPathComponent("frames")
    let streamURL = outDir.appendingPathComponent("stream.h265")
    let metaURL = outDir.appendingPathComponent("record.jsonl")
    try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: streamURL.path, contents: nil)
    FileManager.default.createFile(atPath: metaURL.path, contents: nil)
    let streamOut = try FileHandle(forWritingTo: streamURL)
    let metaOut = try FileHandle(forWritingTo: metaURL)

    let hostBox = HostBox()
    let collector = Collector()
    var parameterSets: [Data] = []
    var frameIndex = 0
    var listSeen = false
    var firstFrame = false
    var firstFrameAt: Date?
    var selectSentAt = Date.distantPast
    var frameAges: [Double] = []
    collector.onMessage = { kind, payload, ts in
        switch kind {
        case .windowList:
            listSeen = true
        case .parameterSets:
            guard let ps = ParameterSets(encoded: payload) else {
                print("probe: undecodable kind 0 — ignored"); return
            }
            parameterSets = ps.sets
            for s in ps.sets { try? streamOut.write(contentsOf: AnnexB.startCoded(s)) }
            try? metaOut.write(contentsOf: Data(
                "{\"k\":0,\"sets\":\(ps.sets.count),\"nalLen\":\(ps.nalUnitHeaderLength)}\n".utf8))
        case .frame:
            let c = frameIndex
            frameIndex += 1
            let name = String(format: "frame-%05d.lp", c)
            try? payload.write(to: framesURL.appendingPathComponent(name))
            guard let nals = WireReassemble.splitLengthPrefixed(payload) else {
                print("probe: frame \(c) does not split as length-prefixed NALs — skipped")
                return
            }
            for n in nals { try? streamOut.write(contentsOf: AnnexB.startCoded(n)) }
            let types = nals.map { ($0[$0.startIndex] >> 1) & 0x3f }
            let age = Date().timeIntervalSince1970 * 1000 - ts * 1000
            frameAges.append(age)
            if firstFrameAt == nil {
                firstFrameAt = Date()
                print("probe: first frame \(Int(Date().timeIntervalSince(selectSentAt) * 1000)) ms after selectSource")
            }
            try? metaOut.write(contentsOf: Data(
                "{\"k\":1,\"i\":\(c),\"bytes\":\(payload.count),\"idr\":\(types.contains(19) || types.contains(20)),\"age\":\(Int(age))}\n".utf8))
            firstFrame = true
        default: break
        }
    }
    let channel = try connect(alpn: "sill/1", hostBox: hostBox, collector: collector)
    guard waitFor(5, until: { hostBox.fingerprint != nil }) else {
        fputs("probe: handshake did not complete\n", stderr); exit(1)
    }
    guard Base64URL.encode(hostBox.fingerprint!) == saved.fingerprint else {
        print("probe: PIN MISMATCH — refusing"); try? channel.close().wait(); exit(1)
    }
    send(channel, kind: .hello, payload: Wire.encode(Hello(appVersion: "0.0.0-probe", protocol: 1,
                                                           device: "ledgehost-probe", audio: [])))
    guard waitFor(5, until: { listSeen }) else {
        fputs("probe: no window list received\n", stderr); exit(1)
    }
    selectSentAt = Date()
    send(channel, kind: .selectSource, payload: Wire.encode(StreamSource.desktop))
    // per-second ClientStats like a real client (P1-M4 soak)
    channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { _ in
        send(channel, kind: .clientStats, payload: Wire.encode(
            ClientStats(fps: frameIndex, frameAgeMs: Int(frameAges.last ?? -1), rttMs: 0, device: "ledgehost-probe")))
    }
    if args.stall > 0 {
        // P1-M4 drop-policy probe: wait for ~30 frames, then stop
        // reading until the high-water policy kicks in, then resume.
        channel.eventLoop.execute { [channel] in
            var waited = 0
            func poll() {
                if frameIndex >= 30 || waited > 40 {
                    print("probe: stalling reads for \(args.stall) s (at frame \(frameIndex))")
                    _ = channel.setOption(ChannelOptions.autoRead, value: false)
                    channel.eventLoop.scheduleTask(in: .seconds(Int64(args.stall))) {
                        _ = channel.setOption(ChannelOptions.autoRead, value: true)
                        print("probe: resumed reads")
                    }
                    return
                }
                waited += 1
                channel.eventLoop.scheduleTask(in: .milliseconds(250)) { poll() }
            }
            poll()
        }
    }
    _ = waitFor(args.seconds + args.stall + 8, until: { false })
    if !frameAges.isEmpty {
        let sorted = frameAges.sorted()
        print("probe: frameAge p50 \(Int(sorted[sorted.count / 2])) ms max \(Int(sorted.last ?? -1)) ms; frames \(frameIndex) (~\(Int(Double(frameIndex) / args.seconds)) fps)")
    }
    try? channel.close().wait()
    try? streamOut.close()
    try? metaOut.close()
    print("probe: recorded \(frameIndex) frame(s), \(parameterSets.count) parameter set(s) -> \(outDir.path)")
    print("probe: verify with: ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames,width,height,coded_width,coded_height -of default=nw=1 \(streamURL.path)")
    exit(firstFrame && !parameterSets.isEmpty ? 0 : 1)
} else if args.mode == "clipboard" {
    // P2 clipboard mode: subscribe ({}), optionally send --text
    // (--count times), report received kind 32s by size and hash;
    // --show prints the synthetic text itself.
    guard let saved = savedHost else {
        fputs("probe: no saved host — pair first\n", stderr); exit(64)
    }
    let hostBox = HostBox()
    let collector = Collector()
    var listSeen = false
    var received = 0
    collector.onMessage = { kind, payload, _ts in
        if kind == .windowList { listSeen = true }
        guard kind == .clipboard else { return }
        received += 1
        let clip = Wire.decode(Clipboard.self, from: payload)
        let hash = clip?.text.map { String(SHA256.hash(data: Data($0.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()) } ?? "-"
        print("probe: clipboard #\(received): \(payload.count)B json, text \(clip?.text?.utf8.count ?? 0)B sha8=\(hash)")
        if args.show, let t = clip?.text { print("probe: text: \(t)") }
    }
    let channel = try connect(alpn: "sill/1", hostBox: hostBox, collector: collector)
    guard waitFor(5, until: { hostBox.fingerprint != nil }),
          Base64URL.encode(hostBox.fingerprint!) == saved.fingerprint else {
        print("probe: handshake/pin failure"); try? channel.close().wait(); exit(1)
    }
    send(channel, kind: .hello, payload: Wire.encode(Hello(appVersion: "0.0.0-probe", protocol: 1,
                                                           device: "ledgehost-probe", audio: [])))
    guard waitFor(5, until: { listSeen }) else {
        fputs("probe: no window list\n", stderr); exit(1)
    }
    send(channel, kind: .selectSource, payload: Wire.encode(StreamSource.desktop))
    send(channel, kind: .clipboard, payload: ClipboardPolicy.subscription)
    if args.stop {
        send(channel, kind: .clipboard, payload: ClipboardPolicy.stopping)
        _ = waitFor(1, until: { false })
    }
    let sendText = args.text == "@big" ? String(repeating: "X", count: 300 * 1024) : args.text
    if !sendText.isEmpty {
        for i in 0..<args.count {
            send(channel, kind: .clipboard, payload: Wire.encode(Clipboard(text: sendText)))
            if args.count > 1 { Thread.sleep(forTimeInterval: 0.05) }
            _ = i
        }
    }
    _ = waitFor(args.seconds, until: { false })
    try? channel.close().wait()
    print("probe: CLIPBOARD DONE \(received) received")
    exit(0)
} else if args.mode == "input" {
    // P1-M3 synthetic input: subscribe to the desktop, then replay a
    // semicolon-separated script of kind 8 events:
    //   move X Y | down X Y | up X Y | rdown X Y | rup X Y
    //   scroll DX DY | key USAGE[hex] [down|up] [MODS[hex]]
    //   text STRING | stats
    guard let saved = savedHost else {
        fputs("probe: no saved host — pair first\n", stderr); exit(64)
    }
    let hostBox = HostBox()
    let collector = Collector()
    var listSeen = false
    var gotSets = false, gotFrame = false
    collector.onMessage = { kind, _, _ts in
        if kind == .windowList { listSeen = true }
        if kind == .parameterSets { gotSets = true }
        if kind == .frame { gotFrame = true }
    }
    let channel = try connect(alpn: "sill/1", hostBox: hostBox, collector: collector)
    guard waitFor(5, until: { hostBox.fingerprint != nil }),
          Base64URL.encode(hostBox.fingerprint!) == saved.fingerprint else {
        print("probe: handshake/pin failure"); try? channel.close().wait(); exit(1)
    }
    send(channel, kind: .hello, payload: Wire.encode(Hello(appVersion: "0.0.0-probe", protocol: 1,
                                                           device: "ledgehost-probe", audio: [])))
    guard waitFor(5, until: { listSeen }) else {
        fputs("probe: no window list\n", stderr); exit(1)
    }
    send(channel, kind: .selectSource, payload: Wire.encode(StreamSource.desktop))
    _ = waitFor(3, until: { gotSets && gotFrame })
    func num(_ s: String) -> Double {
        let t = s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
        return s.hasPrefix("0x")
            ? Double(UInt64(t, radix: 16) ?? 0) : (Double(t) ?? 0)
    }
    for (i, step) in args.script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).enumerated() {
        let f = step.split(separator: " ").map(String.init)
        guard !f.isEmpty else { continue }
        let ev: InputEvent?
        switch f[0] {
        case "move":   ev = .pointer(.move, x: num(f[safe: 1] ?? "0"), y: num(f[safe: 2] ?? "0"))
        case "down":   ev = .pointer(.leftDown, x: num(f[safe: 1] ?? "0"), y: num(f[safe: 2] ?? "0"))
        case "up":     ev = .pointer(.leftUp, x: num(f[safe: 1] ?? "0"), y: num(f[safe: 2] ?? "0"))
        case "rdown":  ev = .pointer(.rightDown, x: num(f[safe: 1] ?? "0"), y: num(f[safe: 2] ?? "0"))
        case "rup":    ev = .pointer(.rightUp, x: num(f[safe: 1] ?? "0"), y: num(f[safe: 2] ?? "0"))
        case "scroll":
            // "scroll dx dy" scrolls at the frame centre; "scroll x y dx dy"
            // scrolls at explicit coordinates (the S-E wire semantics).
            if f.count >= 5 {
                ev = .scroll(x: num(f[safe: 1] ?? "0.5"), y: num(f[safe: 2] ?? "0.5"),
                             dx: num(f[safe: 3] ?? "0"), dy: num(f[safe: 4] ?? "0"))
            } else {
                ev = .scroll(x: 0.5, y: 0.5, dx: num(f[safe: 1] ?? "0"), dy: num(f[safe: 2] ?? "0"))
            }
        case "key":    ev = .key(hidUsage: UInt16(num(f[safe: 1] ?? "0")),
                                 down: (f[safe: 2] ?? "down") == "down",
                                 modifiers: UInt64(num(f[safe: 3] ?? "0")))
        case "text":   ev = .text(f.dropFirst().joined(separator: " "))
        case "stats":  ev = nil
            ; send(channel, kind: .clientStats, payload: Wire.encode(
                ClientStats(fps: 60, frameAgeMs: 0, rttMs: 0, device: "ledgehost-probe")))
        case "bitrate": ev = nil
            ; send(channel, kind: .changeSettings, payload: Wire.encode(
                HostSettingsChange(token: i + 1, bitrate: Int(num(f[safe: 1] ?? "15000000")))))
        case "fps": ev = nil
            ; send(channel, kind: .changeSettings, payload: Wire.encode(
                HostSettingsChange(token: i + 1, maxFPS: Int(num(f[safe: 1] ?? "60")))))
        case "viewport": ev = nil
            ; send(channel, kind: .viewport, payload: Wire.encode(
                Viewport(width: 1600, height: 1200, scale: 1, fps: Int(num(f[safe: 1] ?? "60")))))
        case "sleep":  ev = nil; Thread.sleep(forTimeInterval: num(f[safe: 1] ?? "1"))
        default:
            print("probe: unknown script step '\(f[0])'"); ev = nil
        }
        if let ev {
            send(channel, kind: .input, payload: Wire.encode(ev))
            print("probe: sent step \(i): \(f[0])")
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
    try? channel.close().wait()
    print("probe: INPUT DONE")
    exit(0)
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
    collector.onMessage = { kind, payload, _ts in
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
