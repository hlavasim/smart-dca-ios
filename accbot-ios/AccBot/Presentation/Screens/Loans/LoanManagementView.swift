import SwiftUI

/// Správa půjček — seznam + top-up/splacení. Vytvoření/prodej formuláře = on-device UI pass.
struct LoanManagementView: View {
    @StateObject private var vm: LoanManagementViewModel

    init(deps: AppDependencies) {
        _vm = StateObject(wrappedValue: LoanManagementViewModel(deps: deps))
    }

    var body: some View {
        List {
            Section("Firefish půjčky") {
                ForEach(vm.firefishLoans, id: \.externalLoanId) { l in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l.externalLoanId).font(.headline)
                        Text("Kolaterál \(l.collateralBtcAmount) BTC").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Top-up 0.01") { vm.topUp(l.externalLoanId, addBtc: 0.01) }
                            Spacer()
                            Button("Splatit", role: .destructive) { vm.repay(l.externalLoanId) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if vm.firefishLoans.isEmpty { Text("Žádné aktivní FF půjčky").foregroundStyle(.secondary) }
            }
            Section("Bankovní půjčky") {
                ForEach(vm.bankLoans, id: \.id) { l in
                    HStack {
                        Text("Zbývá")
                        Spacer()
                        Text("\(l.remainingPrincipalCzk) Kč").foregroundStyle(.secondary)
                    }
                }
                if vm.bankLoans.isEmpty { Text("Žádné aktivní bankovní půjčky").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Půjčky")
        .task { vm.load() }
        .overlay(alignment: .bottom) {
            if let m = vm.message {
                Text(m).font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(.bottom, 8)
            }
        }
    }
}
