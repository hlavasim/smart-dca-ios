import XCTest
@testable import AccBot

final class FirefishLoanCalcTests: XCTestCase {
    private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    func test_interestAndRepayment() {
        let l = FirefishLoan(externalLoanId: "FF1", loanDate: Date(), maturityDate: Date(),
            durationDays: 365, loanAmountCzk: 50000, interestRate: 0.10, btcFeeRate: 0.015,
            btcPriceAtLoan: 1_000_000, collateralBtcAmount: 0.08, isRepaid: false)
        XCTAssertEqual(dbl(l.interestCzk), 5000, accuracy: 0.01)
        XCTAssertEqual(dbl(l.totalRepaymentCzk), 55000, accuracy: 0.01)
        XCTAssertEqual(dbl(l.btcFeeAmount), 0.0012, accuracy: 1e-8)  // 0.08 · 0.015 · 1
    }
}

final class BankLoanCalcTests: XCTestCase {
    private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    func test_annuity() {
        let b = BankLoan(principalCzk: 1_000_000, annualInterestRate: 0.07, durationMonths: 120,
            remainingPrincipalCzk: 1_000_000, nextPaymentDate: Date(), isFullyPaid: false)
        XCTAssertEqual(dbl(b.monthlyPaymentCzk), 11610.85, accuracy: 1.0)
    }
    func test_zeroInterest() {
        let b = BankLoan(principalCzk: 120_000, annualInterestRate: 0, durationMonths: 120,
            remainingPrincipalCzk: 120_000, nextPaymentDate: Date(), isFullyPaid: false)
        XCTAssertEqual(dbl(b.monthlyPaymentCzk), 1000, accuracy: 0.01)
    }
}
