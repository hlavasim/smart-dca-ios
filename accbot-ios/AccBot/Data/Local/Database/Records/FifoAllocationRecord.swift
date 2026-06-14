import GRDB

/// FIFO daňová alokace prodeje BTC (port z C# FifoAllocationDb).
struct FifoAllocationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "fifo_allocations"
    var id: String
    var saleDate: Double
    var sourceHoldingId: String
    var allocatedBtc: String
    var acquisitionPriceCzk: String
    var salePriceCzk: String
    var profitCzk: String
    var daysHeld: Int
    var isExempt: Bool
    var taxAmountCzk: String
}
