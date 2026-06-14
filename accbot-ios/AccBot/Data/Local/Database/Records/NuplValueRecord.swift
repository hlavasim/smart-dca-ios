import GRDB

/// NUPL hodnota pro daný den (bitcoin-data.com). Mirror DailyPriceRecord.
struct NuplValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "nupl_values"
    var dateEpochDay: Int64   // days since epoch (UTC)
    var nupl: String          // Double jako string (přesnost, jako daily_prices.price)
    var fetchedAt: Double
}
