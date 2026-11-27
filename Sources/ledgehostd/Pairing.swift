import Foundation
import Crypto
import StreamProtocol
import LedgehostCore
import SillLinuxShims

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
    /// When the current credentials were issued. The expiry check
    /// (`rotateIfExpired`) measures code age from this — every rotation
    /// source (expiry, success, tries exhausted, `code --new`) resets
    /// the clock, so each code lives a full `codeTTL` no matter what
    /// issued it.
    private var credentialsIssuedAt = Date()
    static let codeTTL: TimeInterval = 600

    /// The 600k-round PBKDF2 derivation (~seconds) never runs on the
    /// session event loop: it happens on this serial queue and the new
    /// credentials swap in under `lock` when it lands. At most one
    /// derivation is in flight — a request arriving mid-derivation
    /// coalesces into exactly one follow-up run.
    private static let deriveQueue = DispatchQueue(label: "ledgehost.pairing.derive")
    private var deriveInFlight = false
    private var rotateAgain = false

    init(identity: HostIdentity, pins: PinStore, port: Int) {
        self.identity = identity
        self.pins = pins
        self.port = port
        rotate()
    }

    /// Rotate now (admin `code --new`, init): the old code dies
    /// immediately — `code --new` means the old one is burnt — and the
    /// door answers `closed` until the new secret lands.
    func rotate() {
        lock.lock(); defer { lock.unlock() }
        code = ""; codeKey = nil; qrSecret = Data(); triesLeft = 0
        requestRotationLocked()
    }

    /// Kill the live credentials while the lock is held (success,
    /// tries exhausted): the paired code is dead the moment the caller
    /// returns, per the door's fail-closed rule.
    private func expireCredentialsLocked() {
        code = ""; codeKey = nil; qrSecret = Data(); triesLeft = 0
        requestRotationLocked()
    }

    /// `lock` must be held. Schedules one background derivation, or
    /// folds the request into the one already running.
    private func requestRotationLocked() {
        if deriveInFlight { rotateAgain = true; return }
        deriveInFlight = true
        Self.deriveQueue.async { [weak self] in self?.deriveAndSwap() }
    }

    /// Generate the credentials OFF the lock — the PBKDF2 lives here —
    /// then swap them in atomically. A rotation requested
    /// mid-derivation runs once more after this one; bursts never
    /// queue a backlog of derivations.
    private func deriveAndSwap() {
        let newCode = PairingCode.generate()
        var secret = [UInt8](repeating: 0, count: 16)
        let ok = newCode != nil && Random.fill(&secret)
        let newKey = ok ? PairingProof.codeKey(code: newCode!, macFingerprint: identity.fingerprint) : nil
        lock.lock(); defer { lock.unlock() }
        if let newCode, let newKey, ok {
            code = newCode; codeKey = newKey; qrSecret = Data(secret)
            triesLeft = Self.maxTries
            credentialsIssuedAt = Date()
            // Code only, never the link: the QR secret is a
            // live credential and must not land in the persistent journal.
            print(Log.stamp(), "pairing: code \(PairingCode.grouped(code))")
        } else {
            // Fail closed: a failed RNG must never leave a
            // known code or a zero QR secret in force — with codeKey nil
            // every proof answer is `closed`.
            code = ""; codeKey = nil; qrSecret = Data(); triesLeft = 0
            print(Log.stamp(), "pairing: credential generation failed — pairing door closed until the next rotation")
        }
        deriveInFlight = false
        if rotateAgain {
            rotateAgain = false
            requestRotationLocked()
        }
    }

    /// The live pairing code and its remaining validity, for the admin
    /// socket's `code` command — the value returned is the very secret
    /// the pairing door accepts right now (nil while the door is
    /// closed: mid-rotation, or by a failed generation).
    func currentCode() -> (code: String, secondsLeft: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard codeKey != nil else { return nil }
        let left = Self.codeTTL - Date().timeIntervalSince(credentialsIssuedAt)
        return (code, max(0, Int(left.rounded(.up))))
    }

    /// Age-based expiry, called on a frequent timer from main. Unlike
    /// a security rotation, the OLD code stays live until its
    /// replacement is fully derived and swapped — expiry is
    /// maintenance, not a compromise, so it leaves no dead window.
    func rotateIfExpired() {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(credentialsIssuedAt) >= Self.codeTTL {
            requestRotationLocked()
        }
    }

    /// Per-source proof-failure throttle:
    /// the 5-try rotation budget is global — an address that keeps
    /// sending wrong proofs would otherwise keep spending it via fresh
    /// connections. After `failLimit` failed proofs inside `failWindow`
    /// the address's proofs are refused closed WITHOUT touching
    /// triesLeft: a legit device mistyping a code twice is unaffected,
    /// a flood cannot burn more than `failLimit` proofs per window.
    /// (12 ≈ two rotation budgets in ten minutes.)
    static let failLimit = 12
    static let failWindow: TimeInterval = 600
    private var failures: [String: (count: Int, first: Date)] = [:]

    private func throttled(_ source: String, now: Date) -> Bool {
        guard let f = failures[source], f.count >= Self.failLimit else { return false }
        if now.timeIntervalSince(f.first) >= Self.failWindow {
            failures.removeValue(forKey: source)
            return false
        }
        return true
    }

    private func noteFailure(_ source: String, now: Date) {
        var f = failures[source] ?? (0, now)
        if now.timeIntervalSince(f.first) >= Self.failWindow { f = (0, now) }
        f.count += 1
        failures[source] = f
    }

    /// Answers one kind 19. `deviceFingerprint` comes from the TLS session;
    /// `source` is the remote address for the failure throttle.
    func answer(_ request: PairRequest, deviceFingerprint: Data,
                source: String = "?") -> PairResult {
        // A generation other than 1 is refused without counting a try.
        guard request.v == PairRequest.version else {
            return PairResult(ok: false, reason: PairResult.closed)
        }
        switch request.method {
        case PairRequest.code, PairRequest.qr:
            return answerProof(request, deviceFingerprint: deviceFingerprint,
                               source: source)
        case PairRequest.ask, PairRequest.cancel:
            // Home-door conveniences of a later design step; for now the
            // door is pairing-only and the code is already on display.
            return PairResult(ok: false, reason: PairResult.closed)
        default:
            return PairResult(ok: false, reason: PairResult.closed)
        }
    }

    private func answerProof(_ request: PairRequest, deviceFingerprint: Data,
                             source: String) -> PairResult {
        lock.lock(); defer { lock.unlock() }
        // A throttled address is refused before the rotation budget or
        // proof verification is touched.
        if throttled(source, now: Date()) {
            return PairResult(ok: false, reason: PairResult.closed)
        }
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
            failures.removeValue(forKey: source)
            print(Log.stamp(), "pairing: paired \(RemoteIdentityShortName(deviceFingerprint)) (\(SafeText.label(request.name, limit: 64)))")
            expireCredentialsLocked()
            return PairResult(ok: true, proof: Base64URL.encode(proofM), macID: identity.macID,
                              name: identity.name, recognitionKey: Base64URL.encode(identity.recognitionKey))
        }

        noteFailure(source, now: Date())
        triesLeft -= 1
        let left = triesLeft
        if triesLeft <= 0 { expireCredentialsLocked() }
        return PairResult(ok: false, reason: PairResult.code, triesLeft: left)
    }
}

func RemoteIdentityShortName(_ fingerprint: Data) -> String {
    String(MacID.make(fingerprint: fingerprint).prefix(6))
}
