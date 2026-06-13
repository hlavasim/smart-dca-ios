# Plán 1 — NUPL strategie + bezpečná exekuce + catch-up

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Přidat do iOS appky NUPL DCA strategii (port 1:1 z C#), historickou NUPL sync, a idempotentní catch-up exekuci odolnou vůči timeoutům, aby denní nákup proběhl spolehlivě a nikdy ne dvakrát.

**Architecture:** Mirror existujícího vzoru `DailyPrice` pro novou tabulku `nupl_values` + `SyncNuplUseCase`. NUPL multiplikátor je **čistá funkce** (testovatelná C# vektory). Catch-up smyčka v `DcaExecutionEngine` projde zmeškané dny, každý se svým historickým NUPL, a používá novou tabulku `dca_executions` jako idempotency zámek (záznam **před** síťovým voláním; timeout = rekonciliace přes `tradeHistory`, ne naslepo retry).

**Tech Stack:** Swift / SwiftUI, GRDB (SQLite), XCTest. Projekt generuje xcodegen z `accbot-ios/project.yml`.

## ⚠️ Verifikace na CI (žádný Mac)

Swift nejde compilovat na Windows. **Každá verifikace = push na feature větev → GitHub Actions `ios-build.yml` (`xcodebuild test` na macos-14) → přečíst výsledek.** Proto je kadence **per-task** (ne per-step): napiš testy + implementaci tasku, pak jeden push a kontrola CI. Lokální `xcodebuild` kroky níže jsou referenční — reálně je spustí CI.

Pracovní větev: `feature/nupl-safe-execution`. Sledování CI: `gh run watch -R hlavasim/smart-dca-ios` nebo `gh run list -R hlavasim/smart-dca-ios --limit 3`.

## Soubory

```
accbot-ios/AccBot/
  Domain/Model/NuplConfig.swift                         (NEW — konfig + čistý multiplikátor)
  Domain/Model/DcaStrategy.swift                        (MODIFY — case .nupl)
  Domain/UseCase/CalculateStrategyMultiplierUseCase.swift (MODIFY — .nupl větev + pure func)
  Data/Local/Database/Records/NuplValueRecord.swift     (NEW)
  Data/Local/Database/Dao/NuplDao.swift                 (NEW)
  Data/Local/Database/Records/DcaExecutionRecord.swift  (NEW — idempotency)
  Data/Local/Database/Dao/DcaExecutionDao.swift         (NEW)
  Data/Local/Database/DcaDatabase.swift                 (MODIFY — v4+v5 migrace, DAO props)
  Data/Remote/MarketDataService.swift                   (MODIFY — getNuplHistory)
  Domain/UseCase/SyncNuplUseCase.swift                  (NEW)
  Domain/Model/AppDependencies.swift                    (MODIFY — wiring)
  Service/DcaExecutionEngine.swift                      (MODIFY — catch-up + idempotence)
accbot-ios/AccBotTests/
  NuplMultiplierTests.swift                             (NEW)
  NuplDaoTests.swift                                    (NEW)
  DcaExecutionIdempotencyTests.swift                    (NEW)
```

---

### Task 1: NUPL multiplikátor (čistá funkce) + konfig

**Files:**
- Create: `accbot-ios/AccBot/Domain/Model/NuplConfig.swift`
- Test: `accbot-ios/AccBotTests/NuplMultiplierTests.swift`

- [ ] **Step 1: Napiš padající test** (C# vektory z TuiDcaService.CalculateMultiplier)

`accbot-ios/AccBotTests/NuplMultiplierTests.swift`:
```swift
import XCTest
@testable import AccBot

final class NuplMultiplierTests: XCTestCase {
    let cfg = NuplConfig.default  // bottom 0.0, center 0.5, min 0.5, max 3.0

    func test_atBottom_returnsMax() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.0, config: cfg), 3.0, accuracy: 0.0001)
    }
    func test_belowBottom_clampsToMax() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: -0.1, config: cfg), 3.0, accuracy: 0.0001)
    }
    func test_quarter_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.25, config: cfg), 1.75, accuracy: 0.0001)
    }
    func test_tenth_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.10, config: cfg), 2.5, accuracy: 0.0001)
    }
    func test_fourtenths_interpolates() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.40, config: cfg), 1.0, accuracy: 0.0001)
    }
    func test_atCenter_returnsMin() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.5, config: cfg), 0.5, accuracy: 0.0001)
    }
    func test_aboveCenter_clampsToMin() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: 0.6, config: cfg), 0.5, accuracy: 0.0001)
    }
    func test_nilNupl_returnsFlat() {
        XCTAssertEqual(NuplConfig.multiplier(nupl: nil, config: cfg), 1.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Ověř fail** — Run (CI): `xcodebuild test ... -only-testing:AccBotTests/NuplMultiplierTests`. Expected: FAIL „cannot find 'NuplConfig'".

- [ ] **Step 3: Implementuj**

`accbot-ios/AccBot/Domain/Model/NuplConfig.swift`:
```swift
import Foundation

/// NUPL strategy configuration — port z C# settings.json (NuplBottomValue/Center/Min/MaxMultiplier).
struct NuplConfig: Codable, Equatable, Sendable {
    let bottomValue: Double   // NUPL ≤ bottom → maxMultiplier
    let centerValue: Double   // NUPL ≥ center → minMultiplier
    let minMultiplier: Float
    let maxMultiplier: Float

    static let `default` = NuplConfig(
        bottomValue: 0.0, centerValue: 0.5, minMultiplier: 0.5, maxMultiplier: 3.0
    )

    /// Čistá funkce — port z C# TuiDcaService.CalculateMultiplier.
    /// nil NUPL → 1.0 (fallback, jako C#).
    static func multiplier(nupl: Double?, config: NuplConfig) -> Float {
        guard let nupl else { return 1.0 }
        if nupl <= config.bottomValue { return config.maxMultiplier }
        if nupl >= config.centerValue { return config.minMultiplier }
        let range = config.centerValue - config.bottomValue
        let position = Float((nupl - config.bottomValue) / range)
        return config.maxMultiplier - position * (config.maxMultiplier - config.minMultiplier)
    }
}
```

- [ ] **Step 4: Ověř pass** — Run (CI): stejný příkaz. Expected: PASS (8 testů).

- [ ] **Step 5: Commit**
```bash
git add accbot-ios/AccBot/Domain/Model/NuplConfig.swift accbot-ios/AccBotTests/NuplMultiplierTests.swift
git commit -m "feat(nupl): pure NUPL multiplier (port z C#) + test vektory"
```

---

### Task 2: NUPL strategie v enumu + multiplier use case

**Files:**
- Modify: `accbot-ios/AccBot/Domain/Model/DcaStrategy.swift` (enum + dbString + fromDbString + allStrategies)
- Modify: `accbot-ios/AccBot/Domain/UseCase/CalculateStrategyMultiplierUseCase.swift`

- [ ] **Step 1: Přidej case do `DcaStrategy`** (`DcaStrategy.swift`)

Do enum (za `.fearAndGreed`):
```swift
    case nupl(config: NuplConfig = .default)
```
Do `displayName`: `case .nupl: return String(localized: "NUPL")`
Do `description`: `case .nupl: return String(localized: "Kupuj víc, když je NUPL nízko (trh u dna). Spojitá interpolace.")`
Do `dbString`: `case .nupl: return "NUPL"`
Do `fromDbString`: `case "NUPL": return .nupl()`
Do `allStrategies`: přidat `.nupl()`.

- [ ] **Step 2: Přidej .nupl větev do use case** (`CalculateStrategyMultiplierUseCase.swift`)

Do `switch strategy` v `invoke(...)`:
```swift
        case .nupl(let config):
            // Live cesta (dnešní den): NUPL z MarketDataService.
            let nupl = await marketDataService.getNuplToday()
            let mult = NuplConfig.multiplier(nupl: nupl, config: config)
            return StrategyMultiplierResult(
                multiplier: mult,
                reason: nupl.map { "NUPL \(String(format: "%.3f", $0)) → \(formatMultiplier(mult))" }
                    ?? "NUPL nedostupné, výchozí množství"
            )
```
> `getNuplToday()` přibyde v Tasku 3. (Per-day catch-up cesta nepoužívá tento use case, počítá multiplikátor z `NuplDao` přímo — Task 6.)

- [ ] **Step 3: Verifikace** — žádný nový test; build musí projít. Run (CI): `xcodebuild build`. Expected: zkompiluje (po Tasku 3, který dodá `getNuplToday`). **Tasky 2 a 3 commitni a pushni společně** (kruhová závislost build-time).

- [ ] **Step 4: Commit** (po Tasku 3 — viz tam).

---

### Task 3: NUPL data ze bitcoin-data.com + perzistence (`nupl_values`)

**Files:**
- Create: `accbot-ios/AccBot/Data/Local/Database/Records/NuplValueRecord.swift`
- Create: `accbot-ios/AccBot/Data/Local/Database/Dao/NuplDao.swift`
- Modify: `accbot-ios/AccBot/Data/Local/Database/DcaDatabase.swift` (v4 migrace + DAO prop)
- Modify: `accbot-ios/AccBot/Data/Remote/MarketDataService.swift` (getNuplHistory + getNuplToday)
- Test: `accbot-ios/AccBotTests/NuplDaoTests.swift`

- [ ] **Step 1: Record** (mirror `DailyPriceRecord`)

`NuplValueRecord.swift`:
```swift
import GRDB

struct NuplValueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "nupl_values"
    var dateEpochDay: Int64   // days since epoch (UTC)
    var nupl: String          // Decimal/Double jako string (přesnost, jako daily_prices.price)
    var fetchedAt: Double
}
```

- [ ] **Step 2: DAO** (mirror `DailyPriceDao`)

`NuplDao.swift`:
```swift
import GRDB
import Foundation

struct NuplDao {
    let dbPool: DatabasePool

    /// epoch day (UTC) pro daný Date
    static func epochDay(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    func get(dateEpochDay: Int64) throws -> Double? {
        try dbPool.read { db in
            guard let r = try NuplValueRecord
                .filter(Column("dateEpochDay") == dateEpochDay)
                .fetchOne(db) else { return nil }
            return Double(r.nupl)
        }
    }

    func getLatestDay() throws -> Int64? {
        try dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(dateEpochDay) FROM nupl_values")
        }
    }

    func getEarliestDay() throws -> Int64? {
        try dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT MIN(dateEpochDay) FROM nupl_values")
        }
    }

    func insertBatch(_ rows: [(day: Int64, nupl: Double)]) throws {
        try dbPool.write { db in
            let now = Date().timeIntervalSince1970
            for row in rows {
                try NuplValueRecord(dateEpochDay: row.day, nupl: String(row.nupl), fetchedAt: now)
                    .insert(db, onConflict: .replace)
            }
        }
    }

    func count() throws -> Int {
        try dbPool.read { db in try NuplValueRecord.fetchCount(db) }
    }
}
```

- [ ] **Step 3: Migrace v4 + DAO prop** (`DcaDatabase.swift`)

Do `runMigrations(...)` za v3:
```swift
    migrator.registerMigration("v4_nupl_values") { db in
        try db.create(table: "nupl_values") { t in
            t.column("dateEpochDay", .integer).notNull().primaryKey()
            t.column("nupl", .text).notNull()
            t.column("fetchedAt", .double).notNull()
        }
    }
```
Přidej property `let nuplDao: NuplDao` (k ostatním DAO) a v `init` za `dailyPriceDao = ...`:
```swift
        nuplDao = NuplDao(dbPool: dbPool)
```

- [ ] **Step 4: NUPL fetch v MarketDataService** (`MarketDataService.swift`)

Přidej do `actor MarketDataService`:
```swift
    private let bitcoinDataNuplUrl = "https://bitcoin-data.com/v1/nupl"

    /// Stáhne celou NUPL historii z bitcoin-data.com.
    /// Formát: [{ "d": "yyyy-MM-dd", "unixTs": <int>, "nupl": <number|string> }]
    func getNuplHistory() async -> [(day: Int64, nupl: Double)]? {
        do {
            let (data, _) = try await client.get(url: bitcoinDataNuplUrl)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return arr.compactMap { row -> (day: Int64, nupl: Double)? in
                guard let dStr = row["d"] as? String, let date = fmt.date(from: dStr) else { return nil }
                let nupl: Double?
                if let n = row["nupl"] as? NSNumber { nupl = n.doubleValue }
                else if let s = row["nupl"] as? String { nupl = Double(s) }
                else { nupl = nil }
                guard let nuplVal = nupl else { return nil }
                return (day: Int64((date.timeIntervalSince1970 / 86_400).rounded(.down)), nupl: nuplVal)
            }
        } catch {
            return nil
        }
    }

    /// NUPL pro dnešní den (nebo nejbližší dostupný) — live cesta strategie.
    func getNuplToday() async -> Double? {
        guard let history = await getNuplHistory(), !history.isEmpty else { return nil }
        return history.max(by: { $0.day < $1.day })?.nupl
    }
```

- [ ] **Step 5: Test DAO** (`NuplDaoTests.swift`) — in-memory DB
```swift
import XCTest
import GRDB
@testable import AccBot

final class NuplDaoTests: XCTestCase {
    func test_insertAndGet_byDay() throws {
        let db = try DcaDatabase(path: nil)  // :memory:
        let day = NuplDao.epochDay(Date(timeIntervalSince1970: 1_770_000_000))
        try db.nuplDao.insertBatch([(day: day, nupl: 0.137)])
        XCTAssertEqual(try db.nuplDao.get(dateEpochDay: day), 0.137, accuracy: 0.0001)
        XCTAssertEqual(try db.nuplDao.getLatestDay(), day)
        XCTAssertEqual(try db.nuplDao.count(), 1)
    }
    func test_insertBatch_replacesOnConflict() throws {
        let db = try DcaDatabase(path: nil)
        let day = NuplDao.epochDay(Date())
        try db.nuplDao.insertBatch([(day: day, nupl: 0.2)])
        try db.nuplDao.insertBatch([(day: day, nupl: 0.3)])
        XCTAssertEqual(try db.nuplDao.get(dateEpochDay: day), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try db.nuplDao.count(), 1)
    }
}
```

- [ ] **Step 6: Ověř + Commit (Tasky 2+3 dohromady)** — Run (CI): `xcodebuild test`. Expected: PASS (vč. NuplDaoTests + NuplMultiplierTests, build zelený).
```bash
git add accbot-ios/AccBot/Domain/Model/DcaStrategy.swift \
        accbot-ios/AccBot/Domain/UseCase/CalculateStrategyMultiplierUseCase.swift \
        accbot-ios/AccBot/Data/Local/Database/Records/NuplValueRecord.swift \
        accbot-ios/AccBot/Data/Local/Database/Dao/NuplDao.swift \
        accbot-ios/AccBot/Data/Local/Database/DcaDatabase.swift \
        accbot-ios/AccBot/Data/Remote/MarketDataService.swift \
        accbot-ios/AccBotTests/NuplDaoTests.swift
git commit -m "feat(nupl): .nupl strategie + nupl_values tabulka + bitcoin-data.com fetch"
```

---

### Task 4: SyncNuplUseCase + wiring

**Files:**
- Create: `accbot-ios/AccBot/Domain/UseCase/SyncNuplUseCase.swift`
- Modify: `accbot-ios/AccBot/Domain/Model/AppDependencies.swift`

- [ ] **Step 1: Use case** (mirror `SyncDailyPricesUseCase` — stáhne historii, uloží do `nupl_values`)

`SyncNuplUseCase.swift`:
```swift
import Foundation
import os

/// Stáhne NUPL historii z bitcoin-data.com a uloží do nupl_values.
/// Idempotentní (insert .replace). Vrací počet uložených řádků.
final class SyncNuplUseCase {
    private let nuplDao: NuplDao
    private let marketDataService: MarketDataService
    private let logger = Logger(subsystem: "com.accbot.dca", category: "SyncNupl")

    init(nuplDao: NuplDao, marketDataService: MarketDataService) {
        self.nuplDao = nuplDao
        self.marketDataService = marketDataService
    }

    @discardableResult
    func sync() async -> Int {
        guard let history = await marketDataService.getNuplHistory(), !history.isEmpty else {
            logger.warning("NUPL history unavailable")
            return 0
        }
        do {
            try nuplDao.insertBatch(history)
            logger.info("Synced \(history.count) NUPL values")
            return history.count
        } catch {
            logger.error("Failed to persist NUPL: \(error.localizedDescription)")
            return 0
        }
    }
}
```

- [ ] **Step 2: Wiring** (`AppDependencies.swift`)

Přidej property `let syncNuplUseCase: SyncNuplUseCase` a v `init()` za `marketDataService` instanci:
```swift
        let syncNuplUseCase = SyncNuplUseCase(nuplDao: database.nuplDao, marketDataService: marketDataService)
```
a přiřazení `self.syncNuplUseCase = syncNuplUseCase`.
> Pozn.: sandbox DB sdílí stejnou NUPL historii — pro Phase 1 stačí prod `database.nuplDao` (NUPL je globální, ne per-účet).

Zavolej `sync()` při startu/refresh tam, kde se volá `SyncDailyPricesUseCase.sync()` (najdi v `AppDependencies`/app lifecycle a přidej vedle).

- [ ] **Step 3: Ověř + Commit** — Run (CI): `xcodebuild build` (žádný nový test). Expected: zkompiluje.
```bash
git add accbot-ios/AccBot/Domain/UseCase/SyncNuplUseCase.swift accbot-ios/AccBot/Domain/Model/AppDependencies.swift
git commit -m "feat(nupl): SyncNuplUseCase + wiring (NUPL historie do DB)"
```

---

### Task 5: Idempotency tabulka `dca_executions`

**Files:**
- Create: `accbot-ios/AccBot/Data/Local/Database/Records/DcaExecutionRecord.swift`
- Create: `accbot-ios/AccBot/Data/Local/Database/Dao/DcaExecutionDao.swift`
- Modify: `accbot-ios/AccBot/Data/Local/Database/DcaDatabase.swift` (v5 migrace + DAO prop)
- Test: `accbot-ios/AccBotTests/DcaExecutionIdempotencyTests.swift` (DAO část)

- [ ] **Step 1: Record**

`DcaExecutionRecord.swift`:
```swift
import GRDB

/// Idempotency zámek: jeden záznam na (planId, dayEpoch). Zapsán PŘED nákupem.
struct DcaExecutionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "dca_executions"
    var planId: Int64
    var dayEpoch: Int64
    var status: String          // "pending" | "completed" | "failed"
    var exchangeOrderId: String?
    var createdAt: Double
    var updatedAt: Double
}
```

- [ ] **Step 2: DAO**

`DcaExecutionDao.swift`:
```swift
import GRDB
import Foundation

struct DcaExecutionDao {
    let dbPool: DatabasePool

    enum Status: String { case pending, completed, failed }

    func get(planId: Int64, dayEpoch: Int64) throws -> DcaExecutionRecord? {
        try dbPool.read { db in
            try DcaExecutionRecord
                .filter(Column("planId") == planId && Column("dayEpoch") == dayEpoch)
                .fetchOne(db)
        }
    }

    /// Vloží pending zámek. Vrací false, pokud už záznam existuje (= nekupovat znovu).
    func tryClaim(planId: Int64, dayEpoch: Int64) throws -> Bool {
        try dbPool.write { db in
            if try DcaExecutionRecord
                .filter(Column("planId") == planId && Column("dayEpoch") == dayEpoch)
                .fetchCount(db) > 0 { return false }
            let now = Date().timeIntervalSince1970
            try DcaExecutionRecord(planId: planId, dayEpoch: dayEpoch,
                status: Status.pending.rawValue, exchangeOrderId: nil,
                createdAt: now, updatedAt: now).insert(db)
            return true
        }
    }

    func mark(planId: Int64, dayEpoch: Int64, status: Status, orderId: String?) throws {
        try dbPool.write { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: """
                UPDATE dca_executions SET status = ?, exchangeOrderId = ?, updatedAt = ?
                WHERE planId = ? AND dayEpoch = ?
                """, arguments: [status.rawValue, orderId, now, planId, dayEpoch])
        }
    }
}
```

- [ ] **Step 3: Migrace v5 + DAO prop** (`DcaDatabase.swift`)
```swift
    migrator.registerMigration("v5_dca_executions") { db in
        try db.create(table: "dca_executions") { t in
            t.column("planId", .integer).notNull()
            t.column("dayEpoch", .integer).notNull()
            t.column("status", .text).notNull()
            t.column("exchangeOrderId", .text)
            t.column("createdAt", .double).notNull()
            t.column("updatedAt", .double).notNull()
            t.primaryKey(["planId", "dayEpoch"])
        }
    }
```
Property `let dcaExecutionDao: DcaExecutionDao` + v `init`: `dcaExecutionDao = DcaExecutionDao(dbPool: dbPool)`.

- [ ] **Step 4: Test** (`DcaExecutionIdempotencyTests.swift`)
```swift
import XCTest
@testable import AccBot

final class DcaExecutionIdempotencyTests: XCTestCase {
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
}
```

- [ ] **Step 5: Ověř + Commit** — Run (CI): `xcodebuild test -only-testing:AccBotTests/DcaExecutionIdempotencyTests`. Expected: PASS.
```bash
git add accbot-ios/AccBot/Data/Local/Database/Records/DcaExecutionRecord.swift \
        accbot-ios/AccBot/Data/Local/Database/Dao/DcaExecutionDao.swift \
        accbot-ios/AccBot/Data/Local/Database/DcaDatabase.swift \
        accbot-ios/AccBotTests/DcaExecutionIdempotencyTests.swift
git commit -m "feat(safety): dca_executions idempotency tabulka + DAO"
```

---

### Task 6: Catch-up smyčka v `DcaExecutionEngine` (per-day NUPL + idempotence + timeout reconciliation)

> Jádro bezpečnosti (spec sekce G). Nahrazuje single-buy chování pro `.nupl` strategii catch-up smyčkou přes zmeškané dny.

**Files:**
- Modify: `accbot-ios/AccBot/Service/DcaExecutionEngine.swift`

- [ ] **Step 1: Přidej závislosti do enginu**

V `DcaExecutionEngine` přidej property a do `init` parametry:
```swift
    private let nuplDao: NuplDao
    private let dcaExecutionDao: DcaExecutionDao
    private let maxCatchupDays = 30   // strop zmeškaných dnů na jeden běh
```
init dostane `nuplDao: NuplDao, dcaExecutionDao: DcaExecutionDao` (předej `database.nuplDao` / `database.dcaExecutionDao` z `AppDependencies`). Pozn.: idempotency + NUPL jsou globální → použij prod `database` instance, ne `activeDb`.

- [ ] **Step 2: Catch-up větev v `executePlan`**

Na začátku `executePlan(_ plan:forceRun:)`, hned po získání credentials a před single-buy logikou, odboč pro NUPL strategii:
```swift
        if case .nupl(let config) = plan.strategy, !forceRun {
            await runNuplCatchup(plan: plan, config: config, credentials: credentials, api: exchangeApiFactory.create(credentials: credentials), now: now)
            return
        }
```

- [ ] **Step 3: Implementuj `runNuplCatchup`** (idempotentní, timeout-safe, bounded)
```swift
    private func runNuplCatchup(plan: DcaPlan, config: NuplConfig, credentials: ExchangeCredentials, api: ExchangeApi, now: Date) async {
        // Zmeškané dny: od (lastExecutedAt+1) do dnes, max maxCatchupDays.
        let todayEpoch = NuplDao.epochDay(now)
        let lastEpoch = plan.lastExecutedAt.map { NuplDao.epochDay($0) } ?? (todayEpoch - 1)
        let firstDay = max(lastEpoch + 1, todayEpoch - Int64(maxCatchupDays) + 1)
        guard firstDay <= todayEpoch else { return }

        for day in firstDay...todayEpoch {
            // 1) Idempotency: pokud už completed, přeskoč.
            if let rec = try? dcaExecutionDao.get(planId: plan.id, dayEpoch: day), rec.status == "completed" {
                continue
            }
            // 2) Pending z minula → rekonciliace, ne naslepo retry.
            if let rec = try? dcaExecutionDao.get(planId: plan.id, dayEpoch: day),
               rec.status == "pending", let orderId = rec.exchangeOrderId {
                if await reconcile(orderId: orderId, plan: plan, api: api, day: day) { continue }
                else { break }  // neznámý výsledek → nepokračuj, zkus příště
            }
            // 3) Claim zámku PŘED nákupem.
            guard (try? dcaExecutionDao.tryClaim(planId: plan.id, dayEpoch: day)) == true else { continue }

            // 4) Multiplikátor z historického NUPL daného dne.
            let nupl = try? nuplDao.get(dateEpochDay: day)
            let multiplier = NuplConfig.multiplier(nupl: nupl ?? nil, config: config)
            let amount = roundDecimal(plan.amount * Decimal(Double(multiplier)), scale: 2)

            let minOrderSize = MinOrderSizeRepository.getMinOrderSize(exchange: plan.exchange, fiat: plan.fiat)
            if amount < minOrderSize {
                try? dcaExecutionDao.mark(planId: plan.id, dayEpoch: day, status: .failed, orderId: nil)
                continue
            }

            // 5) Nákup s timeoutem.
            let result = await withTimeout(seconds: 30) {
                await api.marketBuy(crypto: plan.crypto, fiat: plan.fiat, fiatAmount: amount)
            }

            switch result {
            case .some(.success(let tx)):
                let saved = Transaction(
                    planId: plan.id, exchange: plan.exchange, crypto: plan.crypto, fiat: plan.fiat,
                    fiatAmount: tx.fiatAmount, cryptoAmount: tx.cryptoAmount, price: tx.price,
                    fee: tx.fee, feeAsset: tx.feeAsset, status: tx.status, exchangeOrderId: tx.exchangeOrderId
                )
                try? activeDb.transactionDao.insert(saved)
                try? dcaExecutionDao.mark(planId: plan.id, dayEpoch: day,
                    status: tx.status == .pending ? .pending : .completed, orderId: tx.exchangeOrderId)
                // Postup lastExecutedAt jen po potvrzeném dni.
                try? activeDb.planDao.updateExecution(id: plan.id,
                    lastExecutedAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200),
                    nextExecutionAt: calculateNextExecution(plan: plan, from: now))
                if tx.status == .pending { break }  // neznámé → nepokračuj dál
            case .some(.error(_, _)), .none:
                // Timeout/chyba = NEZNÁMÝ výsledek → zůstává pending, NEPOKRAČUJ (žádný re-buy naslepo).
                // orderId neznáme (marketBuy nedoběhl), zámek zůstane pending pro příští rekonciliaci.
                return
            }
        }
    }

    /// Rekonciliace: ověř přes tradeHistory, jestli order proběhl. true = vyřešeno (completed), false = neznámé.
    private func reconcile(orderId: String, plan: DcaPlan, api: ExchangeApi, day: Int64) async -> Bool {
        guard let resolved = await api.getOrderStatus(orderId: orderId) else { return false }
        let saved = Transaction(
            planId: plan.id, exchange: plan.exchange, crypto: plan.crypto, fiat: plan.fiat,
            fiatAmount: resolved.fiatAmount, cryptoAmount: resolved.cryptoAmount, price: resolved.price,
            fee: resolved.fee, feeAsset: resolved.feeAsset, status: resolved.status, exchangeOrderId: orderId
        )
        try? activeDb.transactionDao.insert(saved)
        try? dcaExecutionDao.mark(planId: plan.id, dayEpoch: day, status: .completed, orderId: orderId)
        return true
    }
```
> Pozn.: `withTimeout`, `roundDecimal`, `calculateNextExecution`, `activeDb` už v enginu existují (viz DcaExecutionEngine.swift:264-405).

- [ ] **Step 4: Ověř build** — Run (CI): `xcodebuild build`. Expected: zkompiluje. (Integrace se testuje v Tasku 7.)

- [ ] **Step 5: Commit**
```bash
git add accbot-ios/AccBot/Service/DcaExecutionEngine.swift accbot-ios/AccBot/Domain/Model/AppDependencies.swift
git commit -m "feat(safety): NUPL catch-up smyčka — per-day NUPL, idempotence, timeout rekonciliace"
```

---

### Task 7: Bezpečnostní testy exekuce (idempotence + timeout)

> Testuje, že catch-up nikdy nenakoupí dvakrát a že timeout nevede k druhému orderu. Vyžaduje fake `ExchangeApi`.

**Files:**
- Modify: `accbot-ios/AccBotTests/DcaExecutionIdempotencyTests.swift` (přidat integrační testy s fake API)

- [ ] **Step 1: Fake ExchangeApi + počítadlo nákupů**

Do testu přidej fake, který počítá `marketBuy` volání a umí simulovat timeout (vrátí po >30s, resp. testovatelně přes flag):
```swift
final class CountingApi: ExchangeApi {
    private(set) var buyCount = 0
    var simulateTimeout = false
    func marketBuy(crypto: String, fiat: String, fiatAmount: Decimal) async -> DcaResult {
        buyCount += 1
        if simulateTimeout {
            try? await Task.sleep(nanoseconds: 35 * 1_000_000_000) // > 30s timeout
            return .error(message: "late", retryable: true)
        }
        return .success(Transaction(planId: 0, exchange: .coinmate, crypto: crypto, fiat: fiat,
            fiatAmount: fiatAmount, cryptoAmount: 0.0001, price: 1_000_000, fee: 0,
            feeAsset: fiat, status: .completed, exchangeOrderId: "OID-\(buyCount)"))
    }
    // ostatní metody ExchangeApi: minimální stuby (getBalance → nil, getOrderStatus → nil, atd.)
}
```
> Implementuj všechny členy protokolu `ExchangeApi` jako no-op stuby (viz `Exchange/ExchangeApi.swift` pro signatury).

- [ ] **Step 2: Test — re-run catch-upu přes N dnů = přesně N nákupů**
```swift
func test_catchup_isIdempotent_acrossReruns() async throws {
    // 3 zmeškané dny → první běh 3 nákupy, druhý běh 0 (vše completed).
    // (Engine sestav s in-memory DB, CountingApi přes fake ExchangeApiFactory,
    //  plan.lastExecutedAt = dnes-3 dny, strategy = .nupl.)
    // ... arrange (sestavení enginu s fake factory) ...
    await engine.executePlan(planId)         // 1. běh
    XCTAssertEqual(api.buyCount, 3)
    await engine.executePlan(planId)         // 2. běh — nic nového
    XCTAssertEqual(api.buyCount, 3)          // pořád 3, žádný duplicitní nákup
}
```

- [ ] **Step 3: Test — timeout nevytvoří druhý order**
```swift
func test_timeout_doesNotDoubleBuy() async throws {
    api.simulateTimeout = true
    await engine.executePlan(planId)         // den 1 timeout → pending, smyčka se zastaví
    let firstCount = api.buyCount
    await engine.executePlan(planId)         // další běh: pending se rekonciliuje (getOrderStatus → nil → neznámé), žádný nový buy naslepo
    XCTAssertEqual(api.buyCount, firstCount) // žádné zdvojení
}
```
> Pozn.: arrange (sestavení `DcaExecutionEngine` s fake `ExchangeApiFactory` vracejícím `CountingApi`, in-memory `DcaDatabase`, plán s `.nupl` a `lastExecutedAt`) je shodný v obou testech — vytáhni do `makeEngine()` helperu. `ExchangeApiFactory` je `final class`; pro test buď přidej protokol/override, nebo inject přímo `ExchangeApi` (drobný refactor enginu — preferuj inject API factory přes closure).

- [ ] **Step 4: Ověř + Commit** — Run (CI): `xcodebuild test -only-testing:AccBotTests/DcaExecutionIdempotencyTests`. Expected: PASS.
```bash
git add accbot-ios/AccBotTests/DcaExecutionIdempotencyTests.swift accbot-ios/AccBot/Service/DcaExecutionEngine.swift
git commit -m "test(safety): catch-up idempotence + timeout nevytvoří druhý order"
```

---

## Self-review (spec coverage Plánu 1)

- **A. NUPL strategie** → Task 1 (multiplikátor), Task 2 (enum + use case), Task 3 (data). ✓
- **NUPL historie / per-day catch-up** → Task 3 (`nupl_values`), Task 4 (sync), Task 6 (per-day lookup). ✓
- **Refresh cash před nákupem** → v iOS odpadá: cash je vždy živá z burzy (CoinMate odmítne nedostatečný zůstatek), žádný stale-cash stav jako v C#. Dokumentováno, neportuje se. ✓
- **G. Idempotence buy orderů** → Task 5 (`dca_executions`) + Task 6 (tryClaim před nákupem). ✓
- **G. Timeout = rekonciliace, ne re-buy** → Task 6 (`reconcile`, return on timeout) + Task 7 (test). ✓
- **G. Postup jen po potvrzení** → Task 6 (`updateExecution` jen v `.success`). ✓
- **G. Omezený catch-up** → Task 6 (`maxCatchupDays = 30`). ✓
- **G. Cena nikdy /1** → zachováno z `2015c3a` (CoinmateApi.swift:67-81), neměníme. ✓

## Otevřené body (předané z plánu)

- `ExchangeApiFactory` refactor pro injektovatelnost ve fake testu (Task 7 Step 3) — drobný, preferuj closure inject.
- Volání `SyncNuplUseCase.sync()` v app lifecycle — najít místo vedle `SyncDailyPricesUseCase.sync()`.
- Throttle „skip executeDuePlans <5 min" (z `2015c3a`) ověřit, že platí i pro NUPL větev (měl by, je v `executeDuePlans`).
