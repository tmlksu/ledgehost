import XCTest
@testable import LedgehostCore

final class PointerMapTests: XCTestCase {
    private let root = (x: 0, y: 0, w: 1600, h: 1200)
    private let win  = (x: 600, y: 475, w: 400, h: 300)

    func testDesktopFractions() {
        let p = SourcePointer.map(rx: 800, ry: 600, rect: root)
        XCTAssertTrue(p.inside)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
    }

    func testDesktopEdges() {
        XCTAssertTrue(SourcePointer.map(rx: 0, ry: 0, rect: root).inside)
        XCTAssertTrue(SourcePointer.map(rx: 1599, ry: 1199, rect: root).inside)
        // The far edge is exclusive: the pointer cannot sit at w/h.
        let edge = SourcePointer.map(rx: 1600, ry: 600, rect: root)
        XCTAssertFalse(edge.inside)
    }

    func testWindowRelativeFractions() {
        let p = SourcePointer.map(rx: 800, ry: 625, rect: win)   // window center
        XCTAssertTrue(p.inside)
        XCTAssertEqual(p.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.5, accuracy: 1e-9)
        let q = SourcePointer.map(rx: 700, ry: 600, rect: win)
        XCTAssertEqual(q.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(q.y, 125.0 / 300.0, accuracy: 1e-4)
    }

    func testOutsideWindowIsInsideFalse() {
        for (rx, ry) in [(599, 600), (1000, 600), (700, 474), (700, 775), (0, 0)] {
            XCTAssertFalse(SourcePointer.map(rx: rx, ry: ry, rect: win).inside,
                           "(\(rx),\(ry)) should be outside")
        }
    }

    func testOffScreenAndMissingRectAreInsideFalse() {
        XCTAssertFalse(SourcePointer.map(rx: -1, ry: -1, rect: root).inside)
        XCTAssertFalse(SourcePointer.map(rx: 100, ry: 100, rect: nil).inside)
        XCTAssertFalse(SourcePointer.map(rx: 100, ry: 100,
                                         rect: (x: 0, y: 0, w: 0, h: 0)).inside)
    }

    func testFourDecimalRounding() {
        // 1/3 of 300 px: unrounded 0.3333…, wire carries 4 decimals.
        let p = SourcePointer.map(rx: 700, ry: 575, rect: win)
        XCTAssertEqual(p.y, 0.3333, accuracy: 1e-9)
    }
}
