import Foundation

/// Bankovní půjčka: vytvoření (anuita), měsíční splátky (interest/principal split), catch-up dlužných měsíců.
final class BankLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    private var cal: Calendar { Calendar(identifier: .gregorian) }

    @discardableResult
    func create(principalCzk: Decimal, annualRate: Decimal, durationMonths: Int, loanDate: Date) throws -> String {
        let next = cal.date(byAdding: .month, value: 1, to: loanDate) ?? loanDate
        let model = BankLoan(principalCzk: principalCzk, annualInterestRate: annualRate,
            durationMonths: durationMonths, remainingPrincipalCzk: principalCzk,
            nextPaymentDate: next, isFullyPaid: false)
        let id = model.id
        try db.bankLoanDao.upsertBatch([BankLoanRecord(id: id, principalCzk: "\(principalCzk)",
            annualInterestRate: "\(annualRate)", durationMonths: durationMonths,
            remainingPrincipalCzk: "\(principalCzk)", nextPaymentDate: next.timeIntervalSince1970, isFullyPaid: false)])
        return id
    }

    func recordPayment(id: String, months: Int) throws {
        guard var rec = try db.bankLoanDao.getActive().first(where: { $0.id == id }) else { return }
        let rate = (Double(rec.annualInterestRate) ?? 0) / 12.0
        let monthly = NSDecimalNumber(decimal: BankLoan(
            principalCzk: Decimal(string: rec.principalCzk) ?? 0,
            annualInterestRate: Decimal(string: rec.annualInterestRate) ?? 0,
            durationMonths: rec.durationMonths, remainingPrincipalCzk: 0,
            nextPaymentDate: Date(), isFullyPaid: false).monthlyPaymentCzk).doubleValue
        var remaining = Double(rec.remainingPrincipalCzk) ?? 0
        var next = Date(timeIntervalSince1970: rec.nextPaymentDate)
        for _ in 0..<months {
            if remaining <= 0 { break }
            let interest = remaining * rate
            let principalPortion = monthly - interest
            if principalPortion >= remaining {
                remaining = 0
                rec.isFullyPaid = true
            } else {
                remaining -= principalPortion
                next = cal.date(byAdding: .month, value: 1, to: next) ?? next
            }
        }
        rec.remainingPrincipalCzk = "\(remaining)"
        rec.nextPaymentDate = next.timeIntervalSince1970
        try db.bankLoanDao.upsertBatch([rec])
    }

    /// Catch-up: spočti dlužné měsíce (nextPaymentDate ≤ today) a aplikuj.
    func catchUp(today: Date = Date()) throws {
        for rec in try db.bankLoanDao.getActive() {
            var due = 0
            var pd = Date(timeIntervalSince1970: rec.nextPaymentDate)
            while pd <= today {
                due += 1
                pd = cal.date(byAdding: .month, value: 1, to: pd) ?? pd
            }
            if due > 0 { try recordPayment(id: rec.id, months: due) }
        }
    }
}
