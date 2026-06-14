import XCTest
@testable import AccBot

final class SnapshotServiceTests: XCTestCase {
    func test_buildThenLoad_preservesHoldings() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsert(HoldingRecord(
            id: "h1", amount: "0.5", acquisitionDate: 1_600_000_000,
            purchasePriceCzk: "0", isCollateralized: false, loanId: nil,
            isAvailableForDca: true, source: "Initial", notes: "", createdAt: 0))
        let svc = SnapshotService()
        let snap = try svc.build(from: db, fiat: "CZK")
        let db2 = try DcaDatabase(path: nil)
        try svc.load(snap, into: db2)
        XCTAssertEqual(try db2.holdingDao.getAll().map(\.id), ["h1"])
    }

    func test_buildThenLoad_preservesLoans() throws {
        let db = try DcaDatabase(path: nil)
        try db.firefishLoanDao.upsertBatch([
            FirefishLoanRecord(externalLoanId: "FF1", loanDate: 1_700_000_000, maturityDate: 1_731_536_000,
                durationDays: 365, loanAmountCzk: "50000", interestRate: "0.1", btcFeeRate: "0.015",
                btcPriceAtLoan: "1200000", collateralBtcAmount: "0.08", isRepaid: false)])
        try db.bankLoanDao.upsertBatch([
            BankLoanRecord(id: "b0", principalCzk: "763300", annualInterestRate: "0.07", durationMonths: 120,
                remainingPrincipalCzk: "750000", nextPaymentDate: 1_751_328_000, isFullyPaid: false)])
        let svc = SnapshotService()
        let snap = try svc.build(from: db, fiat: "CZK")
        let db2 = try DcaDatabase(path: nil)
        try svc.load(snap, into: db2)
        XCTAssertEqual(try db2.firefishLoanDao.getAll().map(\.externalLoanId), ["FF1"])
        XCTAssertEqual(try db2.bankLoanDao.getAll().count, 1)
    }
}
