import XCTest
@testable import LedgehostCore

// Admin request validation + revoke prefix matching
// (docs/admin.md).

final class AdminProtocolTests: XCTestCase {
    private func body(_ json: String) -> Data { Data(json.utf8) }

    func testValidCommands() {
        for (json, expected) in [
            ("{\"command\":\"status\"}", AdminProtocol.Command.status),
            ("{\"command\":\"code\"}", .code),
            ("{\"command\":\"code\",\"new\":true}", .code),
            ("{\"command\":\"devices\"}", .devices),
            ("{\"command\":\"revoke\",\"prefix\":\"abcdef12\"}", .revoke),
        ] as [(String, AdminProtocol.Command)] {
            guard case .success((let command, _)) = AdminProtocol.validate(body(json)) else {
                return XCTFail("\(json) should validate")
            }
            XCTAssertEqual(command, expected, json)
        }
    }

    func testRevokeCarriesPrefix() {
        guard case .success((_, let request)) =
                AdminProtocol.validate(body("{\"command\":\"revoke\",\"prefix\":\"ab12\"}")) else {
            return XCTFail("revoke with prefix should validate")
        }
        XCTAssertEqual(request.prefix, "ab12")
    }

    private func expectFailure(_ json: String, _ expected: AdminProtocol.ValidationError,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let why) = AdminProtocol.validate(body(json)) else {
            return XCTFail("\(json) should be refused", file: file, line: line)
        }
        XCTAssertEqual(why, expected, json, file: file, line: line)
    }

    func testInvalidRequests() {
        expectFailure("not json", .undecodable)
        expectFailure("{\"command\":\"explode\"}", .unknownCommand("explode"))
        // revoke without a usable prefix is refused at parse time
        expectFailure("{\"command\":\"revoke\"}", .missingPrefix)
        expectFailure("{\"command\":\"revoke\",\"prefix\":\"\"}", .missingPrefix)
    }

    func testPrefixMatching() {
        let fps = ["AbCdEf123456", "AbCdEf999999", "zzzzzzzzzzzz"]
        // Unique prefix resolves
        var r = AdminProtocol.matchPrefix("AbCdEf12", among: fps)
        XCTAssertEqual(r.match, "AbCdEf123456")
        XCTAssertEqual(r.candidates, 1)
        // The full fingerprint also resolves
        r = AdminProtocol.matchPrefix("zzzzzzzzzzzz", among: fps)
        XCTAssertEqual(r.match, "zzzzzzzzzzzz")
        // Ambiguous prefix: no match, candidate count reported
        r = AdminProtocol.matchPrefix("AbCdEf", among: fps)
        XCTAssertNil(r.match)
        XCTAssertEqual(r.candidates, 2)
        // Unknown prefix
        r = AdminProtocol.matchPrefix("nope", among: fps)
        XCTAssertNil(r.match)
        XCTAssertEqual(r.candidates, 0)
        // Case-sensitive (base64url is)
        r = AdminProtocol.matchPrefix("abcdef12", among: fps)
        XCTAssertEqual(r.candidates, 0)
    }

    func testReplyShapes() throws {
        let okObj = try JSONSerialization.jsonObject(with: AdminProtocol.ok(["a": 1])) as? [String: Any]
        XCTAssertEqual(okObj?["ok"] as? Bool, true)
        XCTAssertEqual(okObj?["a"] as? Int, 1)
        let errObj = try JSONSerialization.jsonObject(with: AdminProtocol.err("bad")) as? [String: Any]
        XCTAssertEqual(errObj?["ok"] as? Bool, false)
        XCTAssertEqual(errObj?["error"] as? String, "bad")
    }
}
