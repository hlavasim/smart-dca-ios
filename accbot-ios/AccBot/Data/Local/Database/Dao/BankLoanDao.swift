import GRDB

final class BankLoanDao {
    private let dbPool: DatabasePool
    init(dbPool: DatabasePool) { self.dbPool = dbPool }

    func getActive() throws -> [BankLoanRecord] {
        try dbPool.read { try BankLoanRecord.filter(Column("isFullyPaid") == false).fetchAll($0) }
    }
    func getAll() throws -> [BankLoanRecord] {
        try dbPool.read { try BankLoanRecord.fetchAll($0) }
    }
    func upsertBatch(_ rows: [BankLoanRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.save(db) } }
    }
    func deleteAll() throws {
        try dbPool.write { _ = try BankLoanRecord.deleteAll($0) }
    }
}
