import Foundation

/// Top-up kolaterálu FF půjčky (LIFO). Auto množství při LTV≥0.80 = 20 % aktuálního kolaterálu.
final class TopUpCollateralUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    static func autoAmount(collateralBtc: Double) -> Double { collateralBtc * RiskConstants.ltvTopUpPercentage }

    func topUp(externalId: String, addBtc: Double) throws {
        guard addBtc <= (try CollateralService.totalFree(db: db)) + CollateralService.epsilon else {
            throw LoanError.insufficientFreeBtc
        }
        try CollateralService.apply(db: db, amountBtc: addBtc, loanId: externalId)
        guard var loan = try db.firefishLoanDao.getActive().first(where: { $0.externalLoanId == externalId }) else { return }
        let newColl = (Double(loan.collateralBtcAmount) ?? 0) + addBtc
        loan.collateralBtcAmount = "\(newColl)"
        try db.firefishLoanDao.upsertBatch([loan])
    }
}
