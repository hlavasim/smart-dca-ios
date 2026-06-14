import GRDB

struct FirefishLoanRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "firefish_loans"
    var externalLoanId: String
    var loanDate: Double
    var maturityDate: Double
    var durationDays: Int
    var loanAmountCzk: String
    var interestRate: String
    var btcFeeRate: String
    var btcPriceAtLoan: String
    var collateralBtcAmount: String
    var isRepaid: Bool
}
