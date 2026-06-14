import XCTest
@testable import AccBot

final class NuplDaoTests: XCTestCase {
    func test_insertAndGet_byDay() throws {
        let db = try DcaDatabase(path: nil)  // :memory:
        let day = NuplDao.epochDay(Date(timeIntervalSince1970: 1_770_000_000))
        try db.nuplDao.insertBatch([(day: day, nupl: 0.137)])
        let v = try XCTUnwrap(try db.nuplDao.get(dateEpochDay: day))
        XCTAssertEqual(v, 0.137, accuracy: 0.0001)
        XCTAssertEqual(try db.nuplDao.getLatestDay(), day)
        XCTAssertEqual(try db.nuplDao.count(), 1)
    }

    func test_insertBatch_replacesOnConflict() throws {
        let db = try DcaDatabase(path: nil)
        let day = NuplDao.epochDay(Date())
        try db.nuplDao.insertBatch([(day: day, nupl: 0.2)])
        try db.nuplDao.insertBatch([(day: day, nupl: 0.3)])
        let v = try XCTUnwrap(try db.nuplDao.get(dateEpochDay: day))
        XCTAssertEqual(v, 0.3, accuracy: 0.0001)
        XCTAssertEqual(try db.nuplDao.count(), 1)
    }
}
