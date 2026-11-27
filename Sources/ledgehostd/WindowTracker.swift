import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore

// WindowTracker — the daemon's view of the display's windows
// (phase-2-plan.md): it runs `xquery watch`, whose stdout is a stream
// of whole-window-list snapshots ("win <xid-hex> <x> <y> <w> <h>
// <class> <title>" lines ended by "."), and keeps the latest one.
// The tracker itself is the Swift boundary: parsing and the filter
// rules that mirror xquery's listing rules live in LedgehostCore so
// they can be unit-tested without an X server.
//
// The subprocess is respawned ~1 s after death — window selection
// degrades to "no windows listed" while it is down, exactly like a
// pre-phase-2 host.

/// Runs `xquery watch`; keeps `windows` + `rootSize` current on the
/// event loop and fires `onChange` when the list changes content.
final class WindowTracker {
    private let loop: EventLoop
    private let display: String
    private let xauthority: String?
    private var process: Process?
    /// Parse state for the readability handler's (serial) queue; the
    /// committed snapshots it yields are applied on the loop.
    private var parser = XWindowListParser()
    private var stopping = false

    private(set) var windows: [XWindow] = []
    private(set) var rootSize: (w: Int, h: Int)?
    /// Fires on the loop after every content-changing snapshot.
    var onChange: (() -> Void)?

    init(loop: EventLoop, display: String, xauthority: String?) {
        self.loop = loop
        self.display = display
        self.xauthority = xauthority
    }

    func window(_ xid: UInt32) -> XWindow? { windows.first { $0.xid == xid } }

    /// All sessions' lists: the vendored WindowInfo array.
    var wireWindows: [WindowInfo] { windows.map(\.wire) }

    func start() {
        guard process == nil else { return }
        var paths: [String] = []
        if let exe = Bundle.main.executableURL {
            paths.append(exe.deletingLastPathComponent().appendingPathComponent("xquery").path)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/bin/xquery")
        guard let url = paths.lazy.map({ URL(fileURLWithPath: $0) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            print(Log.stamp(), "ledgehostd: windows: xquery not found — window sources unavailable")
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["watch"]
        var env: [String: String] = ["DISPLAY": display, "PATH": "/usr/bin:/bin",
                                   "HOME": NSHomeDirectory()]
        if let xauthority { env["XAUTHORITY"] = xauthority }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = Pipe()
        p.standardError = FileHandle.nullDevice
        // Parse on the (serial) readability queue; each committed
        // snapshot hops to the event loop.
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else { return }
            let snaps = self.parser.feed(bytes: data)
            let rs = self.parser.rootSize
            for snap in snaps {
                self.loop.execute { [weak self] in
                    self?.apply(snapshot: snap, rootSize: rs)
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            self?.loop.execute { [weak self] in
                guard let self, !self.stopping else { return }
                self.process = nil
                self.loop.scheduleTask(in: .seconds(1)) { [weak self] in self?.start() }
            }
        }
        do { try p.run(); process = p }
        catch {
            print(Log.stamp(), "ledgehostd: windows: xquery spawn failed: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
    }

    private func apply(snapshot: [XWindow], rootSize: (w: Int, h: Int)?) {
        windows = snapshot
        if let rootSize { self.rootSize = rootSize }
        onChange?()
    }
}
