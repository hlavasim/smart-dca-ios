import Foundation

/// Plný snapshot stavu appky pro git zálohu/obnovu (= migrace z C#).
/// Nested typy mají suffix `Snap`, aby nekolidovaly s doménovými FirefishLoan/BankLoan/Transaction.
struct AppSnapshot: Codable, Equatable {
    var version: Int
    var exportedAt: String
    var fiat: String
    var strategy: StrategySnap
    var holdings: [HoldingSnap]
    var transactions: [TxSnap]
    var firefishLoans: [FirefishLoanSnap]
    var bankLoans: [BankLoanSnap]

    struct StrategySnap: Codable, Equatable {
        var type: String
        var nuplBottomValue: Double
        var nuplCenterValue: Double
        var nuplMinMultiplier: Double
        var nuplMaxMultiplier: Double
        var baseChunkCzk: String
        var baseChunkMultiplier: String
        var lastProcessedDate: String   // yyyy-MM-dd
        var availableCashCzk: String
    }
    struct HoldingSnap: Codable, Equatable {
        var id: String
        var amount: String
        var acquisitionDate: String     // yyyy-MM-dd
        var purchasePriceCzk: String
        var isCollateralized: Bool
        var loanId: String?
        var source: String
        var notes: String
    }
    struct TxSnap: Codable, Equatable {
        var date: String                // yyyy-MM-dd
        var type: String
        var amountBtc: String
        var amountCzk: String
        var btcPriceCzk: String
        var exchangeOrderId: String?
    }
    struct FirefishLoanSnap: Codable, Equatable {
        var externalLoanId: String
        var loanDate: String
        var maturityDate: String
        var loanAmountCzk: String
        var interestRate: String
        var btcFeeRate: String
        var btcPriceAtLoan: String
        var collateralBtcAmount: String
        var isRepaid: Bool
    }
    struct BankLoanSnap: Codable, Equatable {
        var principalCzk: String
        var annualInterestRate: String
        var durationMonths: Int
        var remainingPrincipalCzk: String
        var nextPaymentDate: String
        var isFullyPaid: Bool
    }
}
