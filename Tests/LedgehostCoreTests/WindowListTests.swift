import XCTest
import StreamProtocol
@testable import LedgehostCore

// Phase 2 seams: xquery snapshot parsing and the xid->wire-id mapping
// (window selection echoes the id back), plus the input op-9 source
// rect record.

final class WindowListParserTests: XCTestCase {
    func testParsesSnapshot() {
        var p = XWindowListParser()
        // NB: a multiline literal's newline before """ is NOT part of
        // the string — the "." line needs an explicit "\n".
        let snaps = p.feed(bytes: Data(("""
            root 1600 1200
            win 1a00003 0 0 1600 27 Xfce4-panel xfce4-panel
            win 4000003 10 20 800 600 Google-chrome A Title With Spaces
            .
            """ + "\n").utf8))
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(p.rootSize?.w, 1600)
        let w = snaps[0]
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(w[0].xid, 0x1a00003)
        XCTAssertEqual(w[1].appClass, "Google-chrome")
        XCTAssertEqual(w[1].title, "A Title With Spaces")
        XCTAssertEqual(w[1].x, 10)
    }

    func testIdenticalSnapshotsCommitNothing() {
        var p = XWindowListParser()
        let bytes = Data("win 100 0 0 10 10 C t\n.\n".utf8)
        XCTAssertEqual(p.feed(bytes: bytes).count, 1)
        XCTAssertTrue(p.feed(bytes: bytes).isEmpty)      // same content: dropped
        let changed = Data("win 100 0 0 20 10 C t\n.\n".utf8)
        XCTAssertEqual(p.feed(bytes: changed).count, 1)  // resize: emitted
    }

    func testPartialLinesAcrossFeeds() {
        var p = XWindowListParser()
        XCTAssertTrue(p.feed(bytes: Data("win 100 0 0 10 ".utf8)).isEmpty)
        XCTAssertTrue(p.feed(bytes: Data("10 C t\n".utf8)).isEmpty)
        XCTAssertEqual(p.feed(bytes: Data(".\n".utf8)).count, 1)
    }

    func testMalformedLinesIgnored() {
        var p = XWindowListParser()
        let snaps = p.feed(bytes: Data(("""
            garbage line
            win nothex 0 0 10 10 C t
            win 100 0 0 0 10 C t
            win 200 0 0 10 10 - No Class
            .
            """ + "\n").utf8))
        XCTAssertEqual(snaps[0].count, 1)               // only the valid one
        XCTAssertEqual(snaps[0][0].xid, 0x200)
        XCTAssertEqual(snaps[0][0].appClass, "")        // "-" class -> empty
        XCTAssertEqual(snaps[0][0].title, "No Class")
    }

    func testWireMappingKeepsXidAsId() {
        let w = XWindow(xid: 0x4000003, x: 10, y: 20, width: 800, height: 600,
                        appClass: "Mousepad", title: "Untitled")
        let wire = w.wire
        XCTAssertEqual(wire.id, 0x4000003)              // id IS the xid
        XCTAssertEqual(wire.appName, "Mousepad")
        XCTAssertEqual(wire.width, 800)
        XCTAssertEqual(wire.bundleID, "mousepad.Mousepad")
        // Round-trip: the client echoes id into selectSource .window —
        // the daemon maps it straight back to the xid.
        XCTAssertEqual(wire.id, w.xid)
    }
}

final class SourceRectRecordTests: XCTestCase {
    func testSourceRectEncoding() {
        let r = InputRecord.sourceRect(x: 100, y: -50, width: 512, height: 384)
        // len(4 BE, body incl op) + op(1) + body: 4 int32 BE
        XCTAssertEqual(r.count, 4 + 1 + 16)
        XCTAssertEqual(r.readBE(UInt32.self, at: 0), 17)
        XCTAssertEqual(r[4], InputRecord.opSourceRect)
        XCTAssertEqual(r.readBE(Int32.self, at: 5), 100)
        XCTAssertEqual(r.readBE(Int32.self, at: 9), -50)
        XCTAssertEqual(r.readBE(Int32.self, at: 13), 512)
        XCTAssertEqual(r.readBE(Int32.self, at: 17), 384)
    }
}
