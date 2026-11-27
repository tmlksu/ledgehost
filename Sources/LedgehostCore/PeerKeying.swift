import Foundation
import Crypto

// Peer keying shared by ledgehostd and ledgehost-probe (audit R4/R-3):
// the SPKI-pin rule must exist in exactly one place — two copies could
// drift apart, and this check is the entire TLS peer gate.

public enum PeerFingerprint {
    /// DER head of a P-256 SubjectPublicKeyInfo (the SPKI is 91 bytes).
    public static let spkiHead: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ]

    /// The pin both doors verify: SHA-256 of the peer's SPKI bytes,
    /// but only when the SPKI is a P-256 one — anything else is not a
    /// peer this protocol speaks to.
    public static func ofSPKI(_ spki: [UInt8]) -> Data? {
        guard spki.count == 91, [UInt8](spki.prefix(spkiHead.count)) == spkiHead
        else { return nil }
        return Data(SHA256.hash(data: spki))
    }

    /// SEC1 "EC PRIVATE KEY" PEM — the import shape NIOSSLPrivateKey
    /// wants, identical on the daemon and the probe.
    public static func privateKeyPEM(_ key: P256.Signing.PrivateKey) -> String {
        "-----BEGIN EC PRIVATE KEY-----\n"
            + key.derRepresentation.base64EncodedString()
            + "\n-----END EC PRIVATE KEY-----\n"
    }
}
