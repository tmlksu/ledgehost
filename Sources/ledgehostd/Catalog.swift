import Foundation
import NIO
import NIOCore
import StreamProtocol
import LedgehostCore

// The session catalog (audit R1/R-1): what a fresh session is told —
// the window list, the settings state, the signed host info.

extension ConnectionHandler {
    func sendWindowList(context: ChannelHandlerContext, active: StreamSource) {
        let list = WindowList(macName: identity.name, windows: [], active: active,
                              launchID: identity.launchID, hostVersion: "0.0.0-linux",
                              protocol: 1, clipboard: ClipboardPolicy.generation)
        send(context: context, kind: .windowList, payload: Wire.encode(list))
    }

    func settingsState(answering: Int? = nil) -> HostSettingsState {
        HostSettingsState(
            settings: settings,
            // Settings live in memory only — a daemon restart returns to
            // compiled defaults, so the client must not mark them saved.
            persistent: false, virtualDisplayAvailable: false,
            virtualDisplayNote: "virtual display is not available on this host",
            softwareEncoder: false,
            stream: media.runningInfo.fps > 0
                ? RunningStream(width: media.runningInfo.width, height: media.runningInfo.height,
                                fps: media.runningInfo.fps, mbps: media.runningInfo.mbps,
                                onVirtualDisplay: false)
                : nil,
            answering: answering,
            sessionPaired: true)
    }

    func sendCatalog(context: ChannelHandlerContext) {
        sendWindowList(context: context, active: .none)
        send(context: context, kind: .hostSettings, payload: Wire.encode(settingsState()))
        let info = MacInfo(v: 1, macID: identity.macID, name: identity.name,
                           issuedAt: Date().timeIntervalSince1970, remoteAccess: false,
                           remotePort: port, internet: false, addresses: [])
        if let signed = SignedMacInfo.signing(info, with: identity.privateKey) {
            send(context: context, kind: .macInfo, payload: Wire.encode(signed))
        }
    }
}
