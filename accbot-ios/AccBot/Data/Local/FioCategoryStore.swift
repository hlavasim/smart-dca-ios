import Foundation

/// Override kategorií pro Fio transakce (klíč = Fio ID pohybu). Hodnota = kategorie,
/// nebo speciální "Skrýt" = nezapočítat do útrat (např. průtok FF půjčky, převod, investice).
final class FioCategoryStore {
    static let hidden = "Skrýt"

    private let defaults: UserDefaults
    private let key = "fioCategories.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func all() -> [String: String] {
        guard let data = defaults.data(forKey: key),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    func category(for txId: String) -> String? { all()[txId] }

    func set(_ category: String, for txId: String) {
        var m = all()
        m[txId] = category
        if let data = try? JSONEncoder().encode(m) { defaults.set(data, forKey: key) }
    }
}
