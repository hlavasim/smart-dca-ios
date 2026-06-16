import Foundation

/// Výsledek ručního nákupu přes burzu (String error — Result vyžaduje Error, tady stačí hláška).
enum ManualBuyOutcome {
    case success(Decimal)
    case failure(String)
}

/// Ruční nákup BTC: buď jen zaznamenat (koupeno mimo appku), nebo koupit teď přes burzu.
/// Zapíše Transaction (pro portfolio) + HoldingRecord (pro čisté jmění/daně).
final class ManualBuyUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    @discardableResult
    func record(btcAmount: Decimal, czkAmount: Decimal, date: Date, orderId: String, source: String) -> Bool {
        guard btcAmount > 0, czkAmount > 0 else { return false }
        let price = czkAmount / btcAmount
        let planId = ((try? db.planDao.getAll()) ?? [])
            .first { if case .nupl = $0.strategy { return true }; return false }?.id ?? 0
        try? db.transactionDao.insert(Transaction(
            planId: planId, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: czkAmount, cryptoAmount: btcAmount, price: price, fee: 0,
            status: .completed, exchangeOrderId: orderId, executedAt: date))
        try? db.holdingDao.upsert(HoldingRecord(
            id: UUID().uuidString, amount: "\(btcAmount)", acquisitionDate: date.timeIntervalSince1970,
            purchasePriceCzk: "\(price)", isCollateralized: false, loanId: nil,
            isAvailableForDca: true, source: source, notes: "Ruční nákup", createdAt: Date().timeIntervalSince1970))
        return true
    }

    /// Nákup mimo schedule přes burzu (custom částka). Vrátí koupené BTC nebo chybu.
    func buyNow(czkAmount: Decimal, api: ExchangeApi) async -> ManualBuyOutcome {
        guard czkAmount > 0 else { return .failure("Zadej částku") }
        switch await api.marketBuy(crypto: "BTC", fiat: "CZK", fiatAmount: czkAmount) {
        case .success(let tx):
            _ = record(btcAmount: tx.cryptoAmount, czkAmount: tx.fiatAmount, date: tx.executedAt,
                       orderId: tx.exchangeOrderId ?? "MANUAL-\(UUID().uuidString.prefix(8))", source: "Manual-buy")
            return .success(tx.cryptoAmount)
        case .error(let message, _):
            return .failure(message)
        }
    }
}
