import Foundation
import StreamProtocol

// Remote-access configuration (docs/remote-access-plan.md): the host
// advertises ONE "vpn" address that devices reach through the user's
// WARP/Zero Trust route, and runs a second listener — the remote door —
// with the identical session gates. All OFF by default: unset
// LH_REMOTE_PORT means no remote door and the same kind 18 as before.
//
// Invalid values are a loud startup failure, never a silent fallback.

public enum RemoteConfigError: Error, Equatable {
    case badPort(String)              // unparsable or out of range
    case missingAddress               // port set, address unset/blank
    case addressCarriesPort(String)   // "host:port" — the port lives in remotePort
    case badVia                       // set but blank
    case remotePortIsHomePort         // would double-bind the home door
}

public struct RemoteConfig: Equatable {
    /// The remote door's listen port (LH_REMOTE_PORT).
    public let listenPort: Int
    /// What devices dial — LH_REMOTE_DIAL_PORT for a forwarded-port
    /// setup, else the listen port. Lands in MacInfo.remotePort.
    public let dialPort: Int
    /// The host string, verbatim into MacInfo.addresses[0].host.
    public let address: String
    /// MacAddress.via display string (LH_REMOTE_VIA, default "VPN").
    public let via: String

    public static let envPort = "LH_REMOTE_PORT"
    public static let envAddress = "LH_REMOTE_ADDRESS"
    public static let envDialPort = "LH_REMOTE_DIAL_PORT"
    public static let envVia = "LH_REMOTE_VIA"
    public static let defaultVia = "VPN"

    /// Parse the environment; nil when LH_REMOTE_PORT is unset or
    /// blank — remote access disabled. Throws RemoteConfigError on
    /// anything malformed when it IS set.
    public static func load(env: [String: String],
                            homePort: Int) throws -> RemoteConfig? {
        guard let raw = env[envPort]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        guard let listenPort = Int(raw), (1...65535).contains(listenPort) else {
            throw RemoteConfigError.badPort("\(envPort)=\(raw)")
        }
        guard listenPort != homePort else { throw RemoteConfigError.remotePortIsHomePort }

        guard let address = env[envAddress]?.trimmingCharacters(in: .whitespaces),
              !address.isEmpty else { throw RemoteConfigError.missingAddress }
        // One colon means "host:port" — rejected: the dial port lives
        // in MacInfo.remotePort. Zero colons = plain host/IPv4; several
        // = a bare IPv6 literal, which the vendored format wants
        // without brackets anyway.
        if address.filter({ $0 == ":" }).count == 1 {
            throw RemoteConfigError.addressCarriesPort(address)
        }
        guard !address.contains(where: { $0.isWhitespace }) else {
            throw RemoteConfigError.addressCarriesPort(address)
        }

        var dialPort = listenPort
        if let rawDial = env[envDialPort]?.trimmingCharacters(in: .whitespaces),
           !rawDial.isEmpty {
            guard let p = Int(rawDial), (1...65535).contains(p) else {
                throw RemoteConfigError.badPort("\(envDialPort)=\(rawDial)")
            }
            dialPort = p
        }

        var via = defaultVia
        if let v = env[envVia] {
            guard !v.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw RemoteConfigError.badVia
            }
            via = v
        }

        return RemoteConfig(listenPort: listenPort, dialPort: dialPort,
                            address: address, via: via)
    }

    /// The MacInfo the remote door advertises (and every session's
    /// kind 18 when configured).
    public func macInfo(identity: HostIdentity, at now: Date = Date()) -> MacInfo {
        MacInfo(v: 1, macID: identity.macID, name: identity.name,
                issuedAt: now.timeIntervalSince1970,
                remoteAccess: true, remotePort: dialPort, internet: false,
                addresses: [MacAddress(host: address, port: nil,
                                       kind: MacAddress.vpn, via: via)])
    }
}
