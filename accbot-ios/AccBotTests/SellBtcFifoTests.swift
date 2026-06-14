import XCTest
@testable import AccBot

final class SellBtcFifoTests: XCTestCase {
    private func h(_ id: String, _ amt: String, _ acq: Double, _ price: String) -> HoldingRecord {
        HoldingRecord(id: id, amount: amt, acquisitionDate: acq, purchasePriceCzk: price,
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0)
    }

    func test_fifo_oldestFirst_taxesYoungGain() {
        let now = Date()
        let old = now.addingTimeInterval(-1200 * 86_400).timeIntervalSince1970   // >3 roky
        let young = now.addingTimeInterval(-100 * 86_400).timeIntervalSince1970   // <3 roky
        let holdings = [h("YOUNG", "1.0", young, "1000000"), h("OLD", "1.0", old, "1000000")]
        let allocs = SellBtcUseCase.fifoAllocate(holdings: holdings, sellAmount: 1.5,
            salePrice: 2_000_000, taxRate: 0.15, saleDate: now)
        XCTAssertEqual(allocs.count, 2)
        XCTAssertEqual(allocs[0].sourceHoldingId, "OLD")   // nejstarší first
        XCTAssertTrue(allocs[0].isExempt)
        XCTAssertEqual(Double(allocs[0].taxAmountCzk)!, 0, accuracy: 0.01)
        XCTAssertFalse(allocs[1].isExempt)                 // 0.5 z young
        XCTAssertEqual(Double(allocs[1].taxAmountCzk)!, 75_000, accuracy: 1)  // (2M−1M)·0.5·0.15
    }
}
