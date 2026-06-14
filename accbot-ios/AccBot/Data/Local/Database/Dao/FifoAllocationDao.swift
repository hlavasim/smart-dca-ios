import GRDB

final class FifoAllocationDao {
    private let dbPool: DatabasePool
    init(dbPool: DatabasePool) { self.dbPool = dbPool }

    func getAll() throws -> [FifoAllocationRecord] {
        try dbPool.read { try FifoAllocationRecord.fetchAll($0) }
    }
    func upsertBatch(_ rows: [FifoAllocationRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.save(db) } }
    }
    func deleteAll() throws {
        try dbPool.write { _ = try FifoAllocationRecord.deleteAll($0) }
    }
}
