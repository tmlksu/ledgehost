import Foundation
import Crypto
import StreamProtocol

// The pairing window (M3): one current code and one current QR secret,
// five tries per code, the key derived once per rotation (a 600k-round
// PBKDF2 per attempt would be a denial-of-service gift). Proofs are
// verified with the vendored constant-time checks, against fingerprints
// taken from the TLS session — never from a message.

final class PairingManager {
    static let maxTries = 5

    private let identity: HostIdentity
    private let pins: PinStore
    private let port: Int
    private let lock = NSLock()

    private var code: String = ""
    private var codeKey: SymmetricKey?
    private var qrSecret: Data = Data()
    private var triesLeft: Int = 0

    init(identity: HostIdentity, pins: PinStore, port: Int) {
        self.identity = identity
        self.pins = pins
        self.port = port
        rotate()
    }

    func rotate() {
        lock.lock(); defer { lock.unlock() }
        rotateLocked()
    }

    private func rotateLocked() {
        code = PairingCode.generate() ?? "000000000000"
        codeKey = PairingProof.codeKey(code: code, macFingerprint: identity.fingerprint)
        var secret = [UInt8](repeating: 0, count: 16)
        _ = SillRandom.fill(&secret)
        qrSecret = Data(secret)
        triesLeft = Self.maxTries
        print(Log.stamp(), "pairing: code \(PairingCode.grouped(code))")
        let link = PairLink(fingerprint: identity.fingerprint, secret: qrSecret,
                            name: identity.name, port: port, addresses: [])
        print(Log.stamp(), "pairing: link \(link.url)")
    }

    /// Answers one kind 19. `deviceFingerprint` comes from the TLS session.
    func answer(_ request: PairRequest, deviceFingerprint: Data) -> PairResult {
        // A generation other than 1 is refused without counting a try.
        guard request.v == PairRequest.version else {
            return PairResult(ok: false, reason: PairResult.closed)
        }
        switch request.method {
        case PairRequest.code, PairRequest.qr:
            return answerProof(request, deviceFingerprint: deviceFingerprint)
        case PairRequest.ask, PairRequest.cancel:
            // Home-door conveniences of a later design step; for now the
            // door is pairing-only and the code is already on display.
            return PairResult(ok: false, reason: PairResult.closed)
        default:
            return PairResult(ok: false, reason: PairResult.closed)
        }
    }

    private func answerProof(_ request: PairRequest, deviceFingerprint: Data) -> PairResult {
        lock.lock(); defer { lock.unlock() }
        guard let proof = Base64URL.decode(request.proof) else {
            return PairResult(ok: false, reason: PairResult.code, triesLeft: triesLeft)
        }
        let key: SymmetricKey?
        if request.method == PairRequest.qr {
            key = PairingProof.qrKey(secret: qrSecret)
        } else {
            key = codeKey
        }
        guard let key else { return PairResult(ok: false, reason: PairResult.closed) }

        if PairingProof.isValidDeviceProof(proof, key: key, deviceFingerprint: deviceFingerprint,
                                           macFingerprint: identity.fingerprint) {
            let proofM = PairingProof.macProof(key: key, macFingerprint: identity.fingerprint,
                                               deviceFingerprint: deviceFingerprint)
            do {
                try pins.add(fingerprint: deviceFingerprint, name: request.name, model: request.model)
            } catch {
                print(Log.stamp(), "pairing: could not save the pin: \(error)")
                return PairResult(ok: false, reason: PairResult.closed)
            }
            print(Log.stamp(), "pairing: paired \(RemoteIdentityShortName(deviceFingerprint)) (\(SafeText.label(request.name, limit: 64)))")
            rotateLocked()
            return PairResult(ok: true, proof: Base64URL.encode(proofM), macID: identity.macID,
                              name: identity.name, recognitionKey: Base64URL.encode(identity.recognitionKey))
        }

        triesLeft -= 1
        let left = triesLeft
        if triesLeft <= 0 { rotateLocked() }
        return PairResult(ok: false, reason: PairResult.code, triesLeft: left)
    }
}

func RemoteIdentityShortName(_ fingerprint: Data) -> String {
    String(MacID.make(fingerprint: fingerprint).prefix(6))
}
