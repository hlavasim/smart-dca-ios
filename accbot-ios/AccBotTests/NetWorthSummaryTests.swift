import XCTest
@testable import AccBot

@MainActor
final class NetWorthSummaryTests: XCTestCase {
    func test_netWorth_debt_and_ltv() throws {
        let s = DashboardViewModel.NetWorthSummary(
            heldBtc: Decimal(string: "5.42161425")!,
            btcPriceCzk: Decimal(string: "1844579")!,
            btcValueCzk: 10_000_000,
            firefishDebtCzk: 800_000,
            bankDebtCzk: 681_947,
            firefishLoanCount: 4,
            bankLoanCount: 1)

        XCTAssertEqual(s.totalDebtCzk, 1_481_947)
        XCTAssertEqual(s.netWorthCzk, 8_518_053)
        XCTAssertEqual(try XCTUnwrap(s.ltvPercent), 14.81947, accuracy: 0.001)
    }

    func test_underwater_netWorth_negative() {
        let s = DashboardViewModel.NetWorthSummary(
            heldBtc: 1, btcPriceCzk: 1_000_000, btcValueCzk: 1_000_000,
            firefishDebtCzk: 1_500_000, bankDebtCzk: 0,
            firefishLoanCount: 1, bankLoanCount: 0)

        XCTAssertEqual(s.netWorthCzk, -500_000)
        XCTAssertEqual(try XCTUnwrap(s.ltvPercent), 150, accuracy: 0.001)
    }

    func test_noPrice_valueAndNetWorthNil() {
        let s = DashboardViewModel.NetWorthSummary(
            heldBtc: 1, btcPriceCzk: nil, btcValueCzk: nil,
            firefishDebtCzk: 800_000, bankDebtCzk: 0,
            firefishLoanCount: 4, bankLoanCount: 0)

        XCTAssertNil(s.netWorthCzk)
        XCTAssertNil(s.ltvPercent)
        XCTAssertEqual(s.totalDebtCzk, 800_000)
    }
}
