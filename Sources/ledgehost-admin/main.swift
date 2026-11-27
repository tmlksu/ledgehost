import Foundation
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// ledgehost-admin — the operator CLI for a running ledgehostd
// (docs/admin.md). Sends ONE length-prefixed JSON request to the
// daemon's unix socket at <configDir>/admin.sock and prints the reply
// in a human-readable form.
//
// Usage:
//   ledgehost-admin status
//   ledgehost-admin code [--new]
//   ledgehost-admin devices
//   ledgehost-admin revoke <fingerprint-prefix>
//
// The config dir follows the same rule as the daemon
// (XDG_CONFIG_HOME/ledgehost); --config <dir> overrides it.

func usage() -> Never {
    fputs("""
        usage: ledgehost-admin [--config DIR] <command>
          status                     host identity, ports, counts
          code [--new]               the live pairing code and its
                                     remaining validity (--new rotates first)
          devices                    paired devices
          revoke <fingerprint-prefix>  remove a pin and drop its sessions

        """, stderr)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var configDir = configDirectory("ledgehost")
if let i = args.firstIndex(of: "--config") {
    guard i + 1 < args.count else { usage() }
    configDir = URL(fileURLWithPath: args[i + 1])
    args.removeSubrange(i ... i + 1)
}
guard let command = args.first else { usage() }

let request: AdminProtocol.Request
switch command {
case "status":
    guard args.count == 1 else { usage() }
    request = AdminProtocol.Request(command: "status")
case "code":
    var new = false
    for a in args.dropFirst() {
        guard a == "--new" else { usage() }
        new = true
    }
    request = AdminProtocol.Request(command: "code", new: new ? true : nil)
case "devices":
    guard args.count == 1 else { usage() }
    request = AdminProtocol.Request(command: "devices")
case "revoke":
    guard args.count == 2, !args[1].isEmpty else { usage() }
    request = AdminProtocol.Request(command: "revoke", prefix: args[1])
default:
    fputs("ledgehost-admin: unknown command '\(command)'\n", stderr)
    usage()
}

// MARK: - Socket round-trip (blocking POSIX — a one-shot CLI needs no
// event loop)

func fail(_ message: String) -> Never {
    fputs("ledgehost-admin: \(message)\n", stderr)
    exit(1)
}

let sockPath = configDir.appendingPathComponent(AdminProtocol.socketName).path
let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
guard fd >= 0 else { fail("socket() failed: errno \(errno)") }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(sockPath.utf8CString)
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
    fail("socket path too long: \(sockPath)")
}
pathBytes.withUnsafeBytes { src in
    withUnsafeMutableBytes(of: &addr.sun_path) { sunPath in
        sunPath.copyMemory(from: src)
    }
}
let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else {
    fail("cannot reach the admin socket at \(sockPath) (errno \(errno)) — is ledgehostd running with this config dir?")
}

var frame = Data()
var len = UInt32(0)
do {
    let body = try JSONEncoder().encode(request)
    len = UInt32(body.count).bigEndian
    withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
    frame.append(body)
    try frame.withUnsafeBytes { ptr in
        var sent = 0
        while sent < frame.count {
            let w = write(fd, ptr.baseAddress! + sent, frame.count - sent)
            guard w > 0 else { throw POSIXError(.EIO) }
            sent += w
        }
    }
} catch {
    fail("send failed: \(error)")
}

func readExact(_ n: Int) -> Data? {
    var out = Data(count: n)
    var got = 0
    while got < n {
        let r = out.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, n - got, 0) }
        guard r > 0 else { return nil }
        got += r
    }
    return out
}

guard let hdr = readExact(4) else { fail("no reply from the daemon") }
// Inline Data storage is not guaranteed aligned — compose the BE
// length byte-wise instead of a typed load.
let bodyLen = hdr.reduce(0) { ($0 << 8) | Int($1) }
guard bodyLen <= AdminProtocol.maxResponseBytes else { fail("reply over the cap") }
guard let body = readExact(bodyLen) else { fail("truncated reply") }

// MARK: - Print

guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
    fail("unparseable reply")
}
guard (obj["ok"] as? Bool) == true else {
    fail(String(describing: obj["error"] ?? "command failed"))
}

switch command {
case "status":
    print("host       \(obj["name"] ?? "?")  mac id \(obj["macID"] ?? "?")")
    print("home port  \(obj["port"] ?? "?")")
    if let remote = obj["remote"] as? [String: Any] {
        print("remote     \(remote["address"] ?? "?") dial \(remote["dialPort"] ?? "?") "
              + "listen \(remote["port"] ?? "?") via \(remote["via"] ?? "?")")
    } else {
        print("remote     disabled")
    }
    print("paired     \(obj["pairedDevices"] ?? "?") device(s), "
          + "sessions  \(obj["activeSessions"] ?? "?")")
case "code":
    if obj["rotating"] as? Bool == true {
        print("rotating — the old code is dead; the new one is being derived (a few seconds)")
    } else {
        print("code \(obj["code"] ?? "?")   valid ~\(obj["secondsLeft"] ?? "?") s")
    }
case "devices":
    guard let list = obj["devices"] as? [[String: Any]] else { fail("malformed devices reply") }
    if list.isEmpty { print("no paired devices") }
    for d in list {
        let fp = (d["fingerprint"] as? String) ?? ""
        print("\(String(fp.prefix(8)))  \(d["name"] ?? "?")  \(d["model"] ?? "")")
    }
case "revoke":
    let fp = (obj["revoked"] as? String) ?? ""
    print("revoked \(String(fp.prefix(8)))…  closed \(obj["sessionsClosed"] ?? 0) session(s)")
default:
    break
}
