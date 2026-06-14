import XCTest
@testable import AccBot

final class DcaExecutionIdempotencyTests: XCTestCase {
    func test_tryClaim_secondCallReturnsFalse() throws {
        let db = try DcaDatabase(path: nil)
        XCTAssertTrue(try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100))
        XCTAssertFalse(try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100))
    }

    func test_mark_updatesStatusAndOrderId() throws {
        let db = try DcaDatabase(path: nil)
        _ = try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100)
        try db.dcaExecutionDao.mark(planId: 1, dayEpoch: 100, status: .completed, orderId: "OID-9")
        let rec = try db.dcaExecutionDao.get(planId: 1, dayEpoch: 100)
        XCTAssertEqual(rec?.status, "completed")
        XCTAssertEqual(rec?.exchangeOrderId, "OID-9")
    }
}
