import XCTest
@testable import AccBot

final class HoldingDaoTests: XCTestCase {
    func test_upsert_replacesById() throws {
        let db = try DcaDatabase(path: nil)
        let r = HoldingRecord(id: "h1", amount: "0.5", acquisitionDate: 1_600_000_000,
            purchasePriceCzk: "0", isCollateralized: false, loanId: nil,
            isAvailableForDca: true, source: "Initial", notes: "", createdAt: 0)
        try db.holdingDao.upsert(r)
        try db.holdingDao.upsert({ var x = r; x.amount = "0.7"; return x }())
        XCTAssertEqual(try db.holdingDao.getAll().count, 1)
        XCTAssertEqual(try db.holdingDao.totalAmount(), Decimal(string: "0.7")!)
    }
}
