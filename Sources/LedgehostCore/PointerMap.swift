import Foundation
import StreamProtocol

// Source-space pointer mapping for kind 26 (MacPointer): a root-space
// position becomes `inside` + x/y fractions of the watched source's
// frame (the vendored wire space — 0…1 across the streamed frame,
// rounded as MacPointer.rounded does), or inside=false when the
// pointer is off that source's rectangle.
public enum SourcePointer {
    /// `rect` is the watched source's screen rectangle (the root for
    /// the desktop, the window's rect for a window source). -1/-1
    /// (off the screen entirely) maps to inside=false.
    public static func map(rx: Int, ry: Int,
                           rect: (x: Int, y: Int, w: Int, h: Int)?)
        -> (inside: Bool, x: Double, y: Double) {
        guard let rect, rx >= 0, ry >= 0, rect.w > 0, rect.h > 0,
              rx >= rect.x, rx < rect.x + rect.w,
              ry >= rect.y, ry < rect.y + rect.h else {
            return (false, -1, -1)
        }
        return (true,
                MacPointer.rounded(Double(rx - rect.x) / Double(rect.w)),
                MacPointer.rounded(Double(ry - rect.y) / Double(rect.h)))
    }
}
