import Foundation
import Crypto
import NIO
import NIOCore
import NIOSSL
import NIOTLS
import LedgehostCore

// TLS bootstrap: the P-256 pin shape shared with the
// probe, the server context, and the channel-pipeline assembly.
//
// The verification callback establishes only "P-256 peer" and the pin
// (SHA-256 of BoringSSL's SPKI bytes); the ALPN/pin gate runs after the
// handshake in ConnectionHandler, and no application decoder touches
// bytes before the gate passes.

/// The pin rule is shared with the probe (PeerFingerprint in
/// LedgehostCore,R-3); this is only the NIOSSL glue.
func peerFingerprint(_ certificate: NIOSSLCertificate) -> Data? {
    guard let spki = try? certificate.extractPublicKey().toSPKIBytes() else { return nil }
    return PeerFingerprint.ofSPKI([UInt8](spki))
}

/// The handshake's carry from the TLS callback to the session handler:
/// the peer's verified SPKI fingerprint.
final class PeerBox: @unchecked Sendable {
    var fingerprint: Data?
}

/// Per-source new-connection throttle: a
/// token bucket keyed by remote IP applied BEFORE the TLS handler is
/// installed, so a flooded address pays no handshake crypto.
///   rate 1 conn/s sustained, burst 10 — legitimate use is two iPads
///   reconnecting plus the odd service restart (≤ a handful of
///   connects in a second, then silence); a flood is hundreds.
/// Refusals are logged through a sampler so the flood itself cannot
/// flood the journal. All calls run on the daemon's one event loop.
final class ConnThrottle {
    static let rate = 1.0           // tokens per second
    static let burst = 10.0         // bucket capacity

    private var buckets: [String: (tokens: Double, at: Date)] = [:]
    private var lastSweep = Date.distantPast
    private var refusedLog = LogSampler()

    /// Take one connection token for `addr`; false = refuse early.
    func allow(_ addr: String, now: Date = Date()) -> Bool {
        // Bounded map: sweep entries idle >2 min, at most once a minute.
        if now.timeIntervalSince(lastSweep) > 60 {
            lastSweep = now
            buckets = buckets.filter { now.timeIntervalSince($0.value.at) < 120 }
        }
        var b = buckets[addr] ?? (Self.burst, now)
        b.tokens = min(Self.burst, b.tokens + Self.rate * now.timeIntervalSince(b.at))
        b.at = now
        buckets[addr] = b
        if b.tokens >= 1 { b.tokens -= 1; buckets[addr] = b; return true }
        if let held = refusedLog.emit() {
            print(Log.stamp(), "ledgehostd: connections from \(addr) refused (throttled)\(held > 0 ? " — +\(held) held" : "")")
        }
        return false
    }
}

/// TLS 1.3, our certificate only, both doors' ALPNs.
func serverTLSContext(identity: HostIdentity) throws -> NIOSSLContext {
    let cert = try NIOSSLCertificate(bytes: [UInt8](identity.certificateDER), format: .der)
    let privateKey = try NIOSSLPrivateKey(
        bytes: [UInt8](PeerFingerprint.privateKeyPEM(identity.privateKey).utf8), format: .pem)

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

/// Listener pipeline: per-source connection throttle first (refused addresses never reach TLS), then TLS with the
/// SPKI-pin callback, then the session state machine. Every accepted
/// connection runs the daemon's one event loop.
func makeServerBootstrap(group: EventLoopGroup, sslContext: NIOSSLContext,
                         throttle: ConnThrottle) -> ServerBootstrap {
    ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 8)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            guard let ip = channel.remoteAddress?.ipAddress, throttle.allow(ip) else {
                return channel.close()
            }
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
