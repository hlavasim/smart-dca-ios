import XCTest
@testable import AccBot

final class TaxTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func d(_ y: Int, _ m: Int, _ day: Int) -> Date {
        DateComponents(calendar: cal, year: y, month: m, day: day).date!
    }

    func test_threeYearTest_exemptWhenOlder() {
        let today = d(2026, 6, 14)
        XCTAssertTrue(TaxRules.isExempt(acquisition: d(2023, 6, 13), today: today))   // >3 roky
        XCTAssertFalse(TaxRules.isExempt(acquisition: d(2023, 6, 15), today: today))  // <3 roky
    }

    func test_classification_splitsHoldings() {
        let today = d(2026, 6, 14)
        let h = [
            TaxHolding(amount: 1.0, acquisition: d(2021, 1, 1)),  // free
            TaxHolding(amount: 0.5, acquisition: d(2025, 1, 1)),  // taxable
        ]
        let c = TaxRules.classify(holdings: h, today: today)
        XCTAssertEqual(c.taxFree, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.taxable, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.nextExemption, d(2028, 1, 1))
    }

    func test_fifoProfit_andTax() {
        let lot = TaxRules.fifoGain(amount: 1.0, acquisitionPrice: 1_000_000, salePrice: 2_000_000,
            daysHeld: 100, taxRate: 0.15)
        XCTAssertEqual(lot.profit, 1_000_000, accuracy: 0.01)
        XCTAssertFalse(lot.isExempt)
        XCTAssertEqual(lot.taxAmount, 150_000, accuracy: 0.01)
    }

    func test_fifoProfit_exemptOver3y() {
        let lot = TaxRules.fifoGain(amount: 1.0, acquisitionPrice: 1_000_000, salePrice: 2_000_000,
            daysHeld: 1100, taxRate: 0.15)
        XCTAssertTrue(lot.isExempt)
        XCTAssertEqual(lot.taxAmount, 0, accuracy: 0.01)
    }
}
