import Foundation
import GRDB

/// DAO pro dca_executions — idempotency zámek DCA nákupů.
final class DcaExecutionDao {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    enum Status: String { case pending, completed, failed }

    func get(planId: Int64, dayEpoch: Int64) throws -> DcaExecutionRecord? {
        try dbPool.read { db in
            try DcaExecutionRecord
                .filter(Column("planId") == planId && Column("dayEpoch") == dayEpoch)
                .fetchOne(db)
        }
    }

    /// Vloží pending zámek. Vrací false, pokud už záznam existuje (= nekupovat znovu).
    func tryClaim(planId: Int64, dayEpoch: Int64) throws -> Bool {
        try dbPool.write { db in
            let exists = try DcaExecutionRecord
                .filter(Column("planId") == planId && Column("dayEpoch") == dayEpoch)
                .fetchCount(db) > 0
            if exists { return false }
            let now = Date().timeIntervalSince1970
            try DcaExecutionRecord(
                planId: planId, dayEpoch: dayEpoch,
                status: Status.pending.rawValue, exchangeOrderId: nil,
                createdAt: now, updatedAt: now
            ).insert(db)
            return true
        }
    }

    func mark(planId: Int64, dayEpoch: Int64, status: Status, orderId: String?) throws {
        try dbPool.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE dca_executions SET status = ?, exchangeOrderId = ?, updatedAt = ?
                WHERE planId = ? AND dayEpoch = ?
                """, arguments: [status.rawValue, orderId, now, planId, dayEpoch])
        }
    }
}
