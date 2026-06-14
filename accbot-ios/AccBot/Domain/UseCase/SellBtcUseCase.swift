import Foundation

/// Prodej BTC s FIFO cost basis + českým daňovým eventem. CoinMate-only.
final class SellBtcUseCase {
    private let db: DcaDatabase
    private let coinmate: CoinmateApi
    private let taxRate: Double

    init(db: DcaDatabase, coinmate: CoinmateApi, taxRate: Double) {
        self.db = db
        self.coinmate = coinmate
        self.taxRate = taxRate
    }

    /// Čistá FIFO alokace (nejstarší free holdingy first). Bez IO.
    static func fifoAllocate(holdings: [HoldingRecord], sellAmount: Double, salePrice: Double,
                             taxRate: Double, saleDate: Date) -> [FifoAllocationRecord] {
        var remaining = sellAmount
        var out: [FifoAllocationRecord] = []
        for h in holdings.sorted(by: { $0.acquisitionDate < $1.acquisitionDate }) { // ASC = nejstarší first
            if remaining <= 0 { break }
            let amt = Double(h.amount) ?? 0
            let use = min(amt, remaining)
            let acqPrice = Double(h.purchasePriceCzk) ?? 0
            let daysHeld = Int((saleDate.timeIntervalSince1970 - h.acquisitionDate) / 86_400)
            let gain = TaxRules.fifoGain(amount: use, acquisitionPrice: acqPrice, salePrice: salePrice,
                daysHeld: daysHeld, taxRate: taxRate)
            out.append(FifoAllocationRecord(
                id: UUID().uuidString, saleDate: saleDate.timeIntervalSince1970,
                sourceHoldingId: h.id, allocatedBtc: "\(use)", acquisitionPriceCzk: "\(acqPrice)",
                salePriceCzk: "\(salePrice)", profitCzk: "\(gain.profit)", daysHeld: daysHeld,
                isExempt: gain.isExempt, taxAmountCzk: "\(gain.taxAmount)"))
            remaining -= use
        }
        return out
    }

    /// Provede prodej: CoinMate sell → FIFO alokace → uloží fifo_allocations + sníží holdingy + BtcSale tx.
    func sell(cryptoAmount: Decimal) async throws {
        let result = await coinmate.marketSell(crypto: "BTC", fiat: "CZK", cryptoAmount: cryptoAmount)
        guard case .success(let tx) = result else { return }
        let free = try db.holdingDao.getFree()
        let allocs = Self.fifoAllocate(holdings: free,
            sellAmount: NSDecimalNumber(decimal: cryptoAmount).doubleValue,
            salePrice: NSDecimalNumber(decimal: tx.price).doubleValue,
            taxRate: taxRate, saleDate: Date())
        try db.fifoAllocationDao.upsertBatch(allocs)
        try applyHoldingReduction(allocs)
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: tx.fiatAmount, cryptoAmount: tx.cryptoAmount, price: tx.price, fee: tx.fee,
            feeAsset: tx.feeAsset, status: .completed, exchangeOrderId: tx.exchangeOrderId))
    }

    private func applyHoldingReduction(_ allocs: [FifoAllocationRecord]) throws {
        for a in allocs {
            guard let h = try db.holdingDao.getAll().first(where: { $0.id == a.sourceHoldingId }) else { continue }
            let left = (Double(h.amount) ?? 0) - (Double(a.allocatedBtc) ?? 0)
            if left <= CollateralService.epsilon {
                try db.holdingDao.delete(id: h.id)
            } else {
                var updated = h
                updated.amount = "\(left)"
                try db.holdingDao.update(updated)
            }
        }
    }
}
