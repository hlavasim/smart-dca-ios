import Foundation

enum LoanError: Error { case insufficientFreeBtc }

/// Vytvoření FF půjčky: validace volných BTC → LIFO alokace kolaterálu → uložení.
/// FF poplatek 1,5 % p.a. v BTC (btcFeeAmount) se zaznamená informativně.
final class CreateFirefishLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    @discardableResult
    func create(externalId: String, loanAmountCzk: Decimal, collateralBtc: Decimal,
                durationDays: Int, interestRate: Decimal, btcFeeRate: Decimal,
                btcPriceAtLoan: Decimal, loanDate: Date) throws -> FirefishLoan {
        let free = try CollateralService.totalFree(db: db)
        guard Double(truncating: collateralBtc as NSNumber) <= free + CollateralService.epsilon else {
            throw LoanError.insufficientFreeBtc
        }
        let maturity = Calendar(identifier: .gregorian).date(byAdding: .day, value: durationDays, to: loanDate) ?? loanDate
        let loan = FirefishLoan(externalLoanId: externalId, loanDate: loanDate, maturityDate: maturity,
            durationDays: durationDays, loanAmountCzk: loanAmountCzk, interestRate: interestRate,
            btcFeeRate: btcFeeRate, btcPriceAtLoan: btcPriceAtLoan, collateralBtcAmount: collateralBtc, isRepaid: false)
        try CollateralService.apply(db: db, amountBtc: Double(truncating: collateralBtc as NSNumber), loanId: externalId)
        try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(
            externalLoanId: externalId, loanDate: loanDate.timeIntervalSince1970,
            maturityDate: maturity.timeIntervalSince1970, durationDays: durationDays,
            loanAmountCzk: "\(loanAmountCzk)", interestRate: "\(interestRate)", btcFeeRate: "\(btcFeeRate)",
            btcPriceAtLoan: "\(btcPriceAtLoan)", collateralBtcAmount: "\(collateralBtc)", isRepaid: false)])
        // Audit transakce (best-effort; planId 0 nemusí projít FK na dca_plans).
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: loanAmountCzk, cryptoAmount: 0, price: 0, fee: 0, status: .completed,
            exchangeOrderId: "FF-\(externalId)", warningMessage: "FF fee \(loan.btcFeeAmount) BTC"))
        return loan
    }
}
