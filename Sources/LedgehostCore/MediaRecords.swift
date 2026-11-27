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

/// Incremental LHM1 reader. Feed bytes, take complete records.
/// Validation failure throws; the caller (daemon) kills the helper.
public struct MediaRecordReader {
    // Constants live in IPCLimits (mirror: helpers/ledgehost-ipc.h).
    public static let headerLength = IPCLimits.mediaHeaderLength
    public static let maxPayload = IPCLimits.mediaMaxPayload
    public static let magic = IPCLimits.mediaMagic

    private var buffer = Data()
    private let timestampWindow: Double     // seconds either side of now; 0 = unchecked
    private let clock: () -> Double

    public init(timestampWindow: Double = 24 * 3600,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.timestampWindow = timestampWindow
        self.clock = clock
    }

    public mutating func feed(_ bytes: Data) throws -> [MediaRecord] {
        buffer.append(bytes)
        var out: [MediaRecord] = []
        while buffer.count >= Self.headerLength {
            let b = buffer
            guard b[b.startIndex] == Self.magic[0], b[b.startIndex + 1] == Self.magic[1],
                  b[b.startIndex + 2] == Self.magic[2], b[b.startIndex + 3] == Self.magic[3]
            else { throw MediaRecordError.badMagic }
            let version = b[b.startIndex + 4]
            guard version == IPCLimits.mediaVersion else { throw MediaRecordError.badVersion(version) }
            let tagByte = b[b.startIndex + 5]
            guard let tag = MediaTag(rawValue: tagByte) else { throw MediaRecordError.badTag(tagByte) }
            let flags = b[b.startIndex + 6]
            let ts = Double(bitPattern: b.readBE(UInt64.self, at: 8))
            let len = Int(b.readBE(UInt32.self, at: 16))
            guard len <= Self.maxPayload else { throw MediaRecordError.lengthOverCap(len) }
            guard buffer.count >= Self.headerLength + len else {
                if out.isEmpty { return [] }
                return out
            }
            if timestampWindow > 0, abs(ts - clock()) > timestampWindow {
                throw MediaRecordError.timestampOutOfRange
            }
            let payload = buffer.subdata(in: buffer.startIndex + Self.headerLength
                                         ..< buffer.startIndex + Self.headerLength + len)
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + Self.headerLength + len)
            out.append(MediaRecord(tag: tag, isKeyframe: flags & 1 != 0,
                                  captureTimestamp: ts, payload: payload))
        }
        return out
    }
}
