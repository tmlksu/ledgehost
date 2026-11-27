import Foundation
import NIO
import StreamProtocol
import LedgehostCore

// PointerTracker — tails `xquery pointer` for kind 26 (MacPointer,
// the vendored contract): the host's pointer position, sent to every
// watching session except the one driving input (the injector), and
// only while some session watches a source. `xquery` prints one
// "ptr <x> <y>" line (root coordinates) per move at ~30 Hz, which is
// the throttle — nothing goes on the wire while the pointer idles.
// Each watcher gets coordinates as fractions of ITS source's frame:
// the root for the desktop, the watched window's rect for a window
// source (inside=false when the pointer is outside it, matching the
// vendored "off the stream" payload). Per-session dedup on
// (inside,x,y) keeps repeated positions off the wire even when the
// `seen` counter moves.

final class PointerTracker {
    let loop: EventLoop
    private let display: String
    private let xauthority: String?
    private var process: Process?
    private var stopping = false
    private var pending = ""        // unterminated line fragment

    init(loop: EventLoop, display: String, xauthority: String?) {
        self.loop = loop
        self.display = display
        self.xauthority = xauthority
    }

    /// Called on the event loop whenever the watcher set may have
    /// changed: the tailer runs only while watchers exist — no
    /// viewers means no pointer traffic and no polling helper.
    func noteWatchersChanged() {
        if registry.watchers.isEmpty { stop() } else { start() }
    }

    private func start() {
        guard process == nil else { return }
        var paths: [String] = []
        if let exe = Bundle.main.executableURL {
            paths.append(exe.deletingLastPathComponent().appendingPathComponent("xquery").path)
        }
        paths.append(FileManager.default.currentDirectoryPath + "/bin/xquery")
        guard let url = paths.lazy.map({ URL(fileURLWithPath: $0) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            print(Log.stamp(), "ledgehostd: pointer: xquery not found — pointer updates unavailable")
            return
        }
        let p = Process()
        p.executableURL = url
        p.arguments = ["pointer"]
        var env: [String: String] = ["DISPLAY": display, "PATH": "/usr/bin:/bin",
                                   "HOME": NSHomeDirectory()]
        if let xauthority { env["XAUTHORITY"] = xauthority }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = Pipe()
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else { return }
            self.feed(bytes: data)
        }
        p.terminationHandler = { [weak self] _ in
            self?.loop.execute { [weak self] in
                guard let self, !self.stopping else { return }
                self.process = nil
                if !registry.watchers.isEmpty {
                    self.loop.scheduleTask(in: .seconds(1)) { [weak self] in self?.start() }
                }
            }
        }
        do { try p.run(); process = p }
        catch {
            print(Log.stamp(), "ledgehostd: pointer: xquery spawn failed: \(error)")
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
        process = nil
        pending = ""
    }

    /// Parses on the readability queue; each completed line hops to
    /// the event loop. Lines: "root <w> <h>" (rootSize in the window
    /// tracker is authoritative; this line is consumed only), and
    /// "ptr <x> <y>" / "ptr -1 -1" (off the screen).
    private func feed(bytes: Data) {
        guard let chunk = String(data: bytes, encoding: .utf8) else { return }
        pending += chunk
        var lines: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            lines.append(String(pending[pending.startIndex..<nl]))
            pending.removeSubrange(pending.startIndex...nl)
        }
        for line in lines {
            let f = line.split(separator: " ")
            if f.count == 3, f[0] == "ptr",
               let x = Int(f[1]), let y = Int(f[2]) {
                let rx = x, ry = y
                loop.execute { [weak self] in self?.broadcast(rx: rx, ry: ry) }
            }
        }
    }

    private func broadcast(rx: Int, ry: Int) {
        for session in registry.watchers where !session.isDrivingPointer {
            session.pointerChanged(rx: rx, ry: ry)
        }
    }
}
