import Foundation

/// Bankovní půjčka (port z C# BankLoan) — měsíčně amortizovaná anuita, nouzový nástroj proti likvidaci.
struct BankLoan: Identifiable, Equatable, Sendable {
    var id: String { "\(principalCzk)-\(nextPaymentDate.timeIntervalSince1970)" }
    let principalCzk: Decimal
    let annualInterestRate: Decimal
    let durationMonths: Int
    let remainingPrincipalCzk: Decimal
    let nextPaymentDate: Date
    let isFullyPaid: Bool

    /// Anuitní měsíční splátka: M = P · [r(1+r)^n] / [(1+r)^n − 1], r = roční/12.
    var monthlyPaymentCzk: Decimal {
        guard durationMonths > 0 else { return 0 }
        let p = NSDecimalNumber(decimal: principalCzk).doubleValue
        let r = NSDecimalNumber(decimal: annualInterestRate).doubleValue / 12.0
        if r == 0 { return Decimal(p / Double(durationMonths)) }
        let factor = pow(1 + r, Double(durationMonths))
        return Decimal(p * (r * factor) / (factor - 1))
    }
}
