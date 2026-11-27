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

// M0.5 spike (see docs/phase-0-plan.md): a throwaway TLS server that
// retires the two riskiest unknowns against the real client before
// M2/M3 are built on top:
//   1. the client's TLS stack accepts a hand-built self-signed P-256
//      certificate (vendored SelfSignedCertificate) via NIOSSL, and
//   2. discovery (Avahi, run separately) makes the host appear.
//
// Design, per the Phase 0 plan:
// - the NIOSSL verification callback cannot see the negotiated ALPN,
//   so it only checks "peer certificate is P-256" and computes the
//   pin (SHA-256 of the SPKI, via BoringSSL's SPKI bytes — the parity
//   check against the vendored hand-built SPKI);
// - after the handshake, a gate reads the negotiated ALPN and the
//   fingerprint: sill/1 requires a pinned fingerprint (the spike pins
//   none, so it closes), sill-pair/1 proceeds to log the first frame
//   header, anything else closes. No application decoder is installed
//   before the gate.
//
// Usage: tls-spike [port]   (default 7455)
// Advertise separately, e.g.:
//   avahi-publish-service <hostname> _sill._tcp 7455 p=1 r=<tag>

let port = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 7455 : 7455

// Identity: a fresh key per run is fine for the spike (M2 persists it).
let hostKey = RemoteKey.generate()
guard let certDER = SelfSignedCertificate.make(key: hostKey) else {
    fputs("spike: could not build the self-signed certificate\n", stderr)
    exit(1)
}
let hostFingerprint = SPKI.fingerprint(of: hostKey)
print("spike: host fingerprint \(Base64URL.encode(hostFingerprint))")
print("spike: mac id \(MacID.make(fingerprint: hostFingerprint))")
print("spike: certificate \(certDER.count) bytes")

/// The fixed 26-byte head of a P-256 SPKI (SEQUENCE, the two algorithm
/// OIDs, BIT STRING header) as the vendored SPKI.der builds it.
let p256SPKIHead: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]

/// SHA-256 of a peer certificate's SPKI when it is a P-256 key, else nil.
/// Also the parity check: BoringSSL's SPKI bytes must equal the vendored
/// hand-built SPKI for the same point, byte for byte.
func peerFingerprint(_ certificate: NIOSSLCertificate) -> Data? {
    guard let spki = try? certificate.extractPublicKey().toSPKIBytes(), spki.count == 91,
          [UInt8](spki.prefix(p256SPKIHead.count)) == p256SPKIHead else { return nil }
    return Data(SHA256.hash(data: spki))
}

final class SpikeHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var fingerprint: Data?

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted(let negotiatedProtocol):
                let alpn = negotiatedProtocol ?? "(none)"
                print("spike: handshake completed, ALPN \(alpn)")
                // The post-handshake gate.
                switch negotiatedProtocol {
                case "sill-pair/1":
                    print("spike: gate: pairing door — waiting for the first frame")
                case "sill/1":
                    print("spike: gate: session door but no pin is registered in the spike — closing")
                    context.close(promise: nil)
                default:
                    print("spike: gate: unexpected ALPN — closing")
                    context.close(promise: nil)
                }
            case .shutdownCompleted:
                print("spike: TLS shutdown completed")
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        if bytes.count >= 14 {
            let kind = bytes[0]
            let payloadLength = UInt32(bytes[10]) << 24 | UInt32(bytes[11]) << 16 | UInt32(bytes[12]) << 8 | UInt32(bytes[13])
            print("spike: first frame: kind \(kind), payloadLength \(payloadLength), \(bytes.count) bytes in this read")
        } else {
            print("spike: read \(bytes.count) bytes (shorter than a frame header)")
        }
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("spike: error \(error)")
        context.close(promise: nil)
    }
}

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

let cert = try NIOSSLCertificate(bytes: [UInt8](certDER), format: .der)
// swift-crypto's P-256 private key as SEC1 DER ("EC PRIVATE KEY" PEM for NIOSSL).
let keyPEM = "-----BEGIN EC PRIVATE KEY-----\n"
    + hostKey.derRepresentation.base64EncodedString()
    + "\n-----END EC PRIVATE KEY-----\n"
let key = try NIOSSLPrivateKey(bytes: [UInt8](keyPEM.utf8), format: .pem)

var tlsConfig = TLSConfiguration.makeServerConfiguration(
    certificateChain: [.certificate(cert)],
    privateKey: .privateKey(key)
)
tlsConfig.minimumTLSVersion = .tlsv13
tlsConfig.maximumTLSVersion = .tlsv13
tlsConfig.certificateVerification = .noHostnameVerification  // names mean nothing to a pin; the callback + post-handshake gate decide
tlsConfig.applicationProtocols = ["sill/1", "sill-pair/1"]
// The verification callback cannot see the ALPN; it only establishes
// "P-256 peer" and logs the pin. The ALPN/pin gate runs after the
// handshake, in SpikeHandler.
let verificationCallback: NIOSSLCustomVerificationCallback = { certs, promise in
    guard let first = certs.first, let fp = peerFingerprint(first) else {
        promise.succeed(.failed)
        return
    }
    print("spike: peer certificate is P-256, fingerprint \(Base64URL.encode(fp))")
    promise.succeed(.certificateVerified)
}

let sslContext = try NIOSSLContext(configuration: tlsConfig)
let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 4)
    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.addHandler(try! NIOSSLServerHandler(context: sslContext, customVerificationCallback: verificationCallback)).flatMap {
            channel.pipeline.addHandler(SpikeHandler())
        }
    }

let server = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
print("spike: listening on port \(port) (TLS 1.3, ALPN sill/1 + sill-pair/1, client cert required)")
try server.closeFuture.wait()
