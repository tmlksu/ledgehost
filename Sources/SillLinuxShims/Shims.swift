import Foundation
import Crypto

// Linux shims for the vendored StreamProtocol module: the small platform
// pieces upstream takes from CommonCrypto and Security.framework.
// Kept out of the vendored tree so the upstream diff stays minimal.

/// PBKDF2 (RFC 2898) with HMAC-SHA256 as the PRF, matching
/// CommonCrypto's CCKeyDerivationPBKDF(kCCPBKDF2, kCCPRFHmacAlgSHA256):
/// block index appended to the salt as a big-endian UInt32, XOR of all
/// iteration outputs. swift-crypto (checked 3.5.2) ships no PBKDF2,
/// so this is the implementation; it is pinned by the RFC 7914 section 11
/// vectors and by the upstream pairing vectors in the test target.
public enum PBKDF2 {
    public static func derive(password: [UInt8], salt: Data, iterations: Int, keyLength: Int) -> Data? {
        guard iterations > 0, keyLength > 0 else { return nil }
        let key = SymmetricKey(data: password)
        let saltBytes = [UInt8](salt)
        var out: [UInt8] = []
        var block: UInt32 = 1
        while out.count < keyLength {
            var msg = saltBytes
            msg.append(UInt8((block >> 24) & 0xFF))
            msg.append(UInt8((block >> 16) & 0xFF))
            msg.append(UInt8((block >> 8) & 0xFF))
            msg.append(UInt8(block & 0xFF))
            var u = [UInt8](HMAC<SHA256>.authenticationCode(for: msg, using: key))
            var t = u
            for _ in 1..<iterations {
                u = [UInt8](HMAC<SHA256>.authenticationCode(for: u, using: key))
                for i in t.indices { t[i] ^= u[i] }
            }
            out.append(contentsOf: t)
            block &+= 1
        }
        return Data(out.prefix(keyLength))
    }
}

/// The system CSPRNG (getrandom on Linux via Swift's
/// SystemRandomNumberGenerator), standing in for SecRandomCopyBytes.
/// Returns false only if the system source fails.
public enum Random {
    public static func fill(_ bytes: inout [UInt8]) -> Bool {
        var rng = SystemRandomNumberGenerator()
        var i = 0
        while i < bytes.count {
            var chunk = rng.next()
            for _ in 0..<8 where i < bytes.count {
                bytes[i] = UInt8(chunk & 0xFF)
                chunk >>= 8
                i += 1
            }
        }
        return true
    }
}
