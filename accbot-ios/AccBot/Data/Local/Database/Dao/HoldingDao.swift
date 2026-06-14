import Foundation
import GRDB

/// DAO pro holdings. save = insert-or-replace dle PK (id).
final class HoldingDao {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    func getAll() throws -> [HoldingRecord] {
        try dbPool.read { try HoldingRecord.fetchAll($0) }
    }

    func upsert(_ r: HoldingRecord) throws {
        try dbPool.write { try r.save($0) }
    }

    func upsertBatch(_ rows: [HoldingRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.save(db) } }
    }

    func deleteAll() throws {
        try dbPool.write { _ = try HoldingRecord.deleteAll($0) }
    }

    func totalAmount() throws -> Decimal {
        try getAll().reduce(Decimal(0)) { $0 + (Decimal(string: $1.amount) ?? 0) }
    }
}
