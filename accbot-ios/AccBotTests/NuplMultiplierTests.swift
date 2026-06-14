import XCTest
@testable import AccBot

final class NuplMultiplierTests: XCTestCase {
    let cfg = NuplConfig.default  // bottom 0.0, center 0.5, min 0.5, max 3.0

    func test_atBottom_returnsMax() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.0, config: cfg), 3.0, accuracy: 0.0001)
    }
    func test_belowBottom_clampsToMax() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: -0.1, config: cfg), 3.0, accuracy: 0.0001)
    }
    func test_quarter_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.25, config: cfg), 1.75, accuracy: 0.0001)
    }
    func test_tenth_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.10, config: cfg), 2.5, accuracy: 0.0001)
    }
    func test_fourtenths_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.40, config: cfg), 1.0, accuracy: 0.0001)
    }
    func test_atCenter_returnsMin() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.5, config: cfg), 0.5, accuracy: 0.0001)
    }
    func test_aboveCenter_clampsToMin() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.6, config: cfg), 0.5, accuracy: 0.0001)
    }
    func test_nilNupl_returnsFlat() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: nil, config: cfg), 1.0, accuracy: 0.0001)
    }
}
