import XCTest
@testable import AccBot

final class LoanDaoTests: XCTestCase {
    func test_firefish_getActiveFiltersRepaid() throws {
        let db = try DcaDatabase(path: nil)
        try db.firefishLoanDao.upsertBatch([
            FirefishLoanRecord(externalLoanId: "A", loanDate: 0, maturityDate: 0, durationDays: 365,
                loanAmountCzk: "50000", interestRate: "0.1", btcFeeRate: "0.015",
                btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: false),
            FirefishLoanRecord(externalLoanId: "B", loanDate: 0, maturityDate: 0, durationDays: 365,
                loanAmountCzk: "50000", interestRate: "0.1", btcFeeRate: "0.015",
                btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: true),
        ])
        XCTAssertEqual(try db.firefishLoanDao.getActive().map(\.externalLoanId), ["A"])
        XCTAssertEqual(try db.firefishLoanDao.getAll().count, 2)
    }

    func test_bank_getActiveFiltersPaid() throws {
        let db = try DcaDatabase(path: nil)
        try db.bankLoanDao.upsertBatch([
            BankLoanRecord(id: "x", principalCzk: "1000000", annualInterestRate: "0.07", durationMonths: 120,
                remainingPrincipalCzk: "900000", nextPaymentDate: 0, isFullyPaid: false),
            BankLoanRecord(id: "y", principalCzk: "1000000", annualInterestRate: "0.07", durationMonths: 120,
                remainingPrincipalCzk: "0", nextPaymentDate: 0, isFullyPaid: true),
        ])
        XCTAssertEqual(try db.bankLoanDao.getActive().map(\.id), ["x"])
    }
}
