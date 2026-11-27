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
        let r = InputRecord.pointer(kind: InputRecord.pointerMove, x: 0.5, y: 1.0)!
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

    /// The wire's .scroll means "scroll AT (x, y)" — the translator
    /// emits a pointer move to those coordinates ahead of the clicks
    ///
    func testScrollTranslation() {
        var t = InputTranslator()
        let out = t.translate(.scroll(x: 0.25, y: 0.75, dx: 0.1, dy: -0.05))!
        XCTAssertEqual(out.count, 2)
        let (op0, move) = parse(out[0])!
        XCTAssertEqual(op0, InputRecord.opPointer)
        XCTAssertEqual(move[0], InputRecord.pointerMove)
        XCTAssertEqual(move.readBE(Int32.self, at: 1), 250_000)
        XCTAssertEqual(move.readBE(Int32.self, at: 5), 750_000)
        let (op1, body) = parse(out[1])!
        XCTAssertEqual(op1, InputRecord.opScroll)
        XCTAssertEqual(body.readBE(Int32.self, at: 0), 100_000)
        XCTAssertEqual(body.readBE(Int32.self, at: 4), -50_000)
        // Non-finite coordinates still scroll (no move emitted);
        // non-finite deltas still move (no clicks emitted); both bad
        // drops the event entirely.
        XCTAssertEqual(t.translate(.scroll(x: .nan, y: .nan, dx: 0.1, dy: 0))?.count, 1)
        XCTAssertEqual(t.translate(.scroll(x: 0.3, y: 0.4, dx: .infinity, dy: 0))?.count, 1)
        XCTAssertNil(t.translate(.scroll(x: .nan, y: .nan, dx: .infinity, dy: .nan)))
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

    // MARK: - clipboard (op 7, both directions)

    func testSetClipboardRecord() {
        let (op, body) = parse(InputRecord.clipboard("synthetic-text"))!
        XCTAssertEqual(op, InputRecord.opClipboard)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "synthetic-text")
    }

    func testOutputRecordRoundTrip() {
        // helper -> daemon framing: [len][op][utf8], split with
        // outputRecordLength exactly as InputOutputHandler does.
        var rec = Data([0, 0, 0, 0, InputRecord.recordClipboardText])
        rec.append(Data("clip-text-42".utf8))
        let n = rec.count - 4
        rec[0] = UInt8(n >> 24); rec[1] = UInt8(n >> 16)
        rec[2] = UInt8(n >> 8);  rec[3] = UInt8(n)
        XCTAssertEqual(InputRecord.outputRecordLength(rec), rec.count)
        XCTAssertEqual(InputRecord.outputRecordLength(rec.dropLast(3)), rec.count)
        // a second record appended: first parses alone, rest remain
        var two = rec
        two.append(contentsOf: InputRecord.releaseAll)
        XCTAssertEqual(InputRecord.outputRecordLength(two), rec.count)
        let (kind, bodyOut) = InputRecord.parseOutput(rec)!
        XCTAssertEqual(kind, InputRecord.recordClipboardText)
        XCTAssertEqual(String(decoding: bodyOut, as: UTF8.self), "clip-text-42")
    }

    // MARK: - hostile input doubles

    /// A paired client controls every Double in an InputEvent. The
    /// translator must never trap and must clamp before any Int32
    /// conversion — one move with x=2148.5 or 1e308 used to SIGILL the
    /// daemon via `Int32(Double)`.
    func testHostilePointerDoubles() {
        var t = InputTranslator()
        // Non-finite values are dropped, never clamped to a weird spot.
        XCTAssertNil(t.translate(.pointer(.move, x: .infinity, y: 0.5)))
        XCTAssertNil(t.translate(.pointer(.move, x: 0.5, y: -.infinity)))
        XCTAssertNil(t.translate(.pointer(.move, x: .nan, y: 0.5)))
        // Finite but huge: clamped inside the record bounds, not trapped.
        for x in [2148.5, 1e308, -1e308, 1e6, -1e6] {
            let out = t.translate(.pointer(.move, x: x, y: x))
            XCTAssertEqual(out?.count, 1, "x=\(x) should clamp, not drop or trap")
            let (op, body) = parse(out![0])!
            XCTAssertEqual(op, InputRecord.opPointer)
            XCTAssertLessThanOrEqual(abs(body.readBE(Int32.self, at: 1)), 2_000_000)
            XCTAssertLessThanOrEqual(abs(body.readBE(Int32.self, at: 5)), 2_000_000)
        }
        // Record layer directly: same behaviour without the translator.
        XCTAssertNil(InputRecord.pointer(kind: InputRecord.pointerMove, x: .nan, y: 0))
        XCTAssertNotNil(InputRecord.pointer(kind: InputRecord.pointerMove, x: 1e308, y: -1e308))
    }

    /// Huge scroll deltas clamp to ±4 frame fractions (±4e6
    /// milli-fractions) — the daemon-side bound behind helper cap S2/F6.
    func testHostileScrollDeltas() {
        var t = InputTranslator()
        // Non-finite deltas: no clicks, but the coordinate move still
        // emits (S-E); a fully broken event returns nil.
        XCTAssertEqual(t.translate(.scroll(x: 0, y: 0, dx: .infinity, dy: 0))?.count, 1)
        XCTAssertEqual(t.translate(.scroll(x: 0, y: 0, dx: 0, dy: .nan))?.count, 1)
        XCTAssertNil(t.translate(.scroll(x: .nan, y: 0, dx: .infinity, dy: 0)))
        for dx in [3000.0, -1e308, 2148.5, 100.0] {
            let out = t.translate(.scroll(x: 0.5, y: 0.5, dx: dx, dy: dx))
            XCTAssertEqual(out?.count, 2)   // move + scroll (S-E)
            let (_, body) = parse(out![1])!
            XCTAssertLessThanOrEqual(abs(body.readBE(Int32.self, at: 0)), 4_000_000)
            XCTAssertLessThanOrEqual(abs(body.readBE(Int32.self, at: 4)), 4_000_000)
        }
        // And a sane delta still passes through exactly.
        let out = t.translate(.scroll(x: 0.5, y: 0.5, dx: 0.1, dy: -0.05))!
        let (_, body) = parse(out[1])!
        XCTAssertEqual(body.readBE(Int32.self, at: 0), 100_000)
        XCTAssertEqual(body.readBE(Int32.self, at: 4), -50_000)
    }

    /// A maximal clipboard op-7 record fits the agreed IPC bound
    ///: REC_MAX in the helper is CLIP_MAX+1 == 256KiB+1.
    func testClipboardRecordWithinIPCMax() {
        let text = String(repeating: "x", count: 256 * 1024)
        let rec = InputRecord.clipboard(text)
        XCTAssertEqual(rec.count, 4 + InputRecord.maxRecordBytes)
        XCTAssertEqual(InputRecord.maxRecordBytes, 256 * 1024 + 1)
    }

    func testOutputRecordValidation() {
        XCTAssertEqual(InputRecord.outputRecordLength(Data([0, 1])), nil)   // short header
        XCTAssertEqual(InputRecord.outputRecordLength(Data([0, 0, 0, 0])), -1) // len 0
        XCTAssertEqual(InputRecord.outputRecordLength(Data([0xff, 0, 0, 0])), -1) // oversize
        // daemon->helper ops and helper->daemon record kinds share
        // byte 4; the CHANNEL discriminates (a pointer op record read
        // on the output channel would parse as kind 1 — the daemon
        // only applies this parse to helper stdout)
        let (kind2, _) = InputRecord.parseOutput(InputRecord.pointer(kind: InputRecord.pointerMove, x: 0.5, y: 0.5)!)!
        XCTAssertEqual(kind2, InputRecord.opPointer)
        // invalid UTF-8 body still parses structurally; the daemon
        // re-validates UTF-8 before any broadcast
        let bad = Data([0, 0, 0, 3, InputRecord.recordClipboardText, 0xff, 0xfe])
        XCTAssertEqual(InputRecord.outputRecordLength(bad), 7)
        let (kind3, body3) = InputRecord.parseOutput(bad)!
        XCTAssertEqual(kind3, InputRecord.recordClipboardText)
        XCTAssertNil(String(data: body3, encoding: .utf8))
    }
}

private extension Data {
    func readBE<T: FixedWidthInteger>(_ type: T.Type, at off: Int) -> T {
        var v: T = 0
        for i in 0..<T.bitWidth / 8 { v = v << 8 | T(self[self.startIndex + off + i]) }
        return v
    }
}
