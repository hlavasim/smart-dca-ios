import GRDB

final class FirefishLoanDao {
    private let dbPool: DatabasePool
    init(dbPool: DatabasePool) { self.dbPool = dbPool }

    func getActive() throws -> [FirefishLoanRecord] {
        try dbPool.read { try FirefishLoanRecord.filter(Column("isRepaid") == false).fetchAll($0) }
    }
    func getAll() throws -> [FirefishLoanRecord] {
        try dbPool.read { try FirefishLoanRecord.fetchAll($0) }
    }
    func upsertBatch(_ rows: [FirefishLoanRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.save(db) } }
    }
    func deleteAll() throws {
        try dbPool.write { _ = try FirefishLoanRecord.deleteAll($0) }
    }
}
