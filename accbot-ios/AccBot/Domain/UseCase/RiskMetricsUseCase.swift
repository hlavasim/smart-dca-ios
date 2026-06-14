import Foundation

/// Čisté výpočty rizika/scénářů (port 1:1 z C# RiskMetricsService). Bez DB/sítě → testovatelné.
enum RiskMetricsUseCase {
    static func level(ltv: Double) -> RiskLevel {
        if ltv >= RiskConstants.ffWarnHigh { return .danger }
        if ltv >= RiskConstants.ffWarnLow { return .warning }
        return .ok
    }

    static func perLoan(loan: FirefishLoan, btcPrice: Decimal, ath: Decimal) -> LoanRisk {
        let repay = NSDecimalNumber(decimal: loan.totalRepaymentCzk).doubleValue
        let coll = NSDecimalNumber(decimal: loan.collateralBtcAmount).doubleValue
        let price = NSDecimalNumber(decimal: btcPrice).doubleValue
        let athD = NSDecimalNumber(decimal: ath).doubleValue
        let ltv = coll > 0 && price > 0 ? repay / (coll * price) : 0
        let liq = coll > 0 ? repay / (coll * RiskConstants.ffLiquidationLtv) : 0
        let buffer = price > 0 ? (price - liq) / price : 0
        let liqFromAth = athD > 0 ? (liq - athD) / athD : 0
        return LoanRisk(externalLoanId: loan.externalLoanId, ltv: ltv, liquidationPriceCzk: liq,
            bufferPct: buffer, liquidationFromAthPct: liqFromAth, level: level(ltv: ltv))
    }

    /// Roky udržitelnosti (infinite roll) — port RiskMetricsService.cs:160-168.
    static func yearsAtPrice(price: Double, btc: Double, ffDebt: Double, bankDebt: Double, avgFfRate: Double) -> Double {
        let maxDebt = btc * price * RiskConstants.ffLiquidationLtv
        let headroom = maxDebt - bankDebt
        if ffDebt <= 0 || avgFfRate <= 0 { return 99 }
        if headroom <= ffDebt { return 0 }
        return log(headroom / ffDebt) / log(1 + avgFfRate)
    }

    static func effectiveLiquidationPrice(totalDebt: Double, totalBtc: Double) -> Double {
        totalBtc > 0 ? totalDebt / (totalBtc * RiskConstants.ffLiquidationLtv) : 0
    }

    static func breakEvenPrice(totalDebt: Double, totalBtc: Double, initialBtc: Double) -> Double {
        totalBtc > initialBtc ? totalDebt / (totalBtc - initialBtc) : 0
    }

    /// Vážená průměrná FF úroková sazba (pro roll model).
    static func avgFfRate(loans: [FirefishLoan]) -> Double {
        let weightedSum = loans.reduce(0.0) { acc, l in
            acc + NSDecimalNumber(decimal: l.interestRate * l.totalRepaymentCzk).doubleValue
        }
        let totalRepay = loans.reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.totalRepaymentCzk).doubleValue }
        return totalRepay > 0 ? weightedSum / totalRepay : 0
    }
}
