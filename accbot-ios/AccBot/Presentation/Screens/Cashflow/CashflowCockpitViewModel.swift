import Foundation

/// Forward-looking kokpit: hlavní je VÝHLED (do výplaty vyjdeš/zbyde, runway, safe-to-spend),
/// ne strašící „−75k". Kombinuje Fio (živě) + ruční útraty proti baseline. Cyklus = od poslední výplaty.
@MainActor
final class CashflowCockpitViewModel: ObservableObject {
    // Kontext z baseline
    @Published var isLoading = false
    @Published var loaded = false
    @Published var errorMessage: String?
    @Published var incomeCzk = 0
    @Published var expensesCzk = 0
    @Published var structuralBalanceCzk = 0     // income − expenses (kontext, ne hero)
    @Published var paydayDay = 27
    @Published var categories: [FinanceBaseline.Cat] = []
    @Published var standingVisible: [StandingOrders.Order] = []
    @Published var investedFlow: [StandingOrders.Order] = []

    // Fio + ruční útraty + projekce
    @Published var fioLoading = false
    @Published var fioError: String?
    @Published var fioBalance: Decimal?          // nil = ještě nerefreshováno
    @Published var fioSpentCycle: Decimal = 0
    @Published var manualSpends: [ManualSpend] = []

    // Spočtený výhled
    @Published var daysUntilPayday = 0
    @Published var spentThisCycle: Decimal = 0   // Fio + ruční
    @Published var projectedAtPayday: Decimal?   // zůstatek na výplatu při current tempu
    @Published var safeToSpendPerDay: Decimal?
    @Published var runwayDate: Date?             // do kdy peníze vydrží
    @Published var runwayCoversPayday = false

    private let financeService: FinanceService
    private let fioService: FioService
    private let manualStore: ManualSpendStore
    private let cal: Calendar

    init(deps: AppDependencies) {
        self.financeService = deps.financeService
        self.fioService = deps.fioService
        self.manualStore = deps.manualSpendStore
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague") ?? .current
        self.cal = c
    }

    // MARK: - Cyklus (od poslední výplaty po příští)

    private var today: Date { cal.startOfDay(for: Date()) }

    private func paydayInMonth(of date: Date) -> Date {
        var comps = cal.dateComponents([.year, .month], from: date)
        let range = cal.range(of: .day, in: .month, for: date) ?? 1..<29
        comps.day = min(paydayDay, range.upperBound - 1)
        return cal.date(from: comps) ?? date
    }

    var lastPayday: Date {
        let thisMonth = paydayInMonth(of: today)
        if today >= thisMonth { return thisMonth }
        let prev = cal.date(byAdding: .month, value: -1, to: today) ?? today
        return paydayInMonth(of: prev)
    }

    var nextPayday: Date {
        let next = cal.date(byAdding: .month, value: 1, to: lastPayday) ?? today
        return paydayInMonth(of: next)
    }

    private func days(_ from: Date, _ to: Date) -> Int {
        cal.dateComponents([.day], from: from, to: to).day ?? 0
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let (baseline, orders) = await financeService.load() else {
            errorMessage = String(localized: "Nepodařilo se načíst data. Zkontroluj PAT v Nastavení.")
            return
        }
        incomeCzk = baseline.incomeMedianCzk
        expensesCzk = baseline.categories.reduce(0) { $0 + $1.monthlyMedianCzk }
        structuralBalanceCzk = incomeCzk - expensesCzk
        paydayDay = baseline.payday.dayOfMonth
        categories = baseline.categories.sorted { $0.monthlyMedianCzk > $1.monthlyMedianCzk }
        standingVisible = orders.filter { !$0.isInvestedFlow }.sorted { $0.dayOfMonth < $1.dayOfMonth }
        investedFlow = orders.filter { $0.isInvestedFlow }
        manualSpends = manualStore.since(lastPayday)
        errorMessage = nil
        loaded = true
        recompute()
    }

    // MARK: - Fio

    func refreshFio() async {
        fioLoading = true
        defer { fioLoading = false }
        switch await fioService.fetch(from: lastPayday, to: Date()) {
        case .success(let s):
            fioBalance = s.balanceCzk
            fioSpentCycle = s.spentThisMonthCzk
            fioError = nil
            recompute()
        case .failure(let err):
            fioError = {
                switch err {
                case .noToken: return String(localized: "Chybí Fio token — přidej ho v Nastavení.")
                case .rateLimited: return String(localized: "Fio: moc časté dotazy (1×/30 s), zkus za chvíli.")
                case .http: return String(localized: "Fio se nepodařilo načíst (síť/API).")
                case .parse: return String(localized: "Fio: nečekaná odpověď.")
                }
            }()
        }
    }

    // MARK: - Ruční útraty

    func addManual(amountCzk: Decimal, category: String, note: String) {
        let s = ManualSpend(id: UUID().uuidString, date: Date(), amountCzk: amountCzk,
                            category: category, note: note)
        manualStore.add(s)
        manualSpends = manualStore.since(lastPayday)
        recompute()
    }

    func removeManual(id: String) {
        manualStore.remove(id: id)
        manualSpends = manualStore.since(lastPayday)
        recompute()
    }

    var manualSpentCycle: Decimal { manualSpends.reduce(0) { $0 + $1.amountCzk } }

    // MARK: - Projekce

    private func recompute() {
        daysUntilPayday = max(0, days(today, nextPayday))
        spentThisCycle = fioSpentCycle + manualSpentCycle

        guard let balance = fioBalance else {
            projectedAtPayday = nil
            safeToSpendPerDay = nil
            runwayDate = nil
            runwayCoversPayday = false
            return
        }
        let elapsed = max(1, days(lastPayday, today))
        let dvojToday = dbl(spentThisCycle) / Double(elapsed)              // denní tempo
        let projectedRemaining = dvojToday * Double(daysUntilPayday)
        projectedAtPayday = balance - Decimal(projectedRemaining)
        safeToSpendPerDay = daysUntilPayday > 0 ? balance / Decimal(daysUntilPayday) : balance

        if dvojToday > 0.5 {
            let runwayDays = dbl(balance) / dvojToday
            let rd = cal.date(byAdding: .day, value: Int(runwayDays.rounded()), to: today)
            runwayDate = rd
            runwayCoversPayday = (rd ?? today) >= nextPayday
        } else {
            runwayDate = nil                 // ještě nic neutraceno → tempo neznámé
            runwayCoversPayday = true
        }
    }

    private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    var maxCategoryCzk: Int { categories.map(\.monthlyMedianCzk).max() ?? 1 }
    var investedTotalCzk: Int { investedFlow.reduce(0) { $0 + $1.amountCzk } }
    /// Přebytek na výplatu = „ušetříš navíc" (nad už odloženými investicemi). Nil dokud není Fio.
    var willHaveSurplus: Bool { (projectedAtPayday ?? 0) >= 0 }
}
