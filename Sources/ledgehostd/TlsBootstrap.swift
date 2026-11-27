import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import LedgehostCore

// TLS bootstrap (audit R1/R-1): the P-256 pin shape shared with the
// probe, the server context, and the channel-pipeline assembly.
//
// The verification callback establishes only "P-256 peer" and the pin
// (SHA-256 of BoringSSL's SPKI bytes); the ALPN/pin gate runs after the
// handshake in ConnectionHandler, and no application decoder touches
// bytes before the gate passes.

/// DER head of a P-256 SubjectPublicKeyInfo. Mirrors the probe's copy —
/// the fingerprint rule must not drift (audit R4); the shared constant
/// lives in LedgehostCore (PeerFingerprint.spkiHead) once item R-3 lands.
let p256SPKIHead: [UInt8] = [
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
]

func peerFingerprint(_ certificate: NIOSSLCertificate) -> Data? {
    guard let spki = try? certificate.extractPublicKey().toSPKIBytes(), spki.count == 91,
          [UInt8](spki.prefix(p256SPKIHead.count)) == p256SPKIHead else { return nil }
    return Data(SHA256.hash(data: spki))
}

/// The handshake's carry from the TLS callback to the session handler:
/// the peer's verified SPKI fingerprint.
final class PeerBox: @unchecked Sendable {
    var fingerprint: Data?
}

/// TLS 1.3, our certificate only, both doors' ALPNs.
func serverTLSContext(identity: HostIdentity) throws -> NIOSSLContext {
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
    return try NIOSSLContext(configuration: tlsConfig)
}

/// Listener pipeline: TLS with the SPKI-pin callback, then the session
/// state machine. Every accepted connection runs the daemon's one
/// event loop.
func makeServerBootstrap(group: EventLoopGroup, sslContext: NIOSSLContext) -> ServerBootstrap {
    ServerBootstrap(group: group)
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
}
