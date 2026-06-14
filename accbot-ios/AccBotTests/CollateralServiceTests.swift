import XCTest
@testable import AccBot

final class CollateralServiceTests: XCTestCase {
    private func h(_ id: String, _ amt: Double, _ acq: Double) -> HoldingRecord {
        HoldingRecord(id: id, amount: "\(amt)", acquisitionDate: acq, purchasePriceCzk: "0",
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0)
    }

    func test_lifo_markWholeAndSplit() {
        // A 0.5 (nejnovější), B 1.0, C 0.3; potřeba 1.2 → A celé, B split 0.7/0.3
        let free = [h("A", 0.5, 300), h("B", 1.0, 200), h("C", 0.3, 100)]
        let plan = CollateralService.planAllocation(free: free, amountBtc: 1.2, loanId: "L1")
        XCTAssertEqual(plan.markWhole, ["A"])
        XCTAssertEqual(plan.splits.count, 1)
        XCTAssertEqual(plan.splits[0].sourceHoldingId, "B")
        XCTAssertEqual(Double(plan.splits[0].collateralAmount)!, 0.7, accuracy: 1e-9)
        XCTAssertEqual(Double(plan.splits[0].remainingFree)!, 0.3, accuracy: 1e-9)
    }

    func test_apply_marksAndSplits() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsertBatch([h("A", 0.5, 300), h("B", 1.0, 200)])
        try CollateralService.apply(db: db, amountBtc: 1.2, loanId: "L1")
        XCTAssertEqual(try db.holdingDao.getByLoanId("L1").count, 2)
        let bFree = try db.holdingDao.getAll().first { $0.id == "B" }!
        XCTAssertEqual(Double(bFree.amount)!, 0.3, accuracy: 1e-9)
        XCTAssertFalse(bFree.isCollateralized)
    }

    func test_release_freesCollateral() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsert(HoldingRecord(id: "A", amount: "0.5", acquisitionDate: 300,
            purchasePriceCzk: "0", isCollateralized: true, loanId: "L1", isAvailableForDca: false,
            source: "X", notes: "", createdAt: 0))
        try CollateralService.release(db: db, loanId: "L1")
        let a = try db.holdingDao.getAll().first!
        XCTAssertFalse(a.isCollateralized)
        XCTAssertNil(a.loanId)
    }
}
