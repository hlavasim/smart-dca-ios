import Foundation

/// Ruční útrata (kreditka/hotovost mimo Fio). Ukládá se lokálně do UserDefaults (malý seznam).
struct ManualSpend: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var amountCzk: Decimal
    var category: String
    var note: String
}

/// Lokální úložiště ručních útrat (UserDefaults JSON). Žádná migrace DB — drobný seznam.
final class ManualSpendStore {
    private let defaults: UserDefaults
    private let key = "manualSpends.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [ManualSpend] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([ManualSpend].self, from: data) else { return [] }
        return items.sorted { $0.date > $1.date }
    }

    func add(_ s: ManualSpend) {
        var items = all()
        items.append(s)
        save(items)
    }

    func remove(id: String) {
        save(all().filter { $0.id != id })
    }

    /// Sloučí útraty z gitu (union podle id — lokální se neztratí).
    func merge(_ remote: [ManualSpend]) {
        var byId = Dictionary(all().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for r in remote where byId[r.id] == nil { byId[r.id] = r }
        save(Array(byId.values))
    }

    /// Útraty od daného data (včetně) — pro útratu v aktuálním výplatním cyklu.
    func since(_ date: Date) -> [ManualSpend] {
        all().filter { $0.date >= date }
    }

    private func save(_ items: [ManualSpend]) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}
