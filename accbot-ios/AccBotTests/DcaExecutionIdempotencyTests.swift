import XCTest
@testable import AccBot

/// Fake ExchangeApi: počítá marketBuy volání, umí simulovat timeout.
final class CountingApi: ExchangeApi {
    let exchange: Exchange = .coinmate
    private(set) var buyCount = 0
    var simulateTimeout = false

    func marketBuy(crypto: String, fiat: String, fiatAmount: Decimal) async -> DcaResult {
        buyCount += 1
        if simulateTimeout {
            try? await Task.sleep(nanoseconds: 31 * 1_000_000_000) // > 30s timeout
            return .error(message: "late", retryable: true)
        }
        return .success(Transaction(
            planId: 0, exchange: .coinmate, crypto: crypto, fiat: fiat,
            fiatAmount: fiatAmount, cryptoAmount: 0.0001, price: 1_000_000, fee: 0,
            feeAsset: fiat, status: .completed, exchangeOrderId: "OID-\(buyCount)"))
    }
    func getBalance(currency: String) async -> Decimal? { nil }
    func getCurrentPrice(crypto: String, fiat: String) async -> Decimal? { 1_000_000 }
    func withdraw(crypto: String, amount: Decimal, address: String) async throws -> String { "" }
    func getWithdrawalFee(crypto: String) async -> Decimal? { nil }
    func validateCredentials() async throws -> Bool { true }
}

final class DcaExecutionIdempotencyTests: XCTestCase {

    // MARK: - DAO

    func test_tryClaim_secondCallReturnsFalse() throws {
        let db = try DcaDatabase(path: nil)
        XCTAssertTrue(try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100))
        XCTAssertFalse(try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100))
    }

    func test_mark_updatesStatusAndOrderId() throws {
        let db = try DcaDatabase(path: nil)
        _ = try db.dcaExecutionDao.tryClaim(planId: 1, dayEpoch: 100)
        try db.dcaExecutionDao.mark(planId: 1, dayEpoch: 100, status: .completed, orderId: "OID-9")
        let rec = try db.dcaExecutionDao.get(planId: 1, dayEpoch: 100)
        XCTAssertEqual(rec?.status, "completed")
        XCTAssertEqual(rec?.exchangeOrderId, "OID-9")
    }

    // MARK: - Catch-up integrace

    private func makeEngine() throws -> DcaExecutionEngine {
        let db = try DcaDatabase(path: nil)
        let sandbox = try DcaDatabase(path: nil)
        let prefs = UserPreferences(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)") ?? .standard)
        let net = NetworkClient()
        return DcaExecutionEngine(
            database: db, sandboxDatabase: sandbox,
            credentialsStore: CredentialsStore(),
            userPreferences: prefs,
            exchangeApiFactory: ExchangeApiFactory(userPreferences: prefs, networkClient: net),
            notificationService: NotificationService(),
            marketDataService: MarketDataService(client: net)
        )
    }

    private func nuplPlan(daysAgo: Int) -> DcaPlan {
        let last = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return DcaPlan(id: 1, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            amount: 10_000, frequency: .daily, strategy: .nupl(), lastExecutedAt: last)
    }

    func test_catchup_isIdempotent_acrossReruns() async throws {
        let engine = try makeEngine()
        let api = CountingApi()
        let plan = nuplPlan(daysAgo: 3)   // 3 zmeškané dny
        await engine.runNuplCatchup(plan: plan, config: .default, api: api, now: Date())
        XCTAssertEqual(api.buyCount, 3)
        await engine.runNuplCatchup(plan: plan, config: .default, api: api, now: Date())
        XCTAssertEqual(api.buyCount, 3) // re-run nenakoupí znovu (dca_executions completed)
    }

    func test_timeout_doesNotDoubleBuy() async throws {
        let engine = try makeEngine()
        let api = CountingApi()
        api.simulateTimeout = true
        let plan = nuplPlan(daysAgo: 3)
        await engine.runNuplCatchup(plan: plan, config: .default, api: api, now: Date())
        let firstCount = api.buyCount
        await engine.runNuplCatchup(plan: plan, config: .default, api: api, now: Date())
        XCTAssertEqual(api.buyCount, firstCount) // pending bez orderId → žádný nový buy naslepo
    }
}
