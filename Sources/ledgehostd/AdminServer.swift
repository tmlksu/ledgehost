import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore
#if canImport(Glibc)
import Glibc
#endif

// AdminServer — the unix-domain admin socket (docs/admin.md): one
// length-prefixed JSON request per connection at
// <configDir>/admin.sock, handled on ITS OWN single-threaded group so
// admin IO never queues behind session work on the serving loop.
//
// Trust boundary: the socket file itself (0600 inside the 0700 config
// dir) — no extra token. The pairing code crosses only this socket;
// the journal logs command shapes and outcomes, never the value.
//
// Session-registry reads/writes hop onto the session event loop via
// `submit` (the registry is loop-owned); pins and pairing state are
// NSLock-guarded and are touched directly.
//
// Failure to create the socket is loud but non-fatal: the daemon
// serves without an admin door.

final class AdminServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private let socketPath: String

    /// Binds <configDir>/admin.sock (0600). Throws — the caller decides
    /// whether that is fatal (it is not).
    init(configDir: URL) throws {
        socketPath = configDir.appendingPathComponent(AdminProtocol.socketName).path
        // A stale socket from a crashed run blocks the bind — remove
        // it. A live daemon's socket cannot be stolen this way: the
        // second daemon has already failed its home-door bind before
        // reaching here.
        unlink(socketPath)
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(AdminHandler())
            }
        channel = try bootstrap.bind(unixDomainSocketPath: socketPath).wait()
        chmod(socketPath, 0o600)
        print(Log.stamp(), "ledgehostd: admin socket at \(socketPath) (mode 0600)")
    }

    func stop() {
        channel?.close(promise: nil)
        try? group.syncShutdownGracefully()
        unlink(socketPath)
    }
}

/// One request per connection: len(4, BE, ≤64 KiB body) + JSON,
/// answered with one length-prefixed JSON reply and closed.
final class AdminHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var pending = Data()
    private var answered = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) { pending.append(contentsOf: bytes) }
        guard pending.count >= 4 else { return }
        let n = Int(pending.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard n <= AdminProtocol.maxRequestBytes else {
            answered = true
            reply(context: context, body: AdminProtocol.err("request over the 64 KiB cap"))
            return
        }
        guard pending.count >= 4 + n else { return }
        answered = true
        let body = pending.subdata(in: 4 ..< 4 + n)
        dispatch(body: body) { replyBody in
            // `dispatch` may answer from the session event loop — the
            // write itself must hop back onto this channel's loop.
            context.eventLoop.execute { self.reply(context: context, body: replyBody) }
        }
    }

    private func reply(context: ChannelHandlerContext, body: Data) {
        var out = context.channel.allocator.buffer(capacity: 4 + body.count)
        out.writeInteger(UInt32(body.count), endianness: .big)
        out.writeBytes(body)
        context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    // MARK: - Dispatch

    /// Session-registry reads/writes are loop-owned: they run via
    /// `eventLoop.submit`; pins and pairing state are NSLock-guarded
    /// and run directly on the admin connection's loop.
    private func dispatch(body: Data, respond: @escaping (Data) -> Void) {
        switch AdminProtocol.validate(body) {
        case .failure(let why):
            print(Log.stamp(), "ledgehostd: admin: rejected request — \(why)")
            let message: String
            switch why {
            case .undecodable: message = "request is not a valid admin JSON body"
            case .unknownCommand(let c): message = "unknown command '\(c)'"
            case .missingPrefix: message = "revoke needs a fingerprint prefix"
            }
            respond(AdminProtocol.err(message))
        case .success((let command, let request)):
            switch command {
            case .status:
                var fields: [String: Any] = [
                    "macID": identity.macID,
                    "name": identity.name,
                    "port": port,
                    "remote": remoteConfig.map {
                        ["port": $0.listenPort, "dialPort": $0.dialPort,
                         "address": $0.address, "via": $0.via]
                    } as Any,
                    "pairedDevices": pins.count,
                ]
                eventLoop.submit { registry.sessions.count }.whenComplete { result in
                    fields["activeSessions"] = (try? result.get()) ?? -1
                    print(Log.stamp(), "ledgehostd: admin: status — ok")
                    respond(AdminProtocol.ok(fields))
                }
            case .code:
                if request.new == true {
                    // `code --new` runs the same rotation the pairing
                    // door's own expiry/success paths use — the old
                    // code is dead the moment rotateLocked() returns.
                    pairing.rotate()
                    print(Log.stamp(), "ledgehostd: admin: code --new — rotated")
                }
                if let live = pairing.currentCode() {
                    print(Log.stamp(), "ledgehostd: admin: code — answered over the socket")
                    respond(AdminProtocol.ok(["code": live.code,
                                              "secondsLeft": live.secondsLeft]))
                } else {
                    print(Log.stamp(), "ledgehostd: admin: code — pairing door closed")
                    respond(AdminProtocol.err("pairing door is closed (credential generation failed)"))
                }
            case .devices:
                let list = pins.devices().map {
                    ["fingerprint": $0.fingerprint,
                     "name": $0.name,
                     "model": $0.model ?? ""] as [String: Any]
                }
                print(Log.stamp(), "ledgehostd: admin: devices — \(list.count) paired")
                respond(AdminProtocol.ok(["devices": list]))
            case .revoke:
                let wanted = request.prefix ?? ""
                let (match, candidates) = AdminProtocol.matchPrefix(
                    wanted, among: pins.devices().map { $0.fingerprint })
                guard candidates > 0 else {
                    print(Log.stamp(), "ledgehostd: admin: revoke — unknown prefix")
                    respond(AdminProtocol.err("no paired device matches prefix '\(wanted)'")); return
                }
                guard let match else {
                    print(Log.stamp(), "ledgehostd: admin: revoke — ambiguous prefix (\(candidates) matches)")
                    respond(AdminProtocol.err("prefix '\(wanted)' matches \(candidates) devices — use more characters")); return
                }
                do {
                    try pins.remove(encoded: match)
                } catch {
                    print(Log.stamp(), "ledgehostd: admin: revoke — pin write failed: \(error)")
                    respond(AdminProtocol.err("pin removal failed: \(error)")); return
                }
                // The pin is gone; drop the device's live sessions now
                // rather than on the 2 s revocation poll.
                eventLoop.submit { () -> Int in
                    var closed = 0
                    for session in registry.sessions.values
                    where session.peerFingerprint.map({ Base64URL.encode($0) }) == match {
                        session.send(kind: .goodbye,
                                     payload: Wire.encode(Goodbye(reason: "removed", reconnect: false)))
                        session.closeSoon()
                        closed += 1
                    }
                    return closed
                }.whenComplete { result in
                    let closed = (try? result.get()) ?? 0
                    print(Log.stamp(), "ledgehostd: admin: revoke — pin removed, \(closed) session(s) closed")
                    respond(AdminProtocol.ok(["revoked": match, "sessionsClosed": closed]))
                }
            }
        }
    }
}
