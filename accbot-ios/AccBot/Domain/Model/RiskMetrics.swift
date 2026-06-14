import Foundation

/// Riziko jedné FF půjčky (port z C# RiskMetricsService.LoanRisk).
struct LoanRisk: Equatable {
    let externalLoanId: String
    let ltv: Double
    let liquidationPriceCzk: Double
    let bufferPct: Double
    let liquidationFromAthPct: Double
    let level: RiskLevel
}
