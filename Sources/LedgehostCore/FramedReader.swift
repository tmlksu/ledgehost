import Foundation
import StreamProtocol

/// A framing violation reported by `FramedReader`.
public enum FrameViolation: Error, Equatable {
    /// The header bytes were malformed (never thrown for a partial
    /// header — the reader simply waits for more bytes).
    case invalidHeader
    /// The declared payload exceeds the configured cap.
    case oversized(payloadBytes: Int, cap: Int)
}

/// Incremental framed-record reader (audit Fable R-2): one byte buffer
/// and loop, parameterized by
///  - the header layout (fixed `headerLength` + a `parseHeader` that
///    maps the buffered prefix to a declared payload length, throwing
///    on malformed framing),
///  - the payload cap (`maxPayload`, re-read per record so a
///    state-dependent cap stays live),
///  - the error policy (`Policy`).
///
/// Call sites: the daemon's StreamMessage client parser and the
/// probe's Collector (`streamMessages`), `MediaRecordReader`
/// (`mediaRecords`), and the input helper's stdout loop
/// (`inputRecords`).
public struct FramedReader<Header> {
    /// What a framing violation does to the buffered remainder.
    public enum Policy {
        /// Throw; the caller closes the channel or kills the helper.
        case fatal
        /// Drop the buffer and keep reading the next `feed`.
        case dropBuffer
    }

    public private(set) var buffer = Data()
    private let headerLength: Int
    private let maxPayload: () -> Int
    private let policy: Policy
    /// Maps a `>= headerLength`-byte prefix to the parsed header and
    /// the payload byte count the record needs after the header.
    /// Throws `FrameViolation.invalidHeader` (or a layout-specific
    /// error) on malformed framing.
    private let parseHeader: (Data) throws -> (header: Header, payloadLength: Int)

    public init(headerLength: Int, maxPayload: @escaping () -> Int,
                policy: Policy,
                parseHeader: @escaping (Data) throws -> (Header, Int)) {
        self.headerLength = headerLength
        self.maxPayload = maxPayload
        self.policy = policy
        self.parseHeader = parseHeader
    }

    public init(headerLength: Int, maxPayload: Int,
                policy: Policy,
                parseHeader: @escaping (Data) throws -> (Header, Int)) {
        self.init(headerLength: headerLength, maxPayload: { maxPayload },
                  policy: policy, parseHeader: parseHeader)
    }

    /// Buffer more bytes without draining (use with `next()` when the
    /// caller interleaves per-record work that can change the cap).
    public mutating func append(_ bytes: Data) { buffer.append(bytes) }

    /// Forget buffered bytes (e.g. after a violation the caller logged).
    public mutating func clearBuffer() { buffer.removeAll() }

    /// The next complete record, or nil when the buffer holds less
    /// than one full record. Throws per `policy` on framing violations.
    public mutating func next() throws -> (header: Header, payload: Data)? {
        guard buffer.count >= headerLength else { return nil }
        let parsed: (header: Header, payloadLength: Int)
        do {
            parsed = try parseHeader(buffer)
        } catch {
            if policy == .dropBuffer { buffer.removeAll(); return nil }
            throw error
        }
        let cap = maxPayload()
        guard parsed.payloadLength <= cap else {
            if policy == .dropBuffer { buffer.removeAll(); return nil }
            throw FrameViolation.oversized(payloadBytes: parsed.payloadLength, cap: cap)
        }
        guard buffer.count >= headerLength + parsed.payloadLength else { return nil }
        let payload = buffer.subdata(in: buffer.startIndex + headerLength
                                     ..< buffer.startIndex + headerLength + parsed.payloadLength)
        buffer.removeSubrange(buffer.startIndex
                              ..< buffer.startIndex + headerLength + parsed.payloadLength)
        return (parsed.header, payload)
    }

    /// Append bytes and take every complete record now available.
    public mutating func feed(_ bytes: Data) throws -> [(header: Header, payload: Data)] {
        buffer.append(bytes)
        var out: [(Header, Data)] = []
        while let rec = try next() { out.append(rec) }
        return out
    }
}

extension FramedReader where Header == StreamHeader {
    /// The wire framing both sides speak (StreamMessage):
    /// kind(1) timestamp(8) isKeyframe(1) payloadLength(4), big endian.
    /// `maxPayload` is re-read per record — pass a closure over the
    /// connection state when the cap differs for pairing vs clients.
    public static func streamMessages(maxPayload: @escaping () -> Int,
                                      policy: Policy = .fatal) -> FramedReader {
        FramedReader(headerLength: StreamMessage.headerLength,
                     maxPayload: maxPayload, policy: policy) { d in
            // parseHeader only fails on a partial header, which next()
            // has already ruled out; unknown kinds parse as .unknown.
            guard let h = StreamMessage.parseHeader(d) else {
                throw FrameViolation.invalidHeader
            }
            return (h, h.payloadLength)
        }
    }

    public static func streamMessages(maxPayload: Int,
                                      policy: Policy = .fatal) -> FramedReader {
        streamMessages(maxPayload: { maxPayload }, policy: policy)
    }
}
