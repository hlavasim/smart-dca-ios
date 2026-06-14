import GRDB

/// Idempotency zámek: jeden záznam na (planId, dayEpoch). Zapsán PŘED nákupem,
/// aby re-run/retry nikdy nenakoupil dvakrát.
struct DcaExecutionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dca_executions"
    var planId: Int64
    var dayEpoch: Int64
    var status: String          // "pending" | "completed" | "failed"
    var exchangeOrderId: String?
    var createdAt: Double
    var updatedAt: Double
}
