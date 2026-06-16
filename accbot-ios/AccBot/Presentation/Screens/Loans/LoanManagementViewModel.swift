import Foundation
import SwiftUI

@MainActor
final class LoanManagementViewModel: ObservableObject {
    @Published var firefishLoans: [FirefishLoanRecord] = []
    @Published var bankLoans: [BankLoanRecord] = []
    @Published var message: String?

    private let deps: AppDependencies
    private var db: DcaDatabase { deps.activeDatabase }

    init(deps: AppDependencies) { self.deps = deps }

    func load() {
        firefishLoans = (try? db.firefishLoanDao.getActive()) ?? []
        bankLoans = (try? db.bankLoanDao.getActive()) ?? []
    }

    func repay(_ externalId: String) {
        do {
            try RepayFirefishLoanUseCase(db: db).repay(externalId: externalId)
            message = "Splaceno \(externalId)"
            load()
            backupToGit("FF splacení \(externalId)")
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }

    func topUp(_ externalId: String, addBtc: Double) {
        do {
            try TopUpCollateralUseCase(db: db).topUp(externalId: externalId, addBtc: addBtc)
            message = "Top-up \(externalId): +\(addBtc) BTC"
            load()
            backupToGit("FF top-up \(externalId) +\(addBtc) BTC")
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }

    /// Po změně půjčky hned pushni snapshot do gitu (jinak se data nesesynchronizují).
    private func backupToGit(_ reason: String) {
        let db = self.db
        let snapshotService = deps.snapshotService
        let gitHub = deps.gitHubBackupService
        Task.detached {
            guard let snap = try? snapshotService.build(from: db, fiat: "CZK"),
                  !(snap.holdings.isEmpty && snap.firefishLoans.isEmpty && snap.bankLoans.isEmpty),
                  let data = try? JSONEncoder().encode(snap) else { return }
            _ = await gitHub.push(data, message: "snapshot: \(reason)")
        }
    }

    func createFFLoan(externalId: String, amountCzk: Decimal, collateralBtc: Decimal,
                      durationDays: Int, interestRate: Decimal, btcFeeRate: Decimal,
                      btcPriceAtLoan: Decimal, loanDate: Date) {
        do {
            _ = try CreateFirefishLoanUseCase(db: db).create(
                externalId: externalId, loanAmountCzk: amountCzk, collateralBtc: collateralBtc,
                durationDays: durationDays, interestRate: interestRate, btcFeeRate: btcFeeRate,
                btcPriceAtLoan: btcPriceAtLoan, loanDate: loanDate)
            message = "Půjčka \(externalId) vytvořena"
            load()
            backupToGit("FF nová půjčka \(externalId)")
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }

    func sellBtc(amount: Decimal) async {
        let isSandbox = deps.userPreferences.isSandboxMode()
        guard let creds = deps.credentialsStore.get(for: .coinmate, isSandbox: isSandbox) else {
            message = "Chybí CoinMate klíče"
            return
        }
        let api = deps.exchangeApiFactory.create(credentials: creds)
        do {
            try await SellBtcUseCase(db: db, exchange: api, taxRate: deps.userPreferences.taxRate)
                .sell(cryptoAmount: amount)
            message = "Prodej proveden"
            load()
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }
}
