import XCTest
import Foundation
@testable import LedgehostCore
import StreamProtocol

// Store tests (audit R10 / Fable R-8): pin add/remove/reload, corrupt
// paired.json keeps the last-good set and logs once per episode, a
// corrupt identity is a loud failure that never regenerates, and
// atomicWrite's 0600 + rename shape.
final class StoreTests: XCTestCase {
    private var dirs: [URL] = []

    private func scratchDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgehost-storet-\(UUID().uuidString)")
        try ensureDirectory(d)
        dirs.append(d)
        return d
    }

    override func tearDownWithError() throws {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func fp(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    // --- PinStore ---

    func testPinAddRemoveReload() throws {
        let dir = try scratchDir()
        let store = try PinStore(in: dir)
        XCTAssertEqual(store.count, 0)
        try store.add(fingerprint: fp(1), name: "ipad", model: nil)
        try store.add(fingerprint: fp(2), name: "iphone", model: "15")
        XCTAssertTrue(store.isPinned(fp(1)))
        XCTAssertEqual(store.count, 2)
        // Re-add same fingerprint replaces, not duplicates.
        try store.add(fingerprint: fp(1), name: "ipad2", model: nil)
        XCTAssertEqual(store.count, 2)

        // A second store on the same dir sees the persisted set, and a
        // removal written behind the first store's back appears on
        // reload (the unpair-from-another-process watch).
        let other = try PinStore(in: dir)
        try other.remove(fingerprint: fp(2))
        store.reload()
        XCTAssertTrue(store.isPinned(fp(1)))
        XCTAssertFalse(store.isPinned(fp(2)))
        XCTAssertEqual(store.count, 1)
    }

    func testPinCorruptKeepsLastGoodAndLogsOnce() throws {
        let dir = try scratchDir()
        let store = try PinStore(in: dir)
        try store.add(fingerprint: fp(7), name: "ipad", model: nil)
        var logs: [String] = []
        store.log = { logs.append($0) }

        // Corrupt the file out from under the store.
        let url = dir.appendingPathComponent("paired.json")
        try Data("not json{".utf8).write(to: url)
        store.reload()
        store.reload()   // once per episode: no second line
        XCTAssertTrue(store.isPinned(fp(7)))
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("reload failed"))

        // The store's next write heals the file from last-good memory;
        // reload then logs recovery and the in-memory set persisted.
        try store.add(fingerprint: fp(9), name: "fixed", model: nil)
        store.reload()
        XCTAssertTrue(store.isPinned(fp(7)))
        XCTAssertTrue(store.isPinned(fp(9)))
        XCTAssertEqual(logs.count, 2)
        XCTAssertTrue(logs[1].contains("cleanly"))
    }

    func testPinCorruptAtOpenThrows() throws {
        let dir = try scratchDir()
        try Data("junk".utf8).write(to: dir.appendingPathComponent("paired.json"))
        XCTAssertThrowsError(try PinStore(in: dir)) {
            guard case .corrupt = $0 as? StoreError else {
                return XCTFail("expected .corrupt, got \($0)")
            }
        }
    }

    // --- HostIdentity ---

    func testIdentityRoundtripAndCorruptFailsLoud() throws {
        let dir = try scratchDir()
        let id1 = try HostIdentity.loadOrCreate(in: dir)
        let url = dir.appendingPathComponent("identity.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Reload returns the same identity (same fingerprint).
        let id2 = try HostIdentity.loadOrCreate(in: dir)
        XCTAssertEqual(id1.fingerprint, id2.fingerprint)
        XCTAssertEqual(id1.macID, id2.macID)

        // Corrupt it: loud failure, and the file is NOT overwritten.
        try Data("garbage".utf8).write(to: url)
        XCTAssertThrowsError(try HostIdentity.loadOrCreate(in: dir)) {
            guard case .corrupt = $0 as? StoreError else {
                return XCTFail("expected .corrupt, got \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url), "garbage")
    }

    // --- atomicWrite ---

    func testAtomicWritePermsAndShape() throws {
        let dir = try scratchDir()
        let url = dir.appendingPathComponent("thing.json")
        try atomicWrite(Data("one".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url), "one")
        let perms = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        // No temp-file litter: the rename consumed it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty)
        // A second write replaces whole (rename atomicity shape).
        try atomicWrite(Data("two-two".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url), "two-two")
    }
}
