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
