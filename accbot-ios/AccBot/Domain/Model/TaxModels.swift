import Foundation

struct TaxHolding { let amount: Double; let acquisition: Date }
struct TaxClassification { let taxFree: Double; let taxable: Double; let nextExemption: Date? }
struct FifoGain { let profit: Double; let isExempt: Bool; let taxAmount: Double }

/// Český daňový režim: 3letý test + FIFO (port z C# RiskMetricsService/FifoAllocationDb).
enum TaxRules {
    private static var cal: Calendar { Calendar(identifier: .gregorian) }

    /// Osvobozeno, když acquisition + 3 roky <= today (kalendářní).
    static func isExempt(acquisition: Date, today: Date) -> Bool {
        guard let plus3 = cal.date(byAdding: .year, value: RiskConstants.taxFreeYears, to: acquisition) else { return false }
        return plus3 <= today
    }

    static func classify(holdings: [TaxHolding], today: Date) -> TaxClassification {
        var free = 0.0, taxable = 0.0
        var earliestTaxable: Date?
        for h in holdings {
            if isExempt(acquisition: h.acquisition, today: today) {
                free += h.amount
            } else {
                taxable += h.amount
                if earliestTaxable == nil || h.acquisition < earliestTaxable! { earliestTaxable = h.acquisition }
            }
        }
        let next = earliestTaxable.flatMap { cal.date(byAdding: .year, value: RiskConstants.taxFreeYears, to: $0) }
        return TaxClassification(taxFree: free, taxable: taxable, nextExemption: next)
    }

    /// FIFO zisk + daň. Jen zisky se daní; >= 1095 dní → osvobozeno.
    static func fifoGain(amount: Double, acquisitionPrice: Double, salePrice: Double,
                         daysHeld: Int, taxRate: Double) -> FifoGain {
        let profit = amount * salePrice - amount * acquisitionPrice
        let exempt = daysHeld >= 1095
        let taxable = (!exempt && profit > 0) ? profit : 0
        return FifoGain(profit: profit, isExempt: exempt, taxAmount: taxable * taxRate)
    }
}
