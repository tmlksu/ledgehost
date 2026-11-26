import Foundation
import Crypto
import StreamProtocol
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

enum StoreError: Error {
    case corrupt(String)
    case io(String)
}

func configDirectory(_ app: String) -> URL {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        base = URL(fileURLWithPath: xdg)
    } else {
        base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }
    return base.appendingPathComponent(app)
}

func ensureDirectory(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
}

func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: tmp.path, contents: nil,
                                         attributes: [.posixPermissions: 0o600]) else {
        throw StoreError.io("cannot create \(tmp.path)")
    }
    let handle = try FileHandle(forWritingTo: tmp)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    if rename(tmp.path, url.path) != 0 {
        throw StoreError.io("rename to \(url.path) failed")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func readIfExists(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
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
        _ = SillRandom.fill(&rk)
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
    func reload() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? readIfExists(url),
              let decoded = try? JSONDecoder().decode(PinFile.self, from: data),
              decoded.version == 1 else { return }
        file = decoded
    }
}

/// Random bytes for our own stores (the vendored shims' fill is internal
/// to that module's use sites; this is the same system source).
enum SillRandom {
    static func fill(_ bytes: inout [UInt8]) -> Bool {
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
