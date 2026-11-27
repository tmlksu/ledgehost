import XCTest
import Crypto
import StreamProtocol
@testable import LedgehostCore

// Remote-access config parsing + the kind-18 MacInfo construction
// (docs/remote-access-plan.md). Addresses are documentation-range
// (192.0.2.0/24) or loopback — never a real one.

final class RemoteConfigTests: XCTestCase {
    func testUnsetDisables() throws {
        XCTAssertNil(try RemoteConfig.load(env: [:], homePort: 7455))
        XCTAssertNil(try RemoteConfig.load(env: ["LH_REMOTE_PORT": " "], homePort: 7455))
    }

    func testMinimalConfig() throws {
        let c = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
        ], homePort: 7455)
        XCTAssertEqual(c?.listenPort, 17470)
        XCTAssertEqual(c?.dialPort, 17470)          // no override
        XCTAssertEqual(c?.address, "192.0.2.10")
        XCTAssertEqual(c?.via, "VPN")               // default
    }

    func testDialPortAndViaOverrides() throws {
        let c = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_DIAL_PORT": "443",
            "LH_REMOTE_ADDRESS": "host.example.test",
            "LH_REMOTE_VIA": "VPN (warp0)",
        ], homePort: 7455)
        XCTAssertEqual(c?.dialPort, 443)
        XCTAssertEqual(c?.via, "VPN (warp0)")
    }

    func testValidationFailures() throws {
        let base: [String: String] = ["LH_REMOTE_PORT": "17470", "LH_REMOTE_ADDRESS": "192.0.2.10"]
        // Missing address
        XCTAssertThrowsError(try RemoteConfig.load(env: ["LH_REMOTE_PORT": "17470"],
                                                   homePort: 7455)) {
            XCTAssertEqual($0 as? RemoteConfigError, .missingAddress)
        }
        // Bad ports
        for p in ["abc", "0", "70000", "-1"] {
            var env = base; env["LH_REMOTE_PORT"] = p
            XCTAssertThrowsError(try RemoteConfig.load(env: env, homePort: 7455)) {
                guard case .badPort = ($0 as? RemoteConfigError) else {
                    return XCTFail("\(p): expected badPort, got \($0)")
                }
            }
        }
        // host:port address rejected
        var env2 = base; env2["LH_REMOTE_ADDRESS"] = "192.0.2.10:8443"
        XCTAssertThrowsError(try RemoteConfig.load(env: env2, homePort: 7455)) {
            guard case .addressCarriesPort = ($0 as? RemoteConfigError) else {
                return XCTFail("expected addressCarriesPort, got \($0)")
            }
        }
        // IPv6 literal (several colons) accepted
        var env3 = base; env3["LH_REMOTE_ADDRESS"] = "fd7a:115c:a1e0::1234"
        XCTAssertEqual(try RemoteConfig.load(env: env3, homePort: 7455)?.address,
                       "fd7a:115c:a1e0::1234")
        // Blank via
        var env4 = base; env4["LH_REMOTE_VIA"] = "  "
        XCTAssertThrowsError(try RemoteConfig.load(env: env4, homePort: 7455)) {
            XCTAssertEqual($0 as? RemoteConfigError, .badVia)
        }
        // Remote port == home port rejected
        var env5 = base; env5["LH_REMOTE_PORT"] = "7455"
        XCTAssertThrowsError(try RemoteConfig.load(env: env5, homePort: 7455)) {
            XCTAssertEqual($0 as? RemoteConfigError, .remotePortIsHomePort)
        }
        // Bad dial port
        var env6 = base; env6["LH_REMOTE_DIAL_PORT"] = "nope"
        XCTAssertThrowsError(try RemoteConfig.load(env: env6, homePort: 7455))
    }

    // --- LH_REMOTE_BITRATE_KBPS (remote-door initial bitrate) ---

    func testBitrateDefaultsTo6000WhenEnabled() throws {
        let c = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
        ], homePort: 7455)
        XCTAssertEqual(c?.bitrateKbps, 6000)
    }

    func testBitrateExplicitValue() throws {
        let c = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
            "LH_REMOTE_BITRATE_KBPS": "2500",
        ], homePort: 7455)
        XCTAssertEqual(c?.bitrateKbps, 2500)
    }

    func testBitrateZeroMeansHomeDefault() throws {
        let c = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
            "LH_REMOTE_BITRATE_KBPS": "0",
        ], homePort: 7455)
        XCTAssertNil(c?.bitrateKbps)
    }

    func testBitrateValidationFailures() throws {
        let base: [String: String] = ["LH_REMOTE_PORT": "17470", "LH_REMOTE_ADDRESS": "192.0.2.10"]
        for v in ["abc", "-1", "2000000"] {
            var env = base; env["LH_REMOTE_BITRATE_KBPS"] = v
            XCTAssertThrowsError(try RemoteConfig.load(env: env, homePort: 7455)) {
                guard case .badBitrate = ($0 as? RemoteConfigError) else {
                    return XCTFail("\(v): expected badBitrate, got \($0)")
                }
            }
        }
        // Blank falls back to the remote default
        var env = base; env["LH_REMOTE_BITRATE_KBPS"] = "  "
        XCTAssertEqual(try RemoteConfig.load(env: env, homePort: 7455)?.bitrateKbps, 6000)
    }

    // --- MacInfo construction (proof f: unit-test the daemon side) ---

    private func scratchIdentity() throws -> HostIdentity {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-test-\(UUID().uuidString)")
        return try HostIdentity.loadOrCreate(in: dir)
    }

    func testMacInfoFieldsMatchConfig() throws {
        let config = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_DIAL_PORT": "443",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
            "LH_REMOTE_VIA": "VPN (warp0)",
        ], homePort: 7455)!
        let identity = try scratchIdentity()
        let before = Date().timeIntervalSince1970
        let info = config.macInfo(identity: identity)
        XCTAssertTrue(info.remoteAccess)
        XCTAssertFalse(info.internet)
        XCTAssertEqual(info.remotePort, 443)            // DIAL port, not listen
        XCTAssertEqual(info.macID, identity.macID)
        XCTAssertEqual(info.name, identity.name)
        XCTAssertEqual(info.v, 1)
        XCTAssertEqual(info.issuedAt, before, accuracy: 5)
        XCTAssertEqual(info.addresses.count, 1)
        let a = info.addresses[0]
        XCTAssertEqual(a.host, "192.0.2.10")
        XCTAssertNil(a.port)                            // dial port lives in remotePort
        XCTAssertEqual(a.kind, "vpn")
        XCTAssertEqual(a.via, "VPN (warp0)")
    }

    /// The vendored verify path accepts what the daemon builds: a
    /// SignedMacInfo over this MacInfo round-trips through verified()
    /// and the fingerprint is the identity's.
    func testSignedMacInfoVerifies() throws {
        let config = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
        ], homePort: 7455)!
        let identity = try scratchIdentity()
        let info = config.macInfo(identity: identity)
        let signed = SignedMacInfo.signing(info, with: identity.privateKey)
        XCTAssertNotNil(signed)
        let verified = signed?.verified()
        XCTAssertNotNil(verified)
        XCTAssertEqual(verified?.fingerprint, identity.fingerprint)
        XCTAssertEqual(verified?.info.addresses[0].host, "192.0.2.10")
        XCTAssertEqual(verified?.info.macID, identity.macID)
    }

    /// Freshness is the client's rule (docs/remote-access-plan.md):
    /// the daemon only stamps issuedAt = now — assert it does.
    func testIssuedAtIsFresh() throws {
        let config = try RemoteConfig.load(env: [
            "LH_REMOTE_PORT": "17470",
            "LH_REMOTE_ADDRESS": "192.0.2.10",
        ], homePort: 7455)!
        let identity = try scratchIdentity()
        let t0 = Date().timeIntervalSince1970
        let info = config.macInfo(identity: identity)
        let t1 = Date().timeIntervalSince1970
        XCTAssertGreaterThanOrEqual(info.issuedAt, t0)
        XCTAssertLessThanOrEqual(info.issuedAt, t1)
    }
}
