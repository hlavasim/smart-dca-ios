import Foundation

/// Splacení FF půjčky: označ repaid + uvolni kolaterál. Žádný prodej, žádný daňový event.
final class RepayFirefishLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    func repay(externalId: String) throws {
        guard var loan = try db.firefishLoanDao.getAll().first(where: { $0.externalLoanId == externalId }) else { return }
        loan.isRepaid = true
        try db.firefishLoanDao.upsertBatch([loan])
        try CollateralService.release(db: db, loanId: externalId)
    }
}
