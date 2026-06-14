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
}
