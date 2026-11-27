import Foundation
import Crypto
import StreamProtocol
import LedgehostCore
import SillLinuxShims
#if canImport(Glibc)
import Glibc
#endif

// Identity and pin storage (M2). One directory, two JSON files, both
// written atomically (temp file + fsync + rename) with tight
// permissions: a silently regenerated identity would break every pin
// a device holds, so a corrupt file is a loud failure, never a reset.

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static func stamp() -> String { formatter.string(from: Date()) }
}

/// Bounded per-message logging (audit S6/F5): at most `budget` lines
/// per `seconds` window; held lines are counted so the next emitted
/// line can report "(+N held)" — floods stay visible in aggregate
/// without filling the journal.
struct LogSampler {
    private var windowStart = 0.0
    private var used = 0
    private var held = 0

    /// Returns the number of lines held since the last emission when
    /// this line may print, or nil when it should be held.
    mutating func emit(every seconds: Double = 1, budget: Int = 8) -> Int? {
        let now = Date().timeIntervalSince1970
        if now - windowStart >= seconds { windowStart = now; used = 0 }
        if used >= budget { held += 1; return nil }
        used += 1
        defer { held = 0 }
        return held
    }
}

// MARK: - Host identity

struct IdentityFile: Codable {
    var version: Int
    /// X9.63 private key (97 bytes), standard base64.
    var keyX963: String
    /// 32 bytes, standard base64.
    var recognitionKey: String
    var name: String
}

final class HostIdentity {
    let privateKey: P256.Signing.PrivateKey
    let certificateDER: Data
    let fingerprint: Data
    let macID: String
    let recognitionKey: Data
    let name: String
    let launchID: String

    private init(file: IdentityFile) throws {
        guard let keyData = Data(base64Encoded: file.keyX963),
              let key = RemoteKey.importPrivate(keyData),
              let rk = Data(base64Encoded: file.recognitionKey), rk.count == 32,
              let der = SelfSignedCertificate.make(key: key) else {
            throw StoreError.corrupt("identity file does not decode to a usable P-256 identity")
        }
        privateKey = key
        certificateDER = der
        fingerprint = SPKI.fingerprint(of: key)
        macID = MacID.make(fingerprint: fingerprint)
        recognitionKey = rk
        name = file.name
        launchID = UUID().uuidString
    }

    static func loadOrCreate(in dir: URL) throws -> HostIdentity {
        try ensureDirectory(dir)
        let url = dir.appendingPathComponent("identity.json")
        if let data = try readIfExists(url) {
            guard let file = try? JSONDecoder().decode(IdentityFile.self, from: data), file.version == 1 else {
                throw StoreError.corrupt("identity.json is unreadable; refusing to regenerate (every device pin would break)")
            }
            return try HostIdentity(file: file)
        }
        let key = RemoteKey.generate()
        var rk = [UInt8](repeating: 0, count: 32)
        _ = Random.fill(&rk)
        let name = ProcessInfo.processInfo.hostName
        let file = IdentityFile(version: 1,
                                keyX963: RemoteKey.export(key).base64EncodedString(),
                                recognitionKey: Data(rk).base64EncodedString(),
                                name: name)
        try atomicWrite(JSONEncoder().encode(file), to: url)
        return try HostIdentity(file: file)
    }
}

// MARK: - Pins (paired devices)

struct PinFile: Codable {
    struct Device: Codable {
        /// base64url fingerprint of the device's key.
        var fingerprint: String
        var name: String
        var model: String?
        var pairedAt: Double
    }
    var version: Int
    var devices: [Device]
}

final class PinStore {
    private let url: URL
    private let lock = NSLock()
    private var file: PinFile

    init(in dir: URL) throws {
        url = dir.appendingPathComponent("paired.json")
        if let data = try readIfExists(url) {
            guard let decoded = try? JSONDecoder().decode(PinFile.self, from: data), decoded.version == 1 else {
                throw StoreError.corrupt("paired.json is unreadable")
            }
            file = decoded
        } else {
            file = PinFile(version: 1, devices: [])
        }
    }

    func isPinned(_ fingerprint: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return file.devices.contains { $0.fingerprint == Base64URL.encode(fingerprint) }
    }

    func add(fingerprint: Data, name: String, model: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let entry = PinFile.Device(fingerprint: Base64URL.encode(fingerprint),
                                   name: SafeText.label(name, limit: 64),
                                   model: model,
                                   pairedAt: Date().timeIntervalSince1970)
        file.devices.removeAll { $0.fingerprint == entry.fingerprint }
        file.devices.append(entry)
        try atomicWrite(JSONEncoder().encode(file), to: url)
    }

    func remove(fingerprint: Data) throws {
        lock.lock(); defer { lock.unlock() }
        file.devices.removeAll { $0.fingerprint == Base64URL.encode(fingerprint) }
        try atomicWrite(JSONEncoder().encode(file), to: url)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return file.devices.count }

    /// Re-read paired.json if it changed on disk (the unpair path writes
    /// it from another process) — the live-revocation watch in main.
    /// A read/parse failure keeps the last pin set (the fail-open-for-
    /// availability tradeoff) but is logged once per episode (audit S12)
    /// so a missed revocation window is diagnosable.
    func reload() {
        lock.lock(); defer { lock.unlock() }
        var data: Data?
        do { data = try readIfExists(url) } catch { noteReloadFailure("unreadable"); return }
        guard let data else { clearReloadFailure(); return }
        guard let decoded = try? JSONDecoder().decode(PinFile.self, from: data),
              decoded.version == 1 else { noteReloadFailure("unparseable"); return }
        file = decoded
        clearReloadFailure()
    }

    private var reloadFailing = false
    private func noteReloadFailure(_ what: String) {
        if !reloadFailing {
            reloadFailing = true
            print(Log.stamp(), "ledgehostd: paired.json reload failed (\(what)) — keeping the last pin set")
        }
    }
    private func clearReloadFailure() {
        if reloadFailing {
            reloadFailing = false
            print(Log.stamp(), "ledgehostd: paired.json reads cleanly again")
        }
    }
}

