import Foundation

// Admin protocol (docs/admin.md): one length-prefixed JSON request per
// unix-socket connection — len(4, BE) + JSON body, same framing style
// as the input-helper records — then one length-prefixed JSON reply
// and the connection closes. The daemon's listener lives at
// <configDir>/admin.sock; the socket itself is the trust boundary.
//
// Responses carrying the pairing code travel only over this socket:
// the daemon logs command shapes, never the code value.

public enum AdminProtocol {
    /// Largest accepted request frame: len(4) + body.
    public static let maxRequestBytes = 64 << 10
    /// Same bound for replies (devices lists are small; the bound
    /// keeps a reader honest).
    public static let maxResponseBytes = 64 << 10

    public static let socketName = "admin.sock"

    // MARK: - Wire shapes

    /// `{ "command": "status" | "code" | "devices" | "revoke",
    ///    "new": true?, "prefix": "..."? }`
    public struct Request: Codable {
        public var command: String
        public var new: Bool?
        public var prefix: String?
        public init(command: String, new: Bool? = nil, prefix: String? = nil) {
            self.command = command; self.new = new; self.prefix = prefix
        }
    }

    /// `{ "ok": true, ...fields }` or `{ "ok": false, "error": "..." }`.
    /// Replies carry named fields rather than a shared payload shape —
    /// status/devices/code look nothing alike — so the reply is a
    /// dictionary encoded once.
    public static func ok(_ fields: [String: Any]) -> Data {
        var obj = fields
        obj["ok"] = true
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func err(_ message: String) -> Data {
        let obj: [String: Any] = ["ok": false, "error": message]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Request validation

    public enum Command: String {
        case status, code, devices, revoke
    }

    public enum ValidationError: Error, Equatable {
        case undecodable
        case unknownCommand(String)
        case missingPrefix
    }

    /// Parse a request body into a validated command. Unknown commands,
    /// undecodable JSON and a revoke without a prefix are refused here;
    /// semantic checks (ambiguous prefix, closed pairing door) happen
    /// at dispatch.
    public static func validate(_ body: Data) -> Result<(Command, Request), ValidationError> {
        guard let request = try? JSONDecoder().decode(Request.self, from: body) else {
            return .failure(.undecodable)
        }
        guard let command = Command(rawValue: request.command) else {
            return .failure(.unknownCommand(request.command))
        }
        if command == .revoke {
            guard let prefix = request.prefix, !prefix.isEmpty else {
                return .failure(.missingPrefix)
            }
        }
        return .success((command, request))
    }

    // MARK: - Prefix matching (revoke)

    /// Unambiguous fingerprint-prefix matching for `revoke`: the prefix
    /// is matched verbatim (base64url is case-sensitive) against the
    /// stored encodings. nil = no unique match — the caller reports
    /// unknown vs ambiguous from `candidates`.
    public static func matchPrefix(_ prefix: String,
                                   among fingerprints: [String]) -> (match: String?, candidates: Int) {
        let hits = fingerprints.filter { $0.hasPrefix(prefix) }
        return (hits.count == 1 ? hits[0] : nil, hits.count)
    }
}
