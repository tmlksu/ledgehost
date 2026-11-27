import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Store plumbing shared by the daemon and the probe (audit R4/R-3):
// the config-directory rule and the atomic write must be identical in
// both processes. The higher-level stores (HostIdentity, PinStore)
// live with the daemon until the test seam needs them (R-8).

public enum StoreError: Error {
    case corrupt(String)
    case io(String)
}

public func configDirectory(_ app: String) -> URL {
    let base: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
        base = URL(fileURLWithPath: xdg)
    } else {
        base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }
    return base.appendingPathComponent(app)
}

public func ensureDirectory(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
}

public func atomicWrite(_ data: Data, to url: URL) throws {
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
    // The file is durable; make the directory entry durable too
    // (audit S13) — without this a crash can still lose the rename.
    #if canImport(Glibc)
    if let dfd = FileHandle(forReadingAtPath: url.deletingLastPathComponent().path) {
        _ = try? dfd.synchronize()
        try? dfd.close()
    }
    #endif
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

public func readIfExists(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
}
