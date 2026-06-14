import XCTest
@testable import AccBot

final class MaturityAlertTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)

    func test_alertWithin7Days() {
        let today = Date()
        let due = cal.date(byAdding: .day, value: 5, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: due, today: today), .upcoming(daysLeft: 5))
    }

    func test_criticalWhenOverdue() {
        let today = Date()
        let past = cal.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: past, today: today), .overdue)
    }

    func test_noneWhenFar() {
        let today = Date()
        let far = cal.date(byAdding: .day, value: 30, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: far, today: today), .none)
    }

    func test_needsTopUp_atThreshold() {
        // repay 80000, collateral 0.1, price 1_000_000 → LTV 0.8 → true
        let loan = FirefishLoan(externalLoanId: "L", loanDate: Date(), maturityDate: Date(),
            durationDays: 365, loanAmountCzk: 80000, interestRate: 0, btcFeeRate: 0,
            btcPriceAtLoan: 1_000_000, collateralBtcAmount: 0.1, isRepaid: false)
        XCTAssertTrue(MaturityAlertService.needsTopUp(loan: loan, btcPrice: 1_000_000))
    }
}
