import GRDB

struct BankLoanRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bank_loans"
    var id: String
    var principalCzk: String
    var annualInterestRate: String
    var durationMonths: Int
    var remainingPrincipalCzk: String
    var nextPaymentDate: Double
    var isFullyPaid: Bool
}
