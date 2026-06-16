import SwiftUI

/// Risk cockpit — LTV/likvidace/daňový rozpad. Minimální UI; theme/navigaci doladit on-device.
struct RiskCockpitView: View {
    @StateObject private var vm: RiskCockpitViewModel

    init(deps: AppDependencies) {
        _vm = StateObject(wrappedValue: RiskCockpitViewModel(
            db: deps.activeDatabase, marketData: deps.marketDataService))
    }

    var body: some View {
        List {
            Section("Rizika") {
                ForEach(vm.rows) { row in
                    HStack {
                        Text(row.label)
                        Spacer()
                        Text(row.value).foregroundStyle(color(row.level))
                    }
                }
            }
            Section("Půjčky — LTV a likvidační cena (per půjčka)") {
                ForEach(vm.loanRisks, id: \.externalLoanId) { lr in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(lr.externalLoanId)
                            Spacer()
                            Text(String(format: "LTV %.0f %%", lr.ltv * 100)).foregroundStyle(color(lr.level))
                        }
                        Text(String(format: "Likvidace při %.0f Kč/BTC · rezerva %.0f %%", lr.liquidationPriceCzk, lr.bufferPct * 100))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Pozn.: „Efektivní likvidace" nahoře je cena BTC, při které je na likvidaci CELÉ portfolio (všechny půjčky proti všem BTC) — ne jedna půjčka.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Risk cockpit")
        .overlay { if vm.isLoading { ProgressView() } }
        .task { await vm.load() }
    }

    private func color(_ level: RiskLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}
