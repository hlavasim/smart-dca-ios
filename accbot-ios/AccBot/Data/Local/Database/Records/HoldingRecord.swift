import GRDB

/// BTC holding s akvizičním datem (port z C# BtcHoldingDb) — nutné pro daně + kolaterál.
struct HoldingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "holdings"
    var id: String                 // UUID z C# (zachová identitu)
    var amount: String             // Decimal jako string
    var acquisitionDate: Double    // timeIntervalSince1970
    var purchasePriceCzk: String
    var isCollateralized: Bool
    var loanId: String?            // FF loan externalId (Phase 2)
    var isAvailableForDca: Bool
    var source: String             // "Initial" | "DCA" | "CoinMate-Deposit"
    var notes: String
    var createdAt: Double
}
