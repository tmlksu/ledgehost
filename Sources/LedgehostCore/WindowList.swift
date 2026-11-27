import Foundation
import StreamProtocol

// The xquery window snapshot types (phase 2). The daemon's
// WindowTracker feeds xquery watch's stdout through XWindowListParser
// and keeps the result live. XWindow -> WindowInfo is the id mapping:
// id IS the xid (stable for the window's life, and a valid
// ximagesrc/xdotool argument for capture and movement).
//
// xquery's snapshot format: "root <w> <h>", then one
// "win <xid-hex> <x> <y> <w> <h> <class> <title>" per listable window
// (xquery filtered: viewable, non-override-redirect, non-desktop,
// non-empty), then "." ends the snapshot.

/// One listable window as xquery reports it.
public struct XWindow: Equatable, Sendable {
    public let xid: UInt32
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    /// WM_CLASS's class part ("Mousepad") — the wire's appName.
    public var appClass: String
    public var title: String

    public init(xid: UInt32, x: Int, y: Int, width: Int, height: Int,
                appClass: String, title: String) {
        self.xid = xid; self.x = x; self.y = y
        self.width = width; self.height = height
        self.appClass = appClass; self.title = title
    }

    /// The vendored wire shape: id IS the xid; bundleID is a
    /// best-effort "instance.class" stand-in.
    public var wire: WindowInfo {
        WindowInfo(id: xid, title: title, appName: appClass,
                   bundleID: appClass.lowercased() + "." + appClass,
                   width: width, height: height)
    }
}

/// Incremental parser for xquery's snapshot stream: "win" lines
/// accumulate, "." commits them as the new snapshot. Content-equal
/// snapshots are dropped (watch re-emits on any X event burst, most
/// of which don't change the list).
public struct XWindowListParser {
    public private(set) var snapshot: [XWindow] = []
    private var pending: [XWindow] = []
    public private(set) var rootSize: (w: Int, h: Int)?

    public init() {}

    /// Feed one decoded line; returns a new snapshot on "." commits
    /// whose content differs from the last one.
    public mutating func feed(line: String) -> [XWindow]? {
        if line == "." {
            let out = pending == snapshot ? nil : pending
            snapshot = pending
            pending = []
            return out
        }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        if f.first == "root" {
            if f.count >= 3, let w = Int(f[1]), let h = Int(f[2]) {
                rootSize = (w, h)
            }
            return nil
        }
        guard f.count >= 7, f[0] == "win",
              let xid = UInt32(f[1], radix: 16),
              let x = Int(f[2]), let y = Int(f[3]),
              let w = Int(f[4]), let h = Int(f[5]),
              w > 0, h > 0
        else { return nil }
        let cls = f[6] == "-" ? "" : String(f[6])
        let title = f.dropFirst(7).joined(separator: " ")
        pending.append(XWindow(xid: xid, x: x, y: y, width: w, height: h,
                               appClass: cls, title: title))
        return nil
    }

    /// Bytes -> lines -> snapshots; a partial tail is kept for the
    /// next feed. Returns each committed snapshot.
    public mutating func feed(bytes: Data) -> [[XWindow]] {
        partial += String(decoding: bytes, as: UTF8.self)
        var out: [[XWindow]] = []
        while let nl = partial.firstIndex(of: "\n") {
            let line = String(partial[..<nl])
            partial.removeSubrange(...nl)
            if let snap = feed(line: line) { out.append(snap) }
        }
        return out
    }

    private var partial = ""
}
