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
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }

    func topUp(_ externalId: String, addBtc: Double) {
        do {
            try TopUpCollateralUseCase(db: db).topUp(externalId: externalId, addBtc: addBtc)
            message = "Top-up \(externalId): +\(addBtc) BTC"
            load()
        } catch { message = "Chyba: \(error.localizedDescription)" }
    }

    func createFFLoan(externalId: String, amountCzk: Decimal, collateralBtc: Decimal,
                      durationDays: Int, interestRate: Decimal, btcFeeRate: Decimal, btcPriceAtLoan: Decimal) {
        do {
            _ = try CreateFirefishLoanUseCase(db: db).create(
                externalId: externalId, loanAmountCzk: amountCzk, collateralBtc: collateralBtc,
                durationDays: durationDays, interestRate: interestRate, btcFeeRate: btcFeeRate,
                btcPriceAtLoan: btcPriceAtLoan, loanDate: Date())
            message = "Půjčka \(externalId) vytvořena"
            load()
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
