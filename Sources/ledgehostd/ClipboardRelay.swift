import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore

// Clipboard relay (audit R1/R-1): kind 32 in both directions — a
// device's .set becomes the host CLIPBOARD selection and is relayed to
// the other subscribers; a foreign X client's copy rides the input
// helper's output records back to every subscriber.

/// The last text a device set: the helper's own tracking is the
/// primary echo guard; this is the daemon-side defence in depth
/// (dropped when the helper reports the same text back).
private var deviceSetText: String?

/// A foreign client's CLIPBOARD text → every subscribed connection,
/// unless it is the text a device itself just set (echo suppression).
func wireClipboardRelay() {
    input.onClipboard = { text in
        // deviceSetText is a single-use echo token (audit S9/S-D): consumed
        // on the first helper report, matching or not, so a device-set text
        // cannot indefinitely suppress a foreign copy of the same content.
        let isEcho = text == deviceSetText
        deviceSetText = nil
        if isEcho {
            print(Log.stamp(), "ledgehostd: clipboard: \(text.utf8.count) byte(s) match the device's own set — not broadcast")
            return
        }
        guard let payload = ClipboardPolicy.payload(text: text) else {
            print(Log.stamp(), "ledgehostd: clipboard: host text \(text.utf8.count) byte(s) not sendable — dropped")
            return
        }
        var n = 0
        for session in registry.sessions.values where session.clipboardSubscribed {
            session.send(kind: .clipboard, payload: payload); n += 1
        }
        print(Log.stamp(), "ledgehostd: clipboard: host text \(text.utf8.count) byte(s) -> \(n) subscriber(s)")
    }
}

extension ConnectionHandler {
    /// kind 32 clipboard (ClipboardPolicy): a decodable message
    /// subscribes; a non-empty text becomes the host clipboard and is
    /// relayed verbatim to every OTHER subscriber; stop wins. Refusals
    /// (undecodable, oversize, rate) are silent. Content is never
    /// logged — sizes and counts only.
    func handleClipboard(context: ChannelHandlerContext, payload: Data) {
        guard payload.count <= ClipboardPolicy.maxPayload else { return }
        let (ask, kept) = ClipboardPolicy.hostReceives(payload,
                                                       arrivals: clipboardArrivals,
                                                       now: Date().timeIntervalSince1970)
        clipboardArrivals = kept
        switch ask {
        case .subscribe:
            if !clipboardSubscribed {
                clipboardSubscribed = true
                print(Log.stamp(), "ledgehostd: \(label) subscribed to the clipboard")
            }
        case .set(let text):
            clipboardSubscribed = true
            print(Log.stamp(), "ledgehostd: \(label) set the clipboard (\(text.utf8.count) bytes)")
            deviceSetText = text          // echo suppression, defence in depth
            input.setClipboard(text)
            // Relay a re-encoded text-only payload (audit S8/S-C), never
            // the received bytes verbatim — a crafted message could
            // otherwise smuggle extra fields to other subscribers.
            if let relay = ClipboardPolicy.payload(text: text) {
                for other in registry.sessions.values where other !== self && other.clipboardSubscribed {
                    other.send(kind: .clipboard, payload: relay)
                }
            }
        case .stop:
            if clipboardSubscribed {
                clipboardSubscribed = false
                print(Log.stamp(), "ledgehostd: \(label) unsubscribed from the clipboard")
            }
        case .refuse(let why):
            if msgLog.emit() != nil {
                print(Log.stamp(), "ledgehostd: \(label) clipboard refused (\(why))")
            }
        }
    }
}
