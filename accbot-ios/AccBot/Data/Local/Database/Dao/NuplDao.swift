import Foundation
import GRDB

/// DAO for nupl_values table. Mirror DailyPriceDao (save = insert-or-replace dle PK).
final class NuplDao {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// epoch day (UTC) pro daný Date
    static func epochDay(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    func get(dateEpochDay: Int64) throws -> Double? {
        try dbPool.read { db in
            let record = try NuplValueRecord
                .filter(Column("dateEpochDay") == dateEpochDay)
                .fetchOne(db)
            return record.flatMap { Double($0.nupl) }
        }
    }

    func getLatestDay() throws -> Int64? {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MAX(dateEpochDay) as maxDay FROM nupl_values")
            return row?["maxDay"] as? Int64
        }
    }

    func getEarliestDay() throws -> Int64? {
        try dbPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT MIN(dateEpochDay) as minDay FROM nupl_values")
            return row?["minDay"] as? Int64
        }
    }

    func insertBatch(_ rows: [(day: Int64, nupl: Double)]) throws {
        try dbPool.write { db in
            let now = Date().timeIntervalSince1970
            for r in rows {
                let record = NuplValueRecord(dateEpochDay: r.day, nupl: "\(r.nupl)", fetchedAt: now)
                try record.save(db)
            }
        }
    }

    func count() throws -> Int {
        try dbPool.read { db in try NuplValueRecord.fetchCount(db) }
    }
}
