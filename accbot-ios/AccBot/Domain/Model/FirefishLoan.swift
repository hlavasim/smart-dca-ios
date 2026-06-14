import Foundation

/// Firefish pákový úvěr (port z C# FirefishLoan). Poplatek se platí v BTC (btcFeeRate p.a.).
struct FirefishLoan: Identifiable, Equatable, Sendable {
    var id: String { externalLoanId }
    let externalLoanId: String
    let loanDate: Date
    let maturityDate: Date
    let durationDays: Int
    let loanAmountCzk: Decimal
    let interestRate: Decimal      // p.a. (0.10 = 10 %)
    let btcFeeRate: Decimal        // p.a. v BTC (0.015 = 1,5 %)
    let btcPriceAtLoan: Decimal
    let collateralBtcAmount: Decimal
    let isRepaid: Bool

    var yearFraction: Decimal { Decimal(durationDays) / 365 }
    var interestCzk: Decimal { loanAmountCzk * interestRate * yearFraction }
    var totalRepaymentCzk: Decimal { loanAmountCzk + interestCzk }
    /// FF poplatek v BTC = btcFeeRate p.a. z kolaterálu, prorataně dobou. Nezávisí na ceně BTC.
    var btcFeeAmount: Decimal {
        collateralBtcAmount * btcFeeRate * yearFraction
    }
}
