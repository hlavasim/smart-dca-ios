import SwiftUI

/// Správa půjček — seznam + top-up/splacení + vytvoření FF / prodej BTC.
struct LoanManagementView: View {
    @StateObject private var vm: LoanManagementViewModel
    @State private var showCreate = false
    @State private var showSell = false

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Nová FF půjčka") { showCreate = true }
                    Button("Prodat BTC") { showSell = true }
                } label: { Image(systemName: "plus") }
            }
        }
        .task { vm.load() }
        .sheet(isPresented: $showCreate) { CreateLoanForm(vm: vm) }
        .sheet(isPresented: $showSell) { SellBtcForm(vm: vm) }
        .overlay(alignment: .bottom) {
            if let m = vm.message {
                Text(m).font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(.bottom, 8)
            }
        }
    }
}

private struct CreateLoanForm: View {
    @ObservedObject var vm: LoanManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var externalId = ""
    @State private var amount = ""
    @State private var collateral = ""
    @State private var durationDays = "365"
    @State private var interestRate = "0.10"
    @State private var btcFeeRate = "0.015"
    @State private var btcPrice = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("External ID", text: $externalId)
                TextField("Částka CZK", text: $amount).keyboardType(.decimalPad)
                TextField("Kolaterál BTC", text: $collateral).keyboardType(.decimalPad)
                TextField("Doba (dny)", text: $durationDays).keyboardType(.numberPad)
                TextField("Úrok p.a. (0.10)", text: $interestRate).keyboardType(.decimalPad)
                TextField("BTC fee p.a. (0.015)", text: $btcFeeRate).keyboardType(.decimalPad)
                TextField("Cena BTC při půjčce", text: $btcPrice).keyboardType(.decimalPad)
            }
            .navigationTitle("Nová FF půjčka")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušit") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Vytvořit") {
                        vm.createFFLoan(
                            externalId: externalId,
                            amountCzk: Decimal(string: dec(amount)) ?? 0,
                            collateralBtc: Decimal(string: dec(collateral)) ?? 0,
                            durationDays: Int(durationDays) ?? 365,
                            interestRate: Decimal(string: dec(interestRate)) ?? 0,
                            btcFeeRate: Decimal(string: dec(btcFeeRate)) ?? 0,
                            btcPriceAtLoan: Decimal(string: dec(btcPrice)) ?? 0)
                        dismiss()
                    }
                    .disabled(externalId.isEmpty || amount.isEmpty || collateral.isEmpty || btcPrice.isEmpty)
                }
            }
        }
    }
    private func dec(_ s: String) -> String { s.replacingOccurrences(of: ",", with: ".") }
}

private struct SellBtcForm: View {
    @ObservedObject var vm: LoanManagementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Množství BTC", text: $amount).keyboardType(.decimalPad)
                Text("Prodá se přes CoinMate; uloží se FIFO daňový rozpad.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Prodat BTC")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Zrušit") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Prodat", role: .destructive) {
                        let amt = Decimal(string: amount.replacingOccurrences(of: ",", with: ".")) ?? 0
                        Task { await vm.sellBtc(amount: amt); dismiss() }
                    }
                    .disabled(amount.isEmpty)
                }
            }
        }
    }
}
