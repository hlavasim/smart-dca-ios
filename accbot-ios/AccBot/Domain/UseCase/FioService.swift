import Foundation

/// Živý souhrn z Fio účtu (read-only token v Keychain). Aktuální zůstatek + útrata/příjem tento měsíc.
struct FioSummary: Equatable {
    var balanceCzk: Decimal
    var spentThisMonthCzk: Decimal
    var incomeThisMonthCzk: Decimal
    var txCount: Int
}

/// Čte Fio API (fioapi.fio.cz/v1/rest). Token je v URL (read-only), žádné hlavičky.
/// Pozor na rate limit Fio (1 dotaz / 30 s na token).
final class FioService {
    enum FioError: Error { case noToken, rateLimited, http, parse }

    private let client: NetworkClient
    private let tokenStore: TokenStore

    init(client: NetworkClient, tokenStore: TokenStore) {
        self.client = client
        self.tokenStore = tokenStore
    }

    /// Souhrn za zadané období (typicky od poslední výplaty do dnes — výplatní cyklus).
    func fetch(from: Date, to: Date) async -> Result<FioSummary, FioError> {
        guard let token = tokenStore.get(), !token.isEmpty else { return .failure(.noToken) }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Prague") ?? .current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = cal.timeZone
        let url = "https://fioapi.fio.cz/v1/rest/periods/\(token)/\(fmt.string(from: from))/\(fmt.string(from: to))/transactions.json"

        do {
            let (data, resp) = try await client.get(url: url)
            if resp.statusCode == 409 { return .failure(.rateLimited) }
            guard resp.statusCode == 200 else { return .failure(.http) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let acc = root["accountStatement"] as? [String: Any],
                  let info = acc["info"] as? [String: Any] else { return .failure(.parse) }

            let balance = dec(info["closingBalance"])
            var spent = Decimal(0), income = Decimal(0), count = 0
            if let txList = acc["transactionList"] as? [String: Any],
               let txs = txList["transaction"] as? [[String: Any]] {
                for t in txs {
                    guard let col1 = t["column1"] as? [String: Any] else { continue }
                    let amt = dec(col1["value"])
                    count += 1
                    if amt < 0 { spent += -amt } else { income += amt }
                }
            }
            return .success(FioSummary(balanceCzk: balance, spentThisMonthCzk: spent,
                                       incomeThisMonthCzk: income, txCount: count))
        } catch {
            return .failure(.http)
        }
    }

    private func dec(_ v: Any?) -> Decimal {
        if let n = v as? NSNumber { return n.decimalValue }
        if let s = v as? String, let d = Decimal(string: s) { return d }
        return 0
    }
}
