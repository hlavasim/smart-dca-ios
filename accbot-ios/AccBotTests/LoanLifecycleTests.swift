import XCTest
@testable import AccBot

final class LoanLifecycleTests: XCTestCase {
    private func freeHolding(_ id: String, _ amt: String) -> HoldingRecord {
        HoldingRecord(id: id, amount: amt, acquisitionDate: 300, purchasePriceCzk: "0",
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0)
    }

    func test_createFF_allocatesAndComputesFee() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsert(freeHolding("A", "0.2"))
        let loan = try CreateFirefishLoanUseCase(db: db).create(
            externalId: "FF1", loanAmountCzk: 50000, collateralBtc: 0.1,
            durationDays: 365, interestRate: 0.10, btcFeeRate: 0.015, btcPriceAtLoan: 1_000_000,
            loanDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(NSDecimalNumber(decimal: loan.totalRepaymentCzk).doubleValue, 55000, accuracy: 0.01)
        XCTAssertEqual(NSDecimalNumber(decimal: loan.btcFeeAmount).doubleValue, 0.00075, accuracy: 1e-8)
        XCTAssertEqual(try db.firefishLoanDao.getActive().count, 1)
        XCTAssertEqual(try db.holdingDao.getByLoanId("FF1").count, 1)
    }

    func test_createFF_insufficientFree_throws() throws {
        let db = try DcaDatabase(path: nil)
        XCTAssertThrowsError(try CreateFirefishLoanUseCase(db: db).create(
            externalId: "FF1", loanAmountCzk: 50000, collateralBtc: 0.1,
            durationDays: 365, interestRate: 0.10, btcFeeRate: 0.015, btcPriceAtLoan: 1_000_000, loanDate: Date()))
    }

    func test_topUp_addsCollateralLifo() throws {
        let db = try DcaDatabase(path: nil)
        try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(externalLoanId: "FF1", loanDate: 0,
            maturityDate: 0, durationDays: 365, loanAmountCzk: "50000", interestRate: "0.1",
            btcFeeRate: "0.015", btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: false)])
        try db.holdingDao.upsert(freeHolding("F", "0.1"))
        try TopUpCollateralUseCase(db: db).topUp(externalId: "FF1", addBtc: 0.05)
        let added = try db.holdingDao.getByLoanId("FF1").reduce(0.0) { $0 + (Double($1.amount) ?? 0) }
        XCTAssertEqual(added, 0.05, accuracy: 1e-9)
        let loan = try db.firefishLoanDao.getActive().first!
        XCTAssertEqual(Double(loan.collateralBtcAmount)!, 0.15, accuracy: 1e-9)
    }

    func test_repay_marksRepaidAndReleasesCollateral() throws {
        let db = try DcaDatabase(path: nil)
        try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(externalLoanId: "FF1", loanDate: 0,
            maturityDate: 0, durationDays: 365, loanAmountCzk: "50000", interestRate: "0.1",
            btcFeeRate: "0.015", btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: false)])
        try db.holdingDao.upsert(HoldingRecord(id: "A", amount: "0.1", acquisitionDate: 300,
            purchasePriceCzk: "0", isCollateralized: true, loanId: "FF1", isAvailableForDca: false,
            source: "X", notes: "", createdAt: 0))
        try RepayFirefishLoanUseCase(db: db).repay(externalId: "FF1")
        XCTAssertTrue(try db.firefishLoanDao.getAll().first!.isRepaid)
        XCTAssertEqual(try db.firefishLoanDao.getActive().count, 0)
        let a = try db.holdingDao.getAll().first!
        XCTAssertFalse(a.isCollateralized)
        XCTAssertNil(a.loanId)
    }
}
