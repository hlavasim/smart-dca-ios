import Foundation
import SwiftUI

@MainActor
final class RiskCockpitViewModel: ObservableObject {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let level: RiskLevel
    }

    @Published var loanRisks: [LoanRisk] = []
    @Published var rows: [Row] = []
    @Published var isLoading = false

    private let db: DcaDatabase
    private let marketData: MarketDataService

    init(db: DcaDatabase, marketData: MarketDataService) {
        self.db = db
        self.marketData = marketData
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        let price = (await marketData.getCurrentPrice(crypto: "BTC", fiat: "CZK")) ?? 0
        let ath = (await marketData.getAllTimeHigh(crypto: "BTC", fiat: "CZK")) ?? price

        let loans = ((try? db.firefishLoanDao.getActive()) ?? []).map(mapLoan)
        loanRisks = loans.map { RiskMetricsUseCase.perLoan(loan: $0, btcPrice: price, ath: ath) }

        let totalBtc = NSDecimalNumber(decimal: ((try? db.holdingDao.totalAmount()) ?? 0)).doubleValue
        let totalDebt = loans.reduce(0.0) { $0 + NSDecimalNumber(decimal: $1.totalRepaymentCzk).doubleValue }
        let effLiq = RiskMetricsUseCase.effectiveLiquidationPrice(totalDebt: totalDebt, totalBtc: totalBtc)

        let taxHoldings = ((try? db.holdingDao.getAll()) ?? []).map {
            TaxHolding(amount: NSDecimalNumber(decimal: Decimal(string: $0.amount) ?? 0).doubleValue,
                       acquisition: Date(timeIntervalSince1970: $0.acquisitionDate))
        }
        let tax = TaxRules.classify(holdings: taxHoldings, today: Date())

        var r: [Row] = []
        if let worst = loanRisks.map(\.ltv).max() {
            r.append(Row(label: "Nejhorší LTV", value: pct(worst), level: RiskMetricsUseCase.level(ltv: worst)))
        }
        r.append(Row(label: "Efektivní likvidace (celé portfolio)", value: czk(effLiq), level: .ok))
        r.append(Row(label: "Volné BTC (daňově)", value: btc(tax.taxFree), level: .ok))
        r.append(Row(label: "Zdanitelné BTC", value: btc(tax.taxable), level: .ok))
        rows = r
    }

    private func mapLoan(_ r: FirefishLoanRecord) -> FirefishLoan {
        FirefishLoan(
            externalLoanId: r.externalLoanId,
            loanDate: Date(timeIntervalSince1970: r.loanDate),
            maturityDate: Date(timeIntervalSince1970: r.maturityDate),
            durationDays: r.durationDays,
            loanAmountCzk: Decimal(string: r.loanAmountCzk) ?? 0,
            interestRate: Decimal(string: r.interestRate) ?? 0,
            btcFeeRate: Decimal(string: r.btcFeeRate) ?? 0,
            btcPriceAtLoan: Decimal(string: r.btcPriceAtLoan) ?? 0,
            collateralBtcAmount: Decimal(string: r.collateralBtcAmount) ?? 0,
            isRepaid: r.isRepaid)
    }

    private func pct(_ d: Double) -> String { String(format: "%.0f %%", d * 100) }
    private func czk(_ d: Double) -> String { String(format: "%.0f Kč", d) }
    private func btc(_ d: Double) -> String { String(format: "%.4f BTC", d) }
}
