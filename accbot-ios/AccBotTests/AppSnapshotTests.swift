import XCTest
@testable import AccBot

final class AppSnapshotTests: XCTestCase {
    func test_encodeDecode_roundTrip() throws {
        let snap = AppSnapshot(
            version: 1, exportedAt: "2026-06-13T21:00:00Z", fiat: "CZK",
            strategy: .init(type: "NUPL", nuplBottomValue: 0, nuplCenterValue: 0.5,
                nuplMinMultiplier: 0.5, nuplMaxMultiplier: 3.0, baseChunkCzk: "2308.36",
                baseChunkMultiplier: "0.8", lastProcessedDate: "2026-06-09", availableCashCzk: "3984.23"),
            holdings: [.init(id: "h1", amount: "0.5", acquisitionDate: "2021-04-21",
                purchasePriceCzk: "0", isCollateralized: false, loanId: nil, source: "Initial", notes: "")],
            transactions: [.init(date: "2026-06-05", type: "DCA_PURCHASE", amountBtc: "0.0123",
                amountCzk: "-16100", btcPriceCzk: "1310069", exchangeOrderId: "OID")],
            firefishLoans: [], bankLoans: [])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(AppSnapshot.self, from: data)
        XCTAssertEqual(snap, back)
    }
}
