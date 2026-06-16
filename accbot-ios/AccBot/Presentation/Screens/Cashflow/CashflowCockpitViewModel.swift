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
    @Published var fioTransactions: [FioTransaction] = []

    // Per-kategorie live (současná útrata vs prorated baseline vs projekce)
    struct CategoryLive: Identifiable {
        let id: String
        let name: String
        let spent: Decimal
        let baseline: Int
        let prorated: Decimal     // baseline × část cyklu, co uplynula
        let projected: Decimal    // tempo → konec cyklu
        var overUnder: Decimal { prorated - spent }   // kladné = jdeš pod plán (šetříš)
    }
    @Published var categoryLive: [CategoryLive] = []

    // Příští výplata (čistý zbytek = výplata − trvalé příkazy na Air Bank)
    @Published var nextPaycheckCzk: Int = 0

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
    private let fioCategoryStore: FioCategoryStore
    private let defaults = UserDefaults.standard
    private let paycheckKey = "nextPaycheckCzk.v1"
    private let cal: Calendar

    init(deps: AppDependencies) {
        self.financeService = deps.financeService
        self.fioService = deps.fioService
        self.manualStore = deps.manualSpendStore
        self.fioCategoryStore = deps.fioCategoryStore
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague") ?? .current
        self.cal = c
        self.nextPaycheckCzk = defaults.integer(forKey: paycheckKey)
    }

    /// Kategorie Fio transakce: override z úložiště, jinak "Nezařazeno".
    func fioCategory(for tx: FioTransaction) -> String {
        fioCategoryStore.category(for: tx.id) ?? String(localized: "Nezařazeno")
    }

    func setFioCategory(_ category: String, for tx: FioTransaction) {
        fioCategoryStore.set(category, for: tx.id)
        objectWillChange.send()
        recompute()
    }

    func setNextPaycheck(_ czk: Int) {
        nextPaycheckCzk = czk
        defaults.set(czk, forKey: paycheckKey)
    }

    /// Trvalé příkazy na Air Bank (vše krom Fio) → odečíst od hrubé výplaty = čistý zbytek.
    var standingTotalCzk: Int {
        (standingVisible + investedFlow).reduce(0) { $0 + $1.amountCzk }
    }
    var paycheckRestCzk: Int { max(0, nextPaycheckCzk - standingTotalCzk) }

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
            fioTransactions = s.transactions
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
        let cycleDays = max(1, days(lastPayday, nextPayday))
        let elapsed = max(1, days(lastPayday, today))
        let hidden = FioCategoryStore.hidden

        // Fio útrata OČIŠTĚNÁ — vyloučí skryté (FF průtok, převody, investice)
        fioSpentCycle = fioTransactions.reduce(Decimal(0)) { acc, tx in
            (tx.amountCzk < 0 && fioCategory(for: tx) != hidden) ? acc + (-tx.amountCzk) : acc
        }
        spentThisCycle = fioSpentCycle + manualSpentCycle

        // Per-kategorie: Fio (ne skryté) + ruční
        var byCat: [String: Decimal] = [:]
        for tx in fioTransactions where tx.amountCzk < 0 {
            let c = fioCategory(for: tx)
            if c != hidden { byCat[c, default: 0] += -tx.amountCzk }
        }
        for m in manualSpends { byCat[m.category, default: 0] += m.amountCzk }
        let baseMap = Dictionary(categories.map { ($0.name, $0.monthlyMedianCzk) }, uniquingKeysWith: { a, _ in a })
        var live: [CategoryLive] = []
        for name in Set(byCat.keys).union(baseMap.keys) {
            let spent = byCat[name] ?? 0
            let baseline = baseMap[name] ?? 0
            guard spent > 0 || baseline > 0 else { continue }
            let prorated = Decimal(baseline) * Decimal(elapsed) / Decimal(cycleDays)
            let projected = spent * Decimal(cycleDays) / Decimal(elapsed)
            live.append(CategoryLive(id: name, name: name, spent: spent, baseline: baseline,
                                     prorated: prorated, projected: projected))
        }
        categoryLive = live.sorted { $0.spent > $1.spent }

        // Projekce obálky
        guard let balance = fioBalance else {
            projectedAtPayday = nil; safeToSpendPerDay = nil; runwayDate = nil; runwayCoversPayday = false
            return
        }
        let dailyBurn = dbl(spentThisCycle) / Double(elapsed)
        projectedAtPayday = balance - Decimal(dailyBurn * Double(daysUntilPayday))
        safeToSpendPerDay = daysUntilPayday > 0 ? balance / Decimal(daysUntilPayday) : balance
        if dailyBurn > 0.5 {
            let rd = cal.date(byAdding: .day, value: Int((dbl(balance) / dailyBurn).rounded()), to: today)
            runwayDate = rd
            runwayCoversPayday = (rd ?? today) >= nextPayday
        } else {
            runwayDate = nil
            runwayCoversPayday = true
        }
    }

    private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    var maxCategoryCzk: Int { categories.map(\.monthlyMedianCzk).max() ?? 1 }
    var investedTotalCzk: Int { investedFlow.reduce(0) { $0 + $1.amountCzk } }
    /// Přebytek na výplatu = „ušetříš navíc" (nad už odloženými investicemi). Nil dokud není Fio.
    var willHaveSurplus: Bool { (projectedAtPayday ?? 0) >= 0 }
}
