import Foundation

// Big-endian byte helpers for LedgehostCore. The vendored StreamProtocol
// module keeps its own (internal) copies on Data; these are module-private
// here so the vendored tree stays pristine.

extension Data {
    func readBE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        let start = startIndex + offset
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            copyBytes(to: dst, from: start..<(start + MemoryLayout<T>.size))
        }
        return T(bigEndian: v)
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
