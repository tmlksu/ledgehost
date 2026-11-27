import Foundation

// LHM1 — the framed record format ledgehost-media writes on stdout
// (phase-1-plan.md "IPC specifications"). Header, big endian:
//   magic "LHM1" (4) version (1) = 1 tag (1) flags (1) reserved (1)
//   capture timestamp (8, Double seconds) payload length (4)
// All helper logging is stderr; anything but this framing on stdout is
// a protocol violation and the daemon restarts the helper.

public enum MediaTag: UInt8 {
    case accessUnit = 1
    case parameterSets = 2
}

public struct MediaRecord {
    public let tag: MediaTag
    public let isKeyframe: Bool
    public let captureTimestamp: Double   // wall-clock seconds
    public let payload: Data
}

public enum MediaRecordError: Error, Equatable {
    case badMagic
    case badVersion(UInt8)
    case badTag(UInt8)
    case lengthOverCap(Int)
    case timestampOutOfRange
}

/// The parsed header fields of one LHM1 record, before its payload
/// arrives. FramedReader's `Header` for the media layout.
struct MediaFrameHeader {
    var tag: MediaTag
    var flags: UInt8
    var timestamp: Double
}

extension FramedReader where Header == MediaFrameHeader {
    /// The LHM1 layout (helpers/ledgehost-ipc.h names the C side):
    /// magic(4) version(1) tag(1) flags(1) reserved(1) timestamp(8)
    /// payload len(4), all big endian. Malformed framing throws
    /// MediaRecordError; an over-cap length is `lengthOverCap` there
    /// rather than the generic `FrameViolation.oversized` so the
    /// reader's error surface is unchanged.
    static func mediaRecords(maxPayload: Int = MediaRecordReader.maxPayload) -> FramedReader {
        let m = IPCLimits.mediaMagic
        return FramedReader(headerLength: IPCLimits.mediaHeaderLength,
                            maxPayload: maxPayload, policy: .fatal) { d in
            guard d[d.startIndex] == m[0], d[d.startIndex + 1] == m[1],
                  d[d.startIndex + 2] == m[2], d[d.startIndex + 3] == m[3]
            else { throw MediaRecordError.badMagic }
            let version = d[d.startIndex + 4]
            guard version == IPCLimits.mediaVersion else { throw MediaRecordError.badVersion(version) }
            let tagByte = d[d.startIndex + 5]
            guard let tag = MediaTag(rawValue: tagByte) else { throw MediaRecordError.badTag(tagByte) }
            let flags = d[d.startIndex + 6]
            let ts = Double(bitPattern: d.readBE(UInt64.self, at: 8))
            let len = Int(d.readBE(UInt32.self, at: 16))
            guard len <= maxPayload else { throw MediaRecordError.lengthOverCap(len) }
            return (MediaFrameHeader(tag: tag, flags: flags, timestamp: ts), len)
        }
    }
}

/// Incremental LHM1 reader. Feed bytes, take complete records.
/// Validation failure throws; the caller (daemon) kills the helper.
public struct MediaRecordReader {
    // Constants live in IPCLimits (mirror: helpers/ledgehost-ipc.h).
    public static let headerLength = IPCLimits.mediaHeaderLength
    public static let maxPayload = IPCLimits.mediaMaxPayload
    public static let magic = IPCLimits.mediaMagic

    private var reader = FramedReader.mediaRecords()
    private let timestampWindow: Double     // seconds either side of now; 0 = unchecked
    private let clock: () -> Double

    public init(timestampWindow: Double = 24 * 3600,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.timestampWindow = timestampWindow
        self.clock = clock
    }

    public mutating func feed(_ bytes: Data) throws -> [MediaRecord] {
        try reader.feed(bytes).map { h, payload in
            if timestampWindow > 0, abs(h.timestamp - clock()) > timestampWindow {
                throw MediaRecordError.timestampOutOfRange
            }
            return MediaRecord(tag: h.tag, isKeyframe: h.flags & 1 != 0,
                               captureTimestamp: h.timestamp, payload: payload)
        }
    }
}
