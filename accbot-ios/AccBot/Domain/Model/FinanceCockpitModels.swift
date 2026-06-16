import Foundation

/// Baseline z `finance-baseline.json` (smart-dca-data) — median měsíčně po kategoriích + příjem.
/// Čísla jsou Int (JSON má čísla, ne stringy).
struct FinanceBaseline: Codable, Equatable {
    var version: Int
    var monthsCounted: Int
    var incomeMedianCzk: Int
    /// Skutečný průměrný deficit (výdaje − příjem) za poslední 3 uzavřené měsíce. Volitelné (starší JSON ho nemá).
    var recentCyclesAvgDeficitCzk: Int?
    var payday: Payday
    var categories: [Cat]

    struct Payday: Codable, Equatable {
        var dayOfMonth: Int
        var source: String
    }

    struct Cat: Codable, Equatable, Identifiable {
        var name: String
        var monthlyMedianCzk: Int
        var merchants: [Sub]?
        var subcategories: [Sub]?
        var id: String { name }
    }

    struct Sub: Codable, Equatable, Identifiable {
        var name: String
        var monthlyMedianCzk: Int
        var id: String { name }
    }
}

/// Pravidla auto-kategorizace Fio transakcí (git: fio-rules.json). match = podřetězec
/// (lowercase) v protistraně+zprávě, první shoda vyhrává. category "Skrýt" = nepočítat.
struct FioRules: Codable, Equatable {
    var version: Int
    var rules: [Rule]
    struct Rule: Codable, Equatable {
        var match: String
        var category: String
    }
}

/// Ruční vstupy kokpitu, co přežijí reinstall (git: cockpit-state.json): výplata + ruční útraty.
struct CockpitState: Codable, Equatable {
    var nextPaycheckCzk: Int
    var manualSpends: [ManualSpend]
}

/// Trvalé příkazy z `standing-orders.json` — banka je exekuuje, appka je jen počítá v jejich den.
struct StandingOrders: Codable, Equatable {
    var version: Int
    var orders: [Order]

    struct Order: Codable, Equatable, Identifiable {
        var name: String
        var category: String
        var amountCzk: Int
        var frequency: String
        var dayOfMonth: Int
        var account: String?
        var lastPaid: String?
        var nextPaid: String?
        var note: String?
        var id: String { name }

        /// Přesun mezi vlastními účty (financuje trvalé platby) — ne výdaj ani investice.
        var isInternalTransfer: Bool { category == "InternalTransfer" }
        /// Skutečná investice (BTC apod.) — v tomhle přehledu se vůbec nezobrazuje (řeší portfolio).
        var isHiddenInvestment: Bool { category == "Investice" }
    }
}
