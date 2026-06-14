import XCTest
@testable import AccBot

final class RiskMetricsTests: XCTestCase {
    private func makeLoan(_ repay: Decimal, _ collateral: Decimal) -> FirefishLoan {
        // loanAmountCzk = repay, 0% úrok → totalRepaymentCzk == repay
        FirefishLoan(externalLoanId: "L", loanDate: Date(), maturityDate: Date(),
            durationDays: 365, loanAmountCzk: repay, interestRate: 0, btcFeeRate: 0,
            btcPriceAtLoan: 1_000_000, collateralBtcAmount: collateral, isRepaid: false)
    }

    func test_perLoanLtvAndLiquidation() {
        let r = RiskMetricsUseCase.perLoan(loan: makeLoan(50000, 0.1), btcPrice: 1_000_000, ath: 2_000_000)
        XCTAssertEqual(r.ltv, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.liquidationPriceCzk, 526_315.79, accuracy: 0.5)
        XCTAssertEqual(r.level, .ok)
    }

    func test_levelThresholds() {
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.72), .ok)
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.80), .warning)
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.90), .danger)
    }

    func test_yearsSustainable() {
        // maxDebt 950000, headroom 950000, ln(9.5)/ln(1.1) ≈ 23.6
        let y = RiskMetricsUseCase.yearsAtPrice(price: 1_000_000, btc: 1.0, ffDebt: 100_000,
            bankDebt: 0, avgFfRate: 0.10)
        XCTAssertEqual(y, 23.6, accuracy: 0.3)
    }

    func test_effectiveLiqAndBreakEven() {
        XCTAssertEqual(RiskMetricsUseCase.effectiveLiquidationPrice(totalDebt: 95000, totalBtc: 1.0),
                       100_000, accuracy: 0.5)
        XCTAssertEqual(RiskMetricsUseCase.breakEvenPrice(totalDebt: 100000, totalBtc: 2.0, initialBtc: 1.0),
                       100_000, accuracy: 0.5)
    }
}
