import XCTest
import Foundation
import Crypto
@testable import StreamProtocol
import SillLinuxShims

// Golden tests: the upstream check vectors (Tests/checks/protocol in the
// upstream tree at v0.6.2, whose expected values were computed in Python
// by the upstream authors) plus RFC 7914 section 11 for the PBKDF2 shim.
// If any of these fail, the Linux port does not speak the same protocol.

private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ s: String) -> Data {
    Data(stride(from: 0, to: s.count, by: 2).map { i -> UInt8 in
        let a = s.index(s.startIndex, offsetBy: i)
        return UInt8(s[a..<s.index(a, offsetBy: 2)], radix: 16)!
    })
}

final class PBKDF2ShimTests: XCTestCase {
    func testRFC7914Vectors() {
        let cases: [(Int, String)] = [
            (1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
            (2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
            (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
        ]
        for (c, want) in cases {
            let dk = PBKDF2.derive(password: Array("password".utf8), salt: Data("salt".utf8),
                                   iterations: c, keyLength: 32)
            XCTAssertEqual(dk.map(hex), want, "c=\(c)")
        }
    }
}

final class PairingVectorTests: XCTestCase {
    private var fpMac: Data { Data(SHA256.hash(data: Data("mac".utf8))) }
    private var fpDev: Data { Data(SHA256.hash(data: Data("device".utf8))) }

    func testFingerprints() {
        XCTAssertEqual(hex(fpMac), "348a629f5ceed032c3e8706ec47d9bfafb00fb4250b018dd965435ca50cb836e")
        XCTAssertEqual(hex(fpDev), "263a4dbe41488fb87214b0032339dbb9f0c8da14c16dfcf13084bf3c2552eca5")
    }

    // Slow: the real 600,000-round derivation.
    func testCodeKeyAndProofs() {
        let k = PairingProof.codeKey(code: "482913557208", macFingerprint: fpMac)
        XCTAssertNotNil(k)
        guard let k else { return }
        XCTAssertEqual(k.withUnsafeBytes { hex(Data($0)) },
                       "e9baf879a1cc4ac8b21554df480b6c1621671319107c91e7cb05d154f649d31d")
        let codeD = PairingProof.deviceProof(key: k, deviceFingerprint: fpDev, macFingerprint: fpMac)
        let codeM = PairingProof.macProof(key: k, macFingerprint: fpMac, deviceFingerprint: fpDev)
        XCTAssertEqual(Base64URL.encode(codeD), "dk7PZj4vHsAxj--1u9Vg7ehSn8a1tWc0RCG46YpFVO8")
        XCTAssertEqual(Base64URL.encode(codeM), "6BmGWC9XT8J8OY8phhq9bASgoSnoWpRxBeqZtvRrWmk")
        XCTAssertTrue(PairingProof.isValidMacProof(codeM, key: k, macFingerprint: fpMac, deviceFingerprint: fpDev))
        let wrong = PairingProof.codeKey(code: "482913557217", macFingerprint: fpMac)!
        XCTAssertFalse(PairingProof.isValidMacProof(codeM, key: wrong, macFingerprint: fpMac, deviceFingerprint: fpDev))
        XCTAssertNil(PairingProof.codeKey(code: "48291355720", macFingerprint: fpMac))
    }

    func testQRProofs() {
        let qr = PairingProof.qrKey(secret: Data(repeating: 0x22, count: 16))
        let qrD = PairingProof.deviceProof(key: qr, deviceFingerprint: fpDev, macFingerprint: fpMac)
        let qrM = PairingProof.macProof(key: qr, macFingerprint: fpMac, deviceFingerprint: fpDev)
        XCTAssertEqual(Base64URL.encode(qrD), "AyZAJqNTU5nSKEaHx6RZOf0K5dOeygR_8JSrCV_gNOo")
        XCTAssertEqual(Base64URL.encode(qrM), "XAX-uZPsq_Ax8fvI_sV7Ex0a-ROi19rI-FW-ykPh9TE")
        XCTAssertTrue(PairingProof.isValidDeviceProof(qrD, key: qr, deviceFingerprint: fpDev, macFingerprint: fpMac))
        var flipped = qrD; flipped[5] ^= 0x01
        XCTAssertFalse(PairingProof.isValidDeviceProof(flipped, key: qr, deviceFingerprint: fpDev, macFingerprint: fpMac))
        XCTAssertFalse(PairingProof.isValidDeviceProof(qrM, key: qr, deviceFingerprint: fpDev, macFingerprint: fpMac))
    }

    func testPairingCode() {
        XCTAssertEqual(PairingCode.checkDigit([4, 8, 2, 9, 1, 3, 5, 5, 7, 2, 0]), 8)
        XCTAssertEqual(PairingCode.check("4829 1355 7208"), .success("482913557208"))
        XCTAssertEqual(PairingCode.check("4829-1355-7208"), .success("482913557208"))
        XCTAssertEqual(PairingCode.check("4829 1355 720"), .failure(.length))
        XCTAssertEqual(PairingCode.check("4829 1355 7209"), .failure(.typo))
        XCTAssertEqual(PairingCode.check("4829 1355 7280"), .failure(.typo))
        XCTAssertEqual(PairingCode.grouped("482913557208"), "4829 1355 7208")
        for _ in 0..<50 {
            let c = PairingCode.generate()
            XCTAssertNotNil(c)
            if let c { XCTAssertEqual(PairingCode.check(c), .success(c)) }
        }
    }

    func testRecognitionTag() {
        let rk = Data(repeating: 0x11, count: 32)
        let tag = RecognitionTag.make(recognitionKey: rk, nonce: unhex("a1a2a3a4a5a6"))
        XCTAssertEqual(tag, "oaKjpKWmL4V47Ctm")
        XCTAssertTrue(RecognitionTag.matches("oaKjpKWmL4V47Ctm", recognitionKey: rk))
        XCTAssertFalse(RecognitionTag.matches("oaKjpKWmL4V47Ct", recognitionKey: rk))
        XCTAssertFalse(RecognitionTag.matches("", recognitionKey: rk))
        let fresh = RecognitionTag.make(recognitionKey: rk)
        XCTAssertNotNil(fresh)
        if let fresh { XCTAssertTrue(RecognitionTag.matches(fresh, recognitionKey: rk)) }
    }
}

final class IdentityVectorTests: XCTestCase {
    func testMacID() {
        XCTAssertEqual(MacID.make(fingerprint: unhex("50d858e0985ecc7f6041") + Data(count: 22)), "A3C5HR4RBV67YR21")
        XCTAssertEqual(MacID.make(fingerprint: Data(SHA256.hash(data: Data("example".utf8)))), "A3C5HR4RBV67YR21")
        XCTAssertEqual(MacID.make(fingerprint: Data(count: 32)), "0000000000000000")
        XCTAssertEqual(MacID.make(fingerprint: Data(repeating: 0xFF, count: 32)), "ZZZZZZZZZZZZZZZZ")
        XCTAssertTrue(MacID.isWellFormed("A3C5HR4RBV67YR21"))
        XCTAssertFalse(MacID.isWellFormed("A3C5HR4RBV67YR2I"))
        XCTAssertFalse(MacID.isWellFormed("a3c5hr4rbv67yr21"))
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Data(count: 32)).count, 43)
        XCTAssertEqual(Base64URL.encode(Data(count: 16)).count, 22)
        for n in 1...40 {
            var b = [UInt8](repeating: 0, count: n)
            XCTAssertTrue(SillLinuxShims.Random.fill(&b))
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(Data(b))), Data(b))
        }
        XCTAssertNil(Base64URL.decode("AAAA="))
        XCTAssertNil(Base64URL.decode("ab+c"))
        XCTAssertNil(Base64URL.decode("ab/c"))
        XCTAssertNil(Base64URL.decode("abcde"))
        XCTAssertNil(Base64URL.decode("AB"))
    }

    func testSPKIAndKeyRoundTrip() {
        let key = RemoteKey.generate()
        let point = RemoteKey.publicPoint(key)
        XCTAssertEqual(point.count, 65)
        XCTAssertEqual(SPKI.der(point: point).count, 91)
        XCTAssertEqual(SPKI.fingerprint(of: key), SPKI.fingerprint(point: point))
        let exported = RemoteKey.export(key)
        XCTAssertEqual(exported.count, 97)
        let back = RemoteKey.importPrivate(exported)
        XCTAssertNotNil(back)
        XCTAssertEqual(back.map { SPKI.fingerprint(of: $0) }, SPKI.fingerprint(of: key))
    }

    func testSelfSignedCertificate() {
        let key = RemoteKey.generate()
        let der = SelfSignedCertificate.make(key: key)
        XCTAssertNotNil(der)
        guard let der else { return }
        XCTAssertEqual(der.first, 0x30)
        // The certificate embeds the key's SPKI, so the pin survives.
        let spki = SPKI.der(point: RemoteKey.publicPoint(key))
        XCTAssertTrue(der.range(of: spki) != nil)
        let der2 = SelfSignedCertificate.make(key: key)
        XCTAssertNotNil(der2)
        XCTAssertNotEqual(der, der2)   // fresh serial and CN each time
    }

    func testSignedMacInfoRoundTrip() {
        let key = RemoteKey.generate()
        let fp = SPKI.fingerprint(of: key)
        let info = MacInfo(v: 1, macID: MacID.make(fingerprint: fp), name: "linux-host",
                           issuedAt: 1_700_000_000, remoteAccess: true, remotePort: 7455,
                           internet: false, addresses: [])
        let signed = SignedMacInfo.signing(info, with: key)
        XCTAssertNotNil(signed)
        let verified = signed?.verified()
        XCTAssertEqual(verified?.info, info)
        XCTAssertEqual(verified?.fingerprint, fp)
    }
}
