import Foundation

struct AllocationPlan: Equatable {
    var markWhole: [String] = []   // holding ids použité celé
    struct Split: Equatable {
        let sourceHoldingId: String
        let remainingFree: String
        let collateralAmount: String
        let acquisitionDate: Double
        let purchasePriceCzk: String
        let source: String
    }
    var splits: [Split] = []
}

/// Alokace kolaterálu LIFO (nejnovější holdingy first → chrání 3letou daňovou výjimku starých).
/// Split zachová acquisitionDate + purchasePriceCzk + source (kvůli FIFO dani).
enum CollateralService {
    static let epsilon = 0.00000001

    /// Čistá funkce (žádné IO).
    static func planAllocation(free: [HoldingRecord], amountBtc: Double, loanId: String) -> AllocationPlan {
        var plan = AllocationPlan()
        var remaining = amountBtc
        let sorted = free.sorted { $0.acquisitionDate > $1.acquisitionDate } // DESC = nejnovější first
        for h in sorted {
            if remaining <= 0 { break }
            let amt = Double(h.amount) ?? 0
            let use = min(amt, remaining)
            if use >= amt - epsilon {
                plan.markWhole.append(h.id)
            } else {
                plan.splits.append(.init(
                    sourceHoldingId: h.id, remainingFree: "\(amt - use)",
                    collateralAmount: "\(use)", acquisitionDate: h.acquisitionDate,
                    purchasePriceCzk: h.purchasePriceCzk, source: h.source))
            }
            remaining -= use
        }
        return plan
    }

    static func apply(db: DcaDatabase, amountBtc: Double, loanId: String) throws {
        let free = try db.holdingDao.getFree()
        let plan = planAllocation(free: free, amountBtc: amountBtc, loanId: loanId)
        let byId = Dictionary(uniqueKeysWithValues: free.map { ($0.id, $0) })
        for id in plan.markWhole {
            guard var h = byId[id] else { continue }
            h.isCollateralized = true; h.loanId = loanId; h.isAvailableForDca = false
            try db.holdingDao.update(h)
        }
        let now = Date().timeIntervalSince1970
        for s in plan.splits {
            guard var src = byId[s.sourceHoldingId] else { continue }
            src.amount = s.remainingFree
            try db.holdingDao.update(src)
            try db.holdingDao.upsert(HoldingRecord(
                id: UUID().uuidString, amount: s.collateralAmount, acquisitionDate: s.acquisitionDate,
                purchasePriceCzk: s.purchasePriceCzk, isCollateralized: true, loanId: loanId,
                isAvailableForDca: false, source: s.source, notes: "Split kolaterál \(loanId)", createdAt: now))
        }
    }

    static func release(db: DcaDatabase, loanId: String) throws {
        for var h in try db.holdingDao.getByLoanId(loanId) {
            h.isCollateralized = false
            h.loanId = nil
            try db.holdingDao.update(h)
        }
    }

    static func totalFree(db: DcaDatabase) throws -> Double {
        try db.holdingDao.getFree().reduce(0) { $0 + (Double($1.amount) ?? 0) }
    }
}
