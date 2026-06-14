import Foundation

/// Konstanty rizika (port z C# RiskMetricsService / ProductionConfig).
enum RiskConstants {
    static let ffLiquidationLtv: Double = 0.95   // likvidační LTV
    static let ffWarnHigh: Double = 0.86         // danger práh
    static let ffWarnLow: Double = 0.73          // warning práh
    static let ffOriginationLtv: Double = 0.50   // max nová půjčka (50 % hodnoty kolaterálu)
    static let taxFreeYears = 3                   // CZ 3letý test
    static let ltvWarningThreshold: Double = 0.80 // práh pro top-up
    static let ltvTopUpPercentage: Double = 0.20  // dorovnat o 20 % kolaterálu
    static let maturityAdvanceNoticeDays = 7      // alert na splatnost
}

enum RiskLevel: String, Sendable { case ok, warning, danger }
