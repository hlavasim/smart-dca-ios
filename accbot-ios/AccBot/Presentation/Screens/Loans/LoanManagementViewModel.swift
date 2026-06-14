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
}
