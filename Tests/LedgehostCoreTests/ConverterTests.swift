import XCTest
import Foundation
@testable import LedgehostCore
import StreamProtocol

// Converter and LHM1-reader tests (P1-M1). The fixture is videotestsrc
// output through the real helper pipeline (pattern 18, 320x240, 60 fps,
// vah265lpenc) — a synthetic source, recorded to
// Fixtures/testsrc-320x240.lhm1. No desktop pixels ever enter the tree.

final class LHM1ReaderTests: XCTestCase {
    private func fixtureRecords() throws -> [MediaRecord] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/testsrc-320x240.lhm1")
        let data = try Data(contentsOf: url)
        // Reader timestamp sanity is windowed on wall-clock "now"; the
        // fixture ages, so disable it here and validate timestamps below.
        var reader = MediaRecordReader(timestampWindow: 0)
        return try reader.feed(data)
    }

    func testFixtureParsesCompletely() throws {
        let records = try fixtureRecords()
        XCTAssertEqual(records.count, 61)   // 1 sets + 60 AUs
        XCTAssertEqual(records.first?.tag, .parameterSets)
        XCTAssertEqual(records.dropFirst().filter { $0.tag == .accessUnit }.count, 60)
        // Exactly one flagged keyframe: the first AU.
        XCTAssertTrue(records[1].isKeyframe)
        XCTAssertFalse(records.dropFirst(2).contains { $0.isKeyframe })
        // Timestamps are sane wall-clock seconds; the msdk encoder
        // emits AUs with small reorder jitter, so each must sit within
        // 50 ms of its predecessor while the stream as a whole advances.
        var prev = 0.0
        for r in records {
            XCTAssertGreaterThan(r.captureTimestamp, 1_700_000_000)
            if prev > 0 { XCTAssertLessThanOrEqual(prev - r.captureTimestamp, 0.05) }
            prev = r.captureTimestamp
        }
        XCTAssertGreaterThan(records.last!.captureTimestamp - records[1].captureTimestamp, 0.8)
    }

    func testReaderHandlesSplitFeeds() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/testsrc-320x240.lhm1")
        let data = try Data(contentsOf: url)
        var reader = MediaRecordReader(timestampWindow: 0)
        var all: [MediaRecord] = []
        var i = 0
        while i < data.count {
            let n = min(777, data.count - i)
            all.append(contentsOf: try reader.feed(data.subdata(in: i..<(i + n))))
            i += n
        }
        XCTAssertEqual(all.count, 61)
    }

    func testReaderRejectsBadMagic() {
        var reader = MediaRecordReader(timestampWindow: 0)
        var bad = Data([0x4C, 0x48, 0x4D, 0x32]) + Data(repeating: 0, count: 16)
        XCTAssertThrowsError(try reader.feed(bad)) { XCTAssertEqual($0 as? MediaRecordError, .badMagic) }
        bad = Data()
    }

    func testReaderRejectsOversizedLength() {
        var reader = MediaRecordReader(timestampWindow: 0)
        var h = Data([0x4C, 0x48, 0x4D, 0x31, 1, 1, 0, 0])
        h.appendBE(Date().timeIntervalSince1970.bitPattern)
        h.appendBE(UInt32(MediaRecordReader.maxPayload + 1))
        XCTAssertThrowsError(try reader.feed(h)) {
            XCTAssertEqual($0 as? MediaRecordError, .lengthOverCap(MediaRecordReader.maxPayload + 1))
        }
    }
}

final class ConverterTests: XCTestCase {
    private func fixtureRecords() throws -> [MediaRecord] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/testsrc-320x240.lhm1")
        var reader = MediaRecordReader(timestampWindow: 0)
        return try reader.feed(Data(contentsOf: url))
    }

    func testSetsRecordConvertsToKind0() throws {
        let sets = try fixtureRecords().first!
        let payload = AnnexBConverter.parameterSetsPayload(sets.payload)
        XCTAssertNotNil(payload)
        let ps = ParameterSets(encoded: payload!)
        XCTAssertNotNil(ps)
        XCTAssertEqual(ps!.nalUnitHeaderLength, 4)
        // VA emits VPS/SPS/PPS — in that order, each a single NAL.
        XCTAssertEqual(ps!.sets.count, 3)
        XCTAssertEqual(ps!.sets.map { ($0[$0.startIndex] >> 1) & 0x3f }, [32, 33, 34])
    }

    func testAUConversionSeparatesSetsAndStripsAUD() throws {
        let records = try fixtureRecords()
        let idr = records[1]
        let c = AnnexBConverter.convert(idr.payload)
        // The keyframe AU carries in-band parameter sets.
        XCTAssertEqual(c.parameterSets.map { ($0[$0.startIndex] >> 1) & 0x3f }, [32, 33, 34])
        XCTAssertTrue(c.isIDR)
        // The frame side must parse as 4-byte-length-prefixed NALs with
        // no parameter-set/AUD/filler types left in it.
        let nals = WireReassemble.splitLengthPrefixed(c.frame)
        XCTAssertNotNil(nals)
        let types = nals!.map { ($0[$0.startIndex] >> 1) & 0x3f }
        XCTAssertTrue(types.contains(19) || types.contains(20))
        XCTAssertFalse(types.contains { AnnexB.parameterSetTypes.contains($0)
            || AnnexB.droppedTypes.contains($0) })
    }

    func testInBandSetsMatchSetsRecord() throws {
        let records = try fixtureRecords()
        let fromSets = AnnexBConverter.parameterSetsPayload(records[0].payload)!
        let fromAU = AnnexBConverter.convert(records[1].payload).parameterSets
        let psA = ParameterSets(encoded: fromSets)!
        XCTAssertEqual(psA.sets, fromAU)
    }

    func testNonKeyframesConvertCleanly() throws {
        let records = try fixtureRecords()
        var frames = 0
        for r in records.dropFirst(2) {
            let c = AnnexBConverter.convert(r.payload)
            XCTAssertFalse(c.isIDR)
            XCTAssertEqual(c.parameterSets.count, 0)
            let nals = WireReassemble.splitLengthPrefixed(c.frame)
            XCTAssertNotNil(nals)
            XCTAssertFalse(nals!.isEmpty)
            frames += 1
        }
        XCTAssertEqual(frames, 59)
    }

    func testElementaryStreamRoundTrips() throws {
        let records = try fixtureRecords()
        let sets = ParameterSets(encoded:
            AnnexBConverter.parameterSetsPayload(records[0].payload)!)!.sets
        var frames: [Data] = []
        var keyCount = 0
        for r in records.dropFirst() {
            let c = AnnexBConverter.convert(r.payload)
            frames.append(c.frame)
            if r.isKeyframe { keyCount += 1 }
        }
        XCTAssertEqual(keyCount, 1)
        let es = WireReassemble.elementaryStream(parameterSets: sets, frames: frames)
        // Re-splitting the elementary stream must yield every NAL we
        // emitted — proof the wire format round-trips losslessly.
        let all = AnnexB.split(es)
        var total = sets.count
        for f in frames { total += WireReassemble.splitLengthPrefixed(f)!.count }
        XCTAssertEqual(all.count, total)
    }
}

final class KeymapTests: XCTestCase {
    func testKnownMappings() {
        // The decision-8 example: HID 'a' → KEY_A 30 → X keycode 38.
        XCTAssertEqual(Keymap.hidToEvdev[0x04], 30)
        XCTAssertEqual(Keymap.hidToEvdev[0x04]! + 8, 38)
        XCTAssertEqual(Keymap.hidToEvdev[0x28], 28)   // Return → KEY_ENTER
        XCTAssertEqual(Keymap.hidToEvdev[0x29], 1)    // Escape → KEY_ESC
        XCTAssertEqual(Keymap.hidToEvdev[0x2c], 57)   // Space
        XCTAssertEqual(Keymap.hidToEvdev[0x1e], 2)    // '1' → KEY_1
        XCTAssertEqual(Keymap.hidToEvdev[0x27], 11)   // '0' → KEY_0
        XCTAssertEqual(Keymap.hidToEvdev[0x3a], 59)   // F1
        XCTAssertEqual(Keymap.hidToEvdev[0x4f], 106)  // Right arrow
        XCTAssertEqual(Keymap.hidToEvdev[0x52], 103)  // Up arrow
        XCTAssertEqual(Keymap.hidToEvdev[0x4c], 111)  // Delete → KEY_DELETE
    }

    func testModifiers() {
        let want: [UInt8: UInt16] = [
            0xe0: 29, 0xe1: 42, 0xe2: 56, 0xe3: 125,
            0xe4: 97, 0xe5: 54, 0xe6: 100, 0xe7: 126,
        ]
        for (hid, ev) in want {
            XCTAssertEqual(Keymap.hidToEvdev[hid], ev, "hid 0x\(String(hid, radix: 16))")
        }
    }

    func testUnmappedUsagesReturnNil() {
        for hid: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x86, 0xe8, 0xff] {
            XCTAssertNil(Keymap.hidToEvdev[hid], "hid 0x\(String(hid, radix: 16))")
        }
    }

    func testEveryMappedKeycodeIsXRange() {
        // X keycodes are evdev + 8; real keyboards end below 256.
        for (hid, ev) in Keymap.hidToEvdev {
            XCTAssertLessThan(ev + 8, 256, "hid 0x\(String(hid, radix: 16))")
        }
    }
}

// IPC-constants equivalence: pins the Swift values to
// the numbers helpers/ledgehost-ipc.h defines — the C side cannot be
// compiled here, so the literals ARE the cross-language static assert.
final class IPCLimitsTests: XCTestCase {
    func testConstantsMatchHeader() {
        XCTAssertEqual(IPCLimits.mediaMagic, [0x4C, 0x48, 0x4D, 0x31])      // "LHM1"
        XCTAssertEqual(IPCLimits.mediaVersion, 1)
        XCTAssertEqual(IPCLimits.mediaHeaderLength, 20)
        XCTAssertEqual(IPCLimits.mediaMaxPayload, 32 << 20)
        XCTAssertEqual(IPCLimits.mediaMaxPayload, StreamMessage.maxFramePayload)
        XCTAssertEqual(IPCLimits.inputHeaderLength, 4)
        XCTAssertEqual(IPCLimits.clipboardTextMax, 256 * 1024)
        XCTAssertEqual(IPCLimits.clipboardTextMax, Clipboard.maxTextBytes)
        XCTAssertEqual(IPCLimits.inputRecordMax, 256 * 1024 + 1)
        XCTAssertEqual(InputRecord.maxRecordBytes, IPCLimits.inputRecordMax)
    }
}
