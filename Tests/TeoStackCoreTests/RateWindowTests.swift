import XCTest
@testable import TeoStackCore

final class RateWindowTests: XCTestCase {
    func testMovingAverageRate() {
        var r = RateWindow(window: 5)
        XCTAssertEqual(r.rate, 0)
        r.add(time: 0, value: 0)
        r.add(time: 1, value: 100)
        r.add(time: 2, value: 200)
        XCTAssertEqual(r.rate, 100, accuracy: 0.001)
        r.add(time: 10, value: 200)   // fermo: la finestra scorre e la velocità cala
        XCTAssertLessThan(r.rate, 100)
    }

    func testFormatting() {
        XCTAssertEqual(Format.duration(3661), "01:01:01")
        XCTAssertEqual(Format.duration(nil), "—")
        XCTAssertEqual(Format.bytes(1_500_000), "1.50 MB")
        XCTAssertEqual(Format.megabytesPerSecond(250_000_000), "250 MB/s")
    }
}
