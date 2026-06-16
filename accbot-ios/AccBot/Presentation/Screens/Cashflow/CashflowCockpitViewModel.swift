import Foundation

/// Strukturální měsíční obraz: příjem vs výdaje (medián) → bilance, kam peníze jdou, pevné platby.
/// Bez Fio (fáze C) jde o typický/medián obraz, ne živé útraty tohoto měsíce.
@MainActor
final class CashflowCockpitViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var loaded = false
    @Published var errorMessage: String?

    @Published var incomeCzk = 0
    @Published var expensesCzk = 0
    @Published var balanceCzk = 0          // income − expenses (záporné = strukturální díra)
    @Published var paydayDay = 27

    @Published var categories: [FinanceBaseline.Cat] = []     // seřazené desc
    @Published var standingVisible: [StandingOrders.Order] = []
    @Published var investedFlow: [StandingOrders.Order] = []   // Investice/převody (odkládání)

    // Fio (živé útraty)
    @Published var fioSummary: FioSummary?
    @Published var fioLoading = false
    @Published var fioError: String?

    private let financeService: FinanceService
    private let fioService: FioService

    init(deps: AppDependencies) {
        self.financeService = deps.financeService
        self.fioService = deps.fioService
    }

    func refreshFio() async {
        fioLoading = true
        defer { fioLoading = false }
        switch await fioService.fetchCurrentMonth() {
        case .success(let summary):
            fioSummary = summary
            fioError = nil
        case .failure(let err):
            fioError = {
                switch err {
                case .noToken: return String(localized: "Chybí Fio token — přidej ho v Nastavení.")
                case .rateLimited: return String(localized: "Fio: moc časté dotazy (limit 1×/30 s), zkus za chvíli.")
                case .http: return String(localized: "Fio se nepodařilo načíst (síť/API).")
                case .parse: return String(localized: "Fio: nečekaná odpověď.")
                }
            }()
        }
    }

    var maxCategoryCzk: Int { categories.map(\.monthlyMedianCzk).max() ?? 1 }
    var investedTotalCzk: Int { investedFlow.reduce(0) { $0 + $1.amountCzk } }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let (baseline, orders) = await financeService.load() else {
            errorMessage = String(localized: "Nepodařilo se načíst finanční data. Zkontroluj PAT v Nastavení.")
            return
        }
        incomeCzk = baseline.incomeMedianCzk
        expensesCzk = baseline.categories.reduce(0) { $0 + $1.monthlyMedianCzk }
        balanceCzk = incomeCzk - expensesCzk
        paydayDay = baseline.payday.dayOfMonth
        categories = baseline.categories.sorted { $0.monthlyMedianCzk > $1.monthlyMedianCzk }
        standingVisible = orders.filter { !$0.isInvestedFlow }.sorted { $0.dayOfMonth < $1.dayOfMonth }
        investedFlow = orders.filter { $0.isInvestedFlow }
        errorMessage = nil
        loaded = true
    }
}
