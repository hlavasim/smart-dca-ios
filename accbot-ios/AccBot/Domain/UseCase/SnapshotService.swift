import Foundation

/// Staví AppSnapshot z DB a nahrává zpět. Loany doplní Plán 3 (rozšíří build/load).
/// Import = obnova: stejná load cesta pro migraci z C# i disaster recovery.
final class SnapshotService {
    private let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private let isoFmt = ISO8601DateFormatter()

    func build(from db: DcaDatabase, fiat: String) throws -> AppSnapshot {
        let holdings = try db.holdingDao.getAll().map { h in
            AppSnapshot.HoldingSnap(
                id: h.id, amount: h.amount,
                acquisitionDate: dayFmt.string(from: Date(timeIntervalSince1970: h.acquisitionDate)),
                purchasePriceCzk: h.purchasePriceCzk, isCollateralized: h.isCollateralized,
                loanId: h.loanId, source: h.source, notes: h.notes)
        }
        let txs = try db.transactionDao.getAll(limit: 100_000).map { t in
            AppSnapshot.TxSnap(
                date: dayFmt.string(from: t.executedAt), type: "DCA_PURCHASE",
                amountBtc: "\(t.cryptoAmount)", amountCzk: "-\(t.fiatAmount)",
                btcPriceCzk: "\(t.price)", exchangeOrderId: t.exchangeOrderId)
        }
        // strategie: z prvního NUPL plánu
        let plan = try db.planDao.getAll().first { if case .nupl = $0.strategy { return true }; return false }
        let cfg: NuplConfig = { if case .nupl(let c)? = plan?.strategy { return c }; return .default }()
        let strategy = AppSnapshot.StrategySnap(
            type: "NUPL",
            nuplBottomValue: cfg.bottomValue, nuplCenterValue: cfg.centerValue,
            nuplMinMultiplier: Double(cfg.minMultiplier), nuplMaxMultiplier: Double(cfg.maxMultiplier),
            baseChunkCzk: plan.map { "\($0.amount)" } ?? "0", baseChunkMultiplier: "1.0",
            lastProcessedDate: plan?.lastExecutedAt.map { dayFmt.string(from: $0) } ?? "",
            availableCashCzk: "0") // cash je živá z burzy, neukládáme
        let firefishLoans = try db.firefishLoanDao.getAll().map { l in
            AppSnapshot.FirefishLoanSnap(
                externalLoanId: l.externalLoanId,
                loanDate: dayFmt.string(from: Date(timeIntervalSince1970: l.loanDate)),
                maturityDate: dayFmt.string(from: Date(timeIntervalSince1970: l.maturityDate)),
                loanAmountCzk: l.loanAmountCzk, interestRate: l.interestRate,
                btcFeeRate: l.btcFeeRate, btcPriceAtLoan: l.btcPriceAtLoan,
                collateralBtcAmount: l.collateralBtcAmount, isRepaid: l.isRepaid)
        }
        let bankLoans = try db.bankLoanDao.getAll().map { l in
            AppSnapshot.BankLoanSnap(
                principalCzk: l.principalCzk, annualInterestRate: l.annualInterestRate,
                durationMonths: l.durationMonths, remainingPrincipalCzk: l.remainingPrincipalCzk,
                nextPaymentDate: dayFmt.string(from: Date(timeIntervalSince1970: l.nextPaymentDate)),
                isFullyPaid: l.isFullyPaid)
        }
        return AppSnapshot(
            version: 1, exportedAt: isoFmt.string(from: Date()), fiat: fiat,
            strategy: strategy, holdings: holdings, transactions: txs,
            firefishLoans: firefishLoans, bankLoans: bankLoans)
    }

    func load(_ snap: AppSnapshot, into db: DcaDatabase) throws {
        let now = Date().timeIntervalSince1970
        try db.holdingDao.deleteAll()
        try db.holdingDao.upsertBatch(snap.holdings.map { h in
            HoldingRecord(
                id: h.id, amount: h.amount,
                acquisitionDate: (dayFmt.date(from: h.acquisitionDate) ?? Date()).timeIntervalSince1970,
                purchasePriceCzk: h.purchasePriceCzk, isCollateralized: h.isCollateralized,
                loanId: h.loanId, isAvailableForDca: true, source: h.source, notes: h.notes, createdAt: now)
        })
        try db.firefishLoanDao.deleteAll()
        try db.firefishLoanDao.upsertBatch(snap.firefishLoans.map { l in
            let loanD = dayFmt.date(from: l.loanDate) ?? Date()
            let matD = dayFmt.date(from: l.maturityDate) ?? Date()
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: loanD, to: matD).day ?? 0
            return FirefishLoanRecord(
                externalLoanId: l.externalLoanId,
                loanDate: loanD.timeIntervalSince1970, maturityDate: matD.timeIntervalSince1970,
                durationDays: max(0, days),
                loanAmountCzk: l.loanAmountCzk, interestRate: l.interestRate,
                btcFeeRate: l.btcFeeRate, btcPriceAtLoan: l.btcPriceAtLoan,
                collateralBtcAmount: l.collateralBtcAmount, isRepaid: l.isRepaid)
        })
        try db.bankLoanDao.deleteAll()
        try db.bankLoanDao.upsertBatch(snap.bankLoans.enumerated().map { idx, l in
            BankLoanRecord(
                id: "bank-\(idx)",
                principalCzk: l.principalCzk, annualInterestRate: l.annualInterestRate,
                durationMonths: l.durationMonths, remainingPrincipalCzk: l.remainingPrincipalCzk,
                nextPaymentDate: (dayFmt.date(from: l.nextPaymentDate) ?? Date()).timeIntervalSince1970,
                isFullyPaid: l.isFullyPaid)
        })
        // Pozn.: transakce/plán load (re-importovatelné z CoinMate) lze doplnit dle potřeby.
    }
}
