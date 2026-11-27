import XCTest
import Foundation
@testable import LedgehostCore
import StreamProtocol

// FramedReader edge cases (audit Fable R-2): oversized lengths, split
// headers and garbage, exercised per call-site layout and policy.
final class FramedReaderTests: XCTestCase {

    private func frame(_ payload: Data) -> Data {
        StreamMessage(kind: .hello, timestamp: 1.5, isKeyframe: false,
                      payload: payload).serialized()
    }

    // --- StreamMessage layout (daemon client parser, probe Collector) ---

    func testStreamSplitHeader() throws {
        var r = FramedReader<StreamHeader>.streamMessages(maxPayload: 64)
        let f = frame(Data("hi".utf8))
        XCTAssertTrue(try r.feed(f.prefix(5)).isEmpty)          // partial header
        XCTAssertTrue(try r.feed(f[5..<StreamMessage.headerLength]).isEmpty)
        let recs = try r.feed(f.suffix(2))                       // header done, payload
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].payload, Data("hi".utf8))
    }

    func testStreamOversizedThrows() {
        var r = FramedReader<StreamHeader>.streamMessages(maxPayload: 3)
        XCTAssertThrowsError(try r.feed(frame(Data(repeating: 0, count: 10)))) {
            XCTAssertEqual($0 as? FrameViolation,
                           .oversized(payloadBytes: 10, cap: 3))
        }
    }

    func testStreamDynamicCap() throws {
        // Cap flips between records — the daemon's pairing/client
        // transition relies on the cap being re-read per record.
        var cap = 4
        var r = FramedReader<StreamHeader>.streamMessages(maxPayload: { cap })
        XCTAssertEqual(try r.feed(frame(Data(repeating: 1, count: 4))).count, 1)
        // A record over the old cap parses once the cap is re-read.
        cap = 16
        XCTAssertEqual(try r.feed(frame(Data(repeating: 1, count: 8))).count, 1)
    }

    func testStreamGarbageKindParses() throws {
        // An unknown kind byte is .unknown, not a framing violation —
        // older/newer peers must keep working.
        var f = frame(Data("x".utf8)); f[0] = 0xEE
        var r = FramedReader<StreamHeader>.streamMessages(maxPayload: 64)
        let recs = try r.feed(f)
        XCTAssertEqual(recs.first?.header.kind, .unknown)
    }

    // --- LHM1 layout (MediaRecordReader) ---

    func testMediaBadMagicThrows() {
        var r = MediaRecordReader(timestampWindow: 0)
        XCTAssertThrowsError(try r.feed(Data(repeating: 0xFF, count: 20))) {
            XCTAssertEqual($0 as? MediaRecordError, .badMagic)
        }
    }

    func testMediaOverCapThrows() {
        var h = Data(MediaRecordReader.magic)
        h.append(IPCLimits.mediaVersion)
        h.append(MediaTag.accessUnit.rawValue)
        h.append(contentsOf: [0, 0])
        var ts = Double(1.0).bitPattern.bigEndian
        h.append(Data(bytes: &ts, count: 8))
        var len = UInt32(MediaRecordReader.maxPayload + 1).bigEndian
        h.append(Data(bytes: &len, count: 4))
        var r = MediaRecordReader(timestampWindow: 0)
        XCTAssertThrowsError(try r.feed(h)) {
            guard case .lengthOverCap = $0 as? MediaRecordError else {
                return XCTFail("expected lengthOverCap, got \($0)")
            }
        }
    }

    // --- input-output layout (InputService) ---

    private func inputFrame(body: Data) -> Data {
        var d = Data()
        d.appendBE(UInt32(body.count))
        d.append(body)
        return d
    }

    func testInputZeroLenIsInvalid() {
        var r = InputRecord.outputReader()
        XCTAssertThrowsError(try r.feed(inputFrame(body: Data()))) {
            XCTAssertEqual($0 as? FrameViolation, .invalidHeader)
        }
    }

    func testInputOverCapIsOversized() {
        var r = InputRecord.outputReader()
        var d = Data()
        d.appendBE(UInt32(InputRecord.maxRecordBytes + 1))
        XCTAssertThrowsError(try r.feed(d)) {
            guard case .oversized = $0 as? FrameViolation else {
                return XCTFail("expected oversized, got \($0)")
            }
        }
    }

    func testInputSplitHeader() throws {
        var r = InputRecord.outputReader()
        let f = inputFrame(body: Data([InputRecord.recordClipboardText]) + Data("t".utf8))
        XCTAssertTrue(try r.feed(f.prefix(2)).isEmpty)
        let recs = try r.feed(f.suffix(from: 2))
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(recs[0].payload.first, InputRecord.recordClipboardText)
    }

    func testInputDropBufferPolicy() throws {
        // A bad record drops the buffered rest but keeps records
        // already parsed — InputService logs and continues.
        var r = InputRecord.outputReader(policy: .dropBuffer)
        var d = inputFrame(body: Data([InputRecord.recordClipboardText]) + Data("ok".utf8))
        d.append(Data([0, 0, 0, 0]))      // len 0 → invalid
        d.append(contentsOf: [0xAA, 0xBB])
        let recs = try r.feed(d)
        XCTAssertEqual(recs.count, 1)
        XCTAssertEqual(r.buffer.count, 0)
        // Reader still usable after the drop.
        let ok = try r.feed(inputFrame(body: Data([InputRecord.recordClipboardText])))
        XCTAssertEqual(ok.count, 1)
    }
}
