import Foundation

/// Načte finance baseline + trvalé příkazy z private repa smart-dca-data (přes GitHub Contents API).
final class FinanceService {
    private let gitHub: GitHubBackupService

    init(gitHubBackupService: GitHubBackupService) {
        self.gitHub = gitHubBackupService
    }

    /// Vrátí baseline + trvalé příkazy, nebo nil když baseline nejde načíst (chybí PAT / soubor).
    /// Trvalé příkazy jsou volitelné (prázdné, když chybí).
    func load() async -> (baseline: FinanceBaseline, orders: [StandingOrders.Order])? {
        guard let (bData, _) = await gitHub.fetch(path: "finance-baseline.json"),
              let baseline = try? JSONDecoder().decode(FinanceBaseline.self, from: bData) else {
            return nil
        }
        var orders: [StandingOrders.Order] = []
        if let (sData, _) = await gitHub.fetch(path: "standing-orders.json"),
           let so = try? JSONDecoder().decode(StandingOrders.self, from: sData) {
            orders = so.orders
        }
        return (baseline, orders)
    }

    /// Fio kategorie transakcí z gitu (fio-overrides.json) — aby zůstaly i po reinstalu.
    func loadFioOverrides() async -> [String: String] {
        guard let (data, _) = await gitHub.fetch(path: "fio-overrides.json"),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    /// Uloží Fio kategorie do gitu (po každé změně).
    func saveFioOverrides(_ overrides: [String: String]) async {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        _ = await gitHub.push(data, path: "fio-overrides.json", message: "fio: kategorie transakcí")
    }

    /// Ruční vstupy kokpitu (výplata + ruční útraty) z gitu — aby přežily reinstall.
    func loadCockpitState() async -> CockpitState? {
        guard let (data, _) = await gitHub.fetch(path: "cockpit-state.json"),
              let s = try? JSONDecoder().decode(CockpitState.self, from: data) else { return nil }
        return s
    }

    /// Uloží ruční vstupy kokpitu do gitu (po každé změně).
    func saveCockpitState(_ state: CockpitState) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        _ = await gitHub.push(data, path: "cockpit-state.json", message: "kokpit: výplata + ruční útraty")
    }

    /// Pravidla auto-kategorizace Fio z gitu (fio-rules.json). Prázdné, když chybí.
    func loadFioRules() async -> [FioRules.Rule] {
        guard let (data, _) = await gitHub.fetch(path: "fio-rules.json"),
              let r = try? JSONDecoder().decode(FioRules.self, from: data) else { return [] }
        return r.rules
    }
}
