import Foundation

enum MaturityAlert: Equatable {
    case none
    case upcoming(daysLeft: Int)
    case overdue
}

/// Vyhodnocení splatnosti FF půjček (port z C# ProductionEngine maturita).
enum MaturityAlertService {
    /// Čistá funkce: alert pro daný termín splatnosti.
    static func evaluate(maturity: Date, today: Date,
                         advanceDays: Int = RiskConstants.maturityAdvanceNoticeDays) -> MaturityAlert {
        let days = Calendar(identifier: .gregorian).dateComponents([.day], from: today, to: maturity).day ?? 0
        if days < 0 { return .overdue }
        if days <= advanceDays { return .upcoming(daysLeft: days) }
        return .none
    }

    /// LTV monitoring: vrátí true, když půjčka překročila varovný práh (0.80).
    static func needsTopUp(loan: FirefishLoan, btcPrice: Decimal) -> Bool {
        let repay = NSDecimalNumber(decimal: loan.totalRepaymentCzk).doubleValue
        let coll = NSDecimalNumber(decimal: loan.collateralBtcAmount).doubleValue
        let price = NSDecimalNumber(decimal: btcPrice).doubleValue
        guard coll > 0, price > 0 else { return false }
        return repay / (coll * price) >= RiskConstants.ltvWarningThreshold
    }
}
