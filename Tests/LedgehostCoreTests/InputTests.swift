import XCTest
@testable import LedgehostCore
@testable import StreamProtocol

final class InputTests: XCTestCase {
    /// Parse one op record back out (length + op + fields).
    private func parse(_ d: Data) -> (op: UInt8, body: Data)? {
        guard d.count >= 5 else { return nil }
        let len = Int(d.readBE(UInt32.self, at: 0))
        guard len == d.count - 4, len >= 1 else { return nil }
        return (d[4], d.subdata(in: 5..<d.count))
    }

    func testRecordFraming() {
        let r = InputRecord.pointer(kind: InputRecord.pointerMove, x: 0.5, y: 1.0)
        let (op, body) = parse(r)!
        XCTAssertEqual(op, InputRecord.opPointer)
        XCTAssertEqual(body.count, 9)
        XCTAssertEqual(body[0], InputRecord.pointerMove)
        XCTAssertEqual(body.readBE(Int32.self, at: 1), 500_000)
        XCTAssertEqual(body.readBE(Int32.self, at: 5), 1_000_000)
    }

    func testPointerTranslation() {
        var t = InputTranslator()
        let out = t.translate(.pointer(.leftDown, x: 0.25, y: 0.75))!
        XCTAssertEqual(out.count, 1)
        let (op, body) = parse(out[0])!
        XCTAssertEqual(op, InputRecord.opPointer)
        XCTAssertEqual(body[0], InputRecord.pointerLeftDown)
        XCTAssertEqual(body.readBE(Int32.self, at: 1), 250_000)
        XCTAssertEqual(body.readBE(Int32.self, at: 5), 750_000)
    }

    func testScrollTranslation() {
        var t = InputTranslator()
        let out = t.translate(.scroll(x: 0.5, y: 0.5, dx: 0.1, dy: -0.05))!
        let (op, body) = parse(out[0])!
        XCTAssertEqual(op, InputRecord.opScroll)
        XCTAssertEqual(body.readBE(Int32.self, at: 0), 100_000)
        XCTAssertEqual(body.readBE(Int32.self, at: 4), -50_000)
    }

    /// Modifier bitmask diffing (decision 8): a key with the shift bit
    /// emits a LEFTSHIFT op-3 before the key op; with the bit gone the
    /// next event emits the release.
    func testModifierDiffing() {
        var t = InputTranslator()
        var out = t.translate(.key(hidUsage: 0x04, down: true, modifiers: 1 << 17))!
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(parse(out[0])!.body.readBE(UInt16.self, at: 0), 0xE1)
        XCTAssertEqual(parse(out[0])!.body[2], 1)
        XCTAssertEqual(parse(out[1])!.body.readBE(UInt16.self, at: 0), 0x04)
        // Same modifiers on the next event: no resend.
        out = t.translate(.key(hidUsage: 0x04, down: false, modifiers: 1 << 17))!
        XCTAssertEqual(out.count, 1)
        // Modifiers cleared: LEFTSHIFT up emitted before the key op.
        out = t.translate(.key(hidUsage: 0x05, down: true, modifiers: 0))!
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(parse(out[0])!.body.readBE(UInt16.self, at: 0), 0xE1)
        XCTAssertEqual(parse(out[0])!.body[2], 0)
    }

    /// A modifier usage as the event's own key is exempt from the sync
    /// (it is the event), and its release clears held state.
    func testModifierAsKey() {
        var t = InputTranslator()
        var out = t.translate(.key(hidUsage: 0xE1, down: true, modifiers: 1 << 17))!
        XCTAssertEqual(out.count, 1)   // just the shift-down itself
        out = t.translate(.key(hidUsage: 0xE1, down: false, modifiers: 0))!
        XCTAssertEqual(out.count, 1)
    }

    /// Unknown HID usages and out-of-range modifier bits are dropped.
    func testUnknownUsageDropped() {
        var t = InputTranslator()
        XCTAssertNil(t.translate(.key(hidUsage: 0xFFFF, down: true, modifiers: 0)))
        XCTAssertNil(t.translate(.key(hidUsage: 0x0100, down: true, modifiers: 0)))
        let out = t.translate(.key(hidUsage: 0x04, down: true, modifiers: 1 << 40))!
        XCTAssertEqual(out.count, 1)   // stray bit ignored, key still sent
    }

    /// Control characters in text become key ops; the rest is text.
    func testTextControlCharacters() {
        var t = InputTranslator()
        let out = t.translate(.text("a\nb\t"))!
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(parse(out[0])!.op, InputRecord.opText)
        XCTAssertEqual(parse(out[0])!.body, Data("a".utf8))
        XCTAssertEqual(parse(out[1])!.op, InputRecord.opKey)   // Return down
        XCTAssertEqual(parse(out[1])!.body.readBE(UInt16.self, at: 0), 0x28)
        XCTAssertEqual(parse(out[2])!.op, InputRecord.opKey)   // Return up
        XCTAssertEqual(parse(out[3])!.op, InputRecord.opText)  // "b"
        XCTAssertEqual(parse(out[4])!.op, InputRecord.opKey)   // Tab down
        XCTAssertEqual(parse(out[5])!.op, InputRecord.opKey)   // Tab up
    }

    func testScrollGestureDropped() {
        var t = InputTranslator()
        XCTAssertNil(t.translate(.scrollGesture(.began, x: 0, y: 0)))
    }

    func testRateLimiter() {
        var l = InputRateLimiter()
        var now = 0.0
        for _ in 0..<240 { XCTAssertTrue(l.allow(now: now)) }
        XCTAssertFalse(l.allow(now: now))          // burst exhausted
        now += 1.0                                  // one second refills 240
        for _ in 0..<240 { XCTAssertTrue(l.allow(now: now)) }
        XCTAssertFalse(l.allow(now: now))
    }

    func testReleaseAllRecord() {
        let (op, body) = parse(InputRecord.releaseAll)!
        XCTAssertEqual(op, InputRecord.opReleaseAll)
        XCTAssertTrue(body.isEmpty)
    }
}

private extension Data {
    func readBE<T: FixedWidthInteger>(_ type: T.Type, at off: Int) -> T {
        var v: T = 0
        for i in 0..<T.bitWidth / 8 { v = v << 8 | T(self[self.startIndex + off + i]) }
        return v
    }
}
