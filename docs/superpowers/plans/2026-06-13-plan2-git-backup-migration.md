# Plán 2 — Git záloha/obnova + konverzní skript (migrace z C#)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Automatická git záloha plného stavu appky do private repa (potvrzený push) + obnova na novém zařízení, a jednorázová migrace dat z C# bota přes konverzní skript. Import = obnova (jedna vstupní cesta).

**Architecture:** `AppSnapshot` (Codable) zrcadlí DB tabulky. `SnapshotService` staví snapshot z DAO a nahrává zpět. `GitHubBackupService` čte/zapisuje `snapshot.json` přes GitHub Contents API (PAT z Keychain). Konverzní skript (Python) čte C# JSON a vyrobí `snapshot.json` ve stejném formátu → migrace = obnova z gitu.

**Tech Stack:** Swift / GRDB / XCTest; Python 3 (konverzní skript); GitHub Contents API.

**Předpoklad:** Plán 1 hotový (NUPL strategie, `dca_executions`). Migrace zavádí **holdings tabulku** (iOS dnes holdingy odvozuje z transakcí; C# má explicitní holdingy s `acquisitionDate`, nutné pro daně v Plánu 3).

## ⚠️ Verifikace na CI (žádný Mac) — viz Plán 1. Kadence per-task. Konverzní skript (Python) jde otestovat lokálně na Windows.

Pracovní větev: `feature/git-backup-migration` (po mergi Plánu 1).

## Soubory

```
accbot-ios/AccBot/
  Data/Local/Database/Records/HoldingRecord.swift        (NEW)
  Data/Local/Database/Dao/HoldingDao.swift               (NEW)
  Data/Local/Database/DcaDatabase.swift                  (MODIFY — v6 holdings)
  Domain/Model/AppSnapshot.swift                         (NEW — Codable snapshot)
  Domain/UseCase/SnapshotService.swift                   (NEW — build/load)
  Data/Remote/GitHubBackupService.swift                  (NEW — Contents API)
  Data/Local/TokenStore.swift                            (NEW — PAT v Keychain)
  Exchange/NetworkClient.swift                           (MODIFY — put())
  Domain/Model/AppDependencies.swift                     (MODIFY — wiring)
  Service/DcaExecutionEngine.swift                       (MODIFY — backup po nákupu)
tools/migrate-csharp/
  convert.py                                             (NEW — C# JSON → snapshot.json)
  test_convert.py                                        (NEW — golden test)
  sample/ (fixtures)                                     (NEW)
accbot-ios/AccBotTests/
  AppSnapshotTests.swift                                 (NEW)
  SnapshotServiceTests.swift                             (NEW)
```

---

### Task 1: Holdings tabulka

**Files:** Create `HoldingRecord.swift`, `HoldingDao.swift`; Modify `DcaDatabase.swift`.

- [ ] **Step 1: Record**
```swift
import GRDB
struct HoldingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "holdings"
    var id: String                 // UUID z C# (zachová identitu)
    var amount: String             // Decimal jako string
    var acquisitionDate: Double    // timeIntervalSince1970
    var purchasePriceCzk: String
    var isCollateralized: Bool
    var loanId: String?            // FF loan externalId (Phase 3)
    var isAvailableForDca: Bool
    var source: String             // "Initial" | "DCA" | "CoinMate-Deposit"
    var notes: String
    var createdAt: Double
}
```
- [ ] **Step 2: DAO**
```swift
import GRDB
import Foundation
struct HoldingDao {
    let dbPool: DatabasePool
    func getAll() throws -> [HoldingRecord] {
        try dbPool.read { try HoldingRecord.fetchAll($0) }
    }
    func upsert(_ r: HoldingRecord) throws {
        try dbPool.write { try r.insert($0, onConflict: .replace) }
    }
    func upsertBatch(_ rows: [HoldingRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.insert(db, onConflict: .replace) } }
    }
    func deleteAll() throws { try dbPool.write { try HoldingRecord.deleteAll($0) } }
    func totalAmount() throws -> Decimal {
        try getAll().reduce(Decimal(0)) { $0 + (Decimal(string: $1.amount) ?? 0) }
    }
}
```
- [ ] **Step 3: Migrace v6 + DAO prop** (`DcaDatabase.swift`)
```swift
    migrator.registerMigration("v6_holdings") { db in
        try db.create(table: "holdings") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("amount", .text).notNull()
            t.column("acquisitionDate", .double).notNull()
            t.column("purchasePriceCzk", .text).notNull()
            t.column("isCollateralized", .boolean).notNull().defaults(to: false)
            t.column("loanId", .text)
            t.column("isAvailableForDca", .boolean).notNull().defaults(to: true)
            t.column("source", .text).notNull()
            t.column("notes", .text).notNull().defaults(to: "")
            t.column("createdAt", .double).notNull()
        }
        try db.create(index: "idx_holdings_acq", on: "holdings", columns: ["acquisitionDate"])
    }
```
Property `let holdingDao: HoldingDao` + init `holdingDao = HoldingDao(dbPool: dbPool)`.

- [ ] **Step 4: Test** (`AccBotTests/HoldingDaoTests.swift`)
```swift
import XCTest
@testable import AccBot
final class HoldingDaoTests: XCTestCase {
    func test_upsert_replacesById() throws {
        let db = try DcaDatabase(path: nil)
        let r = HoldingRecord(id: "h1", amount: "0.5", acquisitionDate: 1_600_000_000,
            purchasePriceCzk: "0", isCollateralized: false, loanId: nil,
            isAvailableForDca: true, source: "Initial", notes: "", createdAt: 0)
        try db.holdingDao.upsert(r)
        try db.holdingDao.upsert({ var x = r; x.amount = "0.7"; return x }())
        XCTAssertEqual(try db.holdingDao.getAll().count, 1)
        XCTAssertEqual(try db.holdingDao.totalAmount(), Decimal(string: "0.7"))
    }
}
```
- [ ] **Step 5: Ověř (CI) + Commit**
```bash
git add accbot-ios/AccBot/Data/Local/Database/Records/HoldingRecord.swift \
        accbot-ios/AccBot/Data/Local/Database/Dao/HoldingDao.swift \
        accbot-ios/AccBot/Data/Local/Database/DcaDatabase.swift \
        accbot-ios/AccBotTests/HoldingDaoTests.swift
git commit -m "feat(data): holdings tabulka (acquisitionDate, collateral, loanId)"
```

---

### Task 2: AppSnapshot model (Codable)

**Files:** Create `AppSnapshot.swift`; Test `AppSnapshotTests.swift`.

- [ ] **Step 1: Padající round-trip test**
```swift
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
```
- [ ] **Step 2: Ověř fail (CI).**
- [ ] **Step 3: Implementuj** `AppSnapshot.swift`
```swift
import Foundation

struct AppSnapshot: Codable, Equatable {
    var version: Int
    var exportedAt: String
    var fiat: String
    var strategy: Strategy
    var holdings: [Holding]
    var transactions: [Transaction]
    var firefishLoans: [FirefishLoan]
    var bankLoans: [BankLoan]

    struct Strategy: Codable, Equatable {
        var type: String
        var nuplBottomValue: Double
        var nuplCenterValue: Double
        var nuplMinMultiplier: Double
        var nuplMaxMultiplier: Double
        var baseChunkCzk: String
        var baseChunkMultiplier: String
        var lastProcessedDate: String   // yyyy-MM-dd
        var availableCashCzk: String
    }
    struct Holding: Codable, Equatable {
        var id: String
        var amount: String
        var acquisitionDate: String     // yyyy-MM-dd
        var purchasePriceCzk: String
        var isCollateralized: Bool
        var loanId: String?
        var source: String
        var notes: String
    }
    struct Transaction: Codable, Equatable {
        var date: String                // yyyy-MM-dd
        var type: String
        var amountBtc: String
        var amountCzk: String
        var btcPriceCzk: String
        var exchangeOrderId: String?
    }
    struct FirefishLoan: Codable, Equatable {
        var externalLoanId: String
        var loanDate: String
        var maturityDate: String
        var loanAmountCzk: String
        var interestRate: String
        var btcFeeRate: String
        var btcPriceAtLoan: String
        var collateralBtcAmount: String
        var isRepaid: Bool
    }
    struct BankLoan: Codable, Equatable {
        var principalCzk: String
        var annualInterestRate: String
        var durationMonths: Int
        var remainingPrincipalCzk: String
        var nextPaymentDate: String
        var isFullyPaid: Bool
    }
}
```
- [ ] **Step 4: Ověř pass (CI).**
- [ ] **Step 5: Commit** `feat(snapshot): AppSnapshot Codable model + round-trip test`.

---

### Task 3: SnapshotService (build/load)

**Files:** Create `SnapshotService.swift`; Test `SnapshotServiceTests.swift`.
> Phase 1+2 sekce: plans/holdings/transactions/strategy. Loany doplní Plán 3 (Task 6 tam).

- [ ] **Step 1: Padající test — build→load round trip**
```swift
import XCTest
@testable import AccBot
final class SnapshotServiceTests: XCTestCase {
    func test_buildThenLoad_preservesHoldings() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsert(HoldingRecord(id: "h1", amount: "0.5", acquisitionDate: 1_600_000_000,
            purchasePriceCzk: "0", isCollateralized: false, loanId: nil, isAvailableForDca: true,
            source: "Initial", notes: "", createdAt: 0))
        let svc = SnapshotService()
        let snap = try svc.build(from: db, fiat: "CZK")
        let db2 = try DcaDatabase(path: nil)
        try svc.load(snap, into: db2)
        XCTAssertEqual(try db2.holdingDao.getAll().map(\.id), ["h1"])
    }
}
```
- [ ] **Step 2: Ověř fail (CI).**
- [ ] **Step 3: Implementuj** `SnapshotService.swift`
```swift
import Foundation

/// Staví AppSnapshot z DB a nahrává zpět. Loany řeší Plán 3 (rozšíří build/load).
final class SnapshotService {
    private let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    private let isoFmt = ISO8601DateFormatter()

    func build(from db: DcaDatabase, fiat: String) throws -> AppSnapshot {
        let holdings = try db.holdingDao.getAll().map { h in
            AppSnapshot.Holding(
                id: h.id, amount: h.amount,
                acquisitionDate: dayFmt.string(from: Date(timeIntervalSince1970: h.acquisitionDate)),
                purchasePriceCzk: h.purchasePriceCzk, isCollateralized: h.isCollateralized,
                loanId: h.loanId, source: h.source, notes: h.notes)
        }
        let txs = try db.transactionDao.getAll(limit: 100_000).map { t in
            AppSnapshot.Transaction(
                date: dayFmt.string(from: t.executedAt), type: "DCA_PURCHASE",
                amountBtc: "\(t.cryptoAmount)", amountCzk: "-\(t.fiatAmount)",
                btcPriceCzk: "\(t.price)", exchangeOrderId: t.exchangeOrderId)
        }
        // strategy: z prvního NUPL plánu (Plán 1)
        let plan = try db.planDao.getAll().first { if case .nupl = $0.strategy { return true }; return false }
        let cfg: NuplConfig = { if case .nupl(let c)? = plan?.strategy { return c }; return .default }()
        let strategy = AppSnapshot.Strategy(
            type: "NUPL", nuplBottomValue: cfg.bottomValue, nuplCenterValue: cfg.centerValue,
            nuplMinMultiplier: Double(cfg.minMultiplier), nuplMaxMultiplier: Double(cfg.maxMultiplier),
            baseChunkCzk: plan.map { "\($0.amount)" } ?? "0", baseChunkMultiplier: "1.0",
            lastProcessedDate: plan?.lastExecutedAt.map { dayFmt.string(from: $0) } ?? "",
            availableCashCzk: "0")  // cash je živá z burzy, neukládáme
        return AppSnapshot(version: 1, exportedAt: isoFmt.string(from: Date()), fiat: fiat,
            strategy: strategy, holdings: holdings, transactions: txs, firefishLoans: [], bankLoans: [])
    }

    func load(_ snap: AppSnapshot, into db: DcaDatabase) throws {
        let now = Date().timeIntervalSince1970
        try db.holdingDao.deleteAll()
        try db.holdingDao.upsertBatch(snap.holdings.map { h in
            HoldingRecord(id: h.id, amount: h.amount,
                acquisitionDate: (dayFmt.date(from: h.acquisitionDate) ?? Date()).timeIntervalSince1970,
                purchasePriceCzk: h.purchasePriceCzk, isCollateralized: h.isCollateralized,
                loanId: h.loanId, isAvailableForDca: true, source: h.source, notes: h.notes, createdAt: now)
        })
        // Pozn.: transakce/plán/loany load doplní Plán 3 dle potřeby (holdingy = nenahraditelné jádro pro daně).
    }
}
```
- [ ] **Step 4: Ověř pass (CI).**
- [ ] **Step 5: Commit** `feat(snapshot): SnapshotService build/load (holdings)`.

---

### Task 4: GitHub backup service + PAT store + NetworkClient.put

**Files:** Modify `NetworkClient.swift`; Create `TokenStore.swift`, `GitHubBackupService.swift`.

- [ ] **Step 1: NetworkClient.put** (mirror `delete`/`postJsonRaw`)
```swift
    func put(url: String, body: [String: Any], headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: url) else { throw NetworkError.invalidUrl(url) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await execute(request)
    }
```
- [ ] **Step 2: TokenStore** (PAT v Keychain — mirror CredentialsStore, jeden klíč)
```swift
import Foundation
import Security
/// Uloží GitHub PAT do Keychain (device-only). PAT se při ztrátě zařízení vygeneruje znovu.
final class TokenStore {
    private let service = "com.accbot.dca.tokens"
    private let account = "github_pat"
    func save(_ token: String) {
        let data = Data(token.utf8)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary, nil)
    }
    func get() -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```
- [ ] **Step 3: GitHubBackupService** (Contents API: GET sha → PUT base64)
```swift
import Foundation
/// Záloha snapshot.json do private repa přes GitHub Contents API.
final class GitHubBackupService {
    private let client: NetworkClient
    private let tokenStore: TokenStore
    private let repo = "hlavasim/smart-dca-data"
    private let path = "snapshot.json"

    init(client: NetworkClient, tokenStore: TokenStore) {
        self.client = client; self.tokenStore = tokenStore
    }
    private var headers: [String: String]? {
        guard let token = tokenStore.get() else { return nil }
        return ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28"]
    }
    private var contentsUrl: String { "https://api.github.com/repos/\(repo)/contents/\(path)" }

    /// Vrátí (content, sha) nebo nil když soubor neexistuje.
    func fetch() async -> (json: Data, sha: String)? {
        guard let headers else { return nil }
        do {
            let (data, _) = try await client.get(url: contentsUrl, headers: headers)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let b64 = (json["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
                  let sha = json["sha"] as? String,
                  let decoded = Data(base64Encoded: b64) else { return nil }
            return (decoded, sha)
        } catch { return nil }
    }
    /// Push snapshot. Vrací commit SHA při úspěchu.
    @discardableResult
    func push(_ snapshotJson: Data, message: String) async -> String? {
        guard let headers else { return nil }
        let existingSha = await fetch()?.sha
        var body: [String: Any] = [
            "message": message,
            "content": snapshotJson.base64EncodedString()
        ]
        if let existingSha { body["sha"] = existingSha }
        do {
            let (data, _) = try await client.put(url: contentsUrl, body: body, headers: headers)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["commit"] as? [String: Any])?["sha"] as? String
        } catch { return nil }
    }
}
```
- [ ] **Step 4: Ověř build (CI).** (Síťové metody se neunit-testují — ověří se ručně proti repu při integraci.)
- [ ] **Step 5: Commit** `feat(backup): GitHubBackupService + TokenStore (PAT) + NetworkClient.put`.

---

### Task 5: Napojení zálohy/obnovy

**Files:** Modify `AppDependencies.swift`, `DcaExecutionEngine.swift`.

- [ ] **Step 1: Wiring** — v `AppDependencies.init()` vytvoř `let tokenStore = TokenStore()`, `let gitHubBackupService = GitHubBackupService(client: networkClient, tokenStore: tokenStore)`, `let snapshotService = SnapshotService()` a přiřaď do properties. Předej `snapshotService`, `gitHubBackupService` do `DcaExecutionEngine`.

- [ ] **Step 2: Záloha po nákupu** — v `DcaExecutionEngine`, po úspěšném dni v catch-up smyčce (Plán 1, `runNuplCatchup`, větev `.success` po `updateExecution`), zavolej:
```swift
        await backupAfterChange(reason: "DCA \(plan.crypto) \(dayFmt.string(from: ...))")
```
a přidej helper:
```swift
    private func backupAfterChange(reason: String) async {
        guard let snap = try? snapshotService.build(from: activeDb, fiat: "CZK"),
              let data = try? JSONEncoder().encode(snap) else { return }
        let sha = await gitHubBackupService.push(data, message: "snapshot: \(reason)")
        if let sha { logger.info("Backup pushed: \(sha)") }
        else { logger.warning("Backup push failed (will retry next run)") }
        userPreferences.lastBackupAt = sha != nil ? Date() : userPreferences.lastBackupAt
    }
```
(Přidej `lastBackupAt: Date?` do `UserPreferences`.)

- [ ] **Step 3: Obnova** — vytvoř use case / volání na startu (v `AppDependencies` nebo splash): pokud je DB prázdná (`holdingDao.getAll().isEmpty` && `transactionDao.getTotalCount() == 0`) a PAT je nastaven, zavolej:
```swift
        if let (json, _) = await gitHubBackupService.fetch(),
           let snap = try? JSONDecoder().decode(AppSnapshot.self, from: json) {
            try? snapshotService.load(snap, into: database)
        }
```

- [ ] **Step 4: UI stav zálohy** — v Settings/Dashboard zobraz `userPreferences.lastBackupAt` jako „Poslední záloha: před X". (Reference: existující `SettingsView` řádky.) + pole pro zadání GitHub PAT → `tokenStore.save(...)`.

- [ ] **Step 5: Ověř build (CI) + Commit** `feat(backup): záloha po nákupu + obnova na startu + UI stav`.

---

### Task 6: Konverzní skript (C# JSON → snapshot.json)

**Files:** Create `tools/migrate-csharp/convert.py`, `test_convert.py`, `sample/`.
> Běží lokálně na Windows (Python 3). Otestovatelné bez CI.

- [ ] **Step 1: Fixtures** — zkopíruj malé vzorky do `tools/migrate-csharp/sample/`:
  `state.json`, `holdings.json`, `transactions.json`, `loans/firefish-active.json`, `loans/bank-loans.json`
  (z `smart-dca-leveraged-local-first/SmartDcaLeveraged/data/`, oříznuté na 1-2 záznamy) + `expected_snapshot.json` (ručně sestavený očekávaný výstup).

- [ ] **Step 2: Padající golden test** `test_convert.py`
```python
import json, subprocess, sys, pathlib
BASE = pathlib.Path(__file__).parent
def test_golden():
    out = subprocess.check_output([sys.executable, str(BASE/"convert.py"), str(BASE/"sample")])
    got = json.loads(out)
    expected = json.loads((BASE/"sample"/"expected_snapshot.json").read_text(encoding="utf-8"))
    # porovnej bez volatilního exportedAt
    got.pop("exportedAt", None); expected.pop("exportedAt", None)
    assert got == expected
```
Run: `python -m pytest tools/migrate-csharp/test_convert.py -v` → FAIL (convert.py chybí).

- [ ] **Step 3: Implementuj** `convert.py`
```python
#!/usr/bin/env python3
"""C# SmartDcaLeveraged JSON -> smart-dca-ios snapshot.json.
Usage: python convert.py <data_dir>  (>data_dir má state.json, holdings.json, transactions.json, loans/)
"""
import json, sys, pathlib
from datetime import datetime, timezone

def day(s):  # "2021-04-21T02:00:00" -> "2021-04-21"
    return s[:10] if s else ""

def main(data_dir):
    d = pathlib.Path(data_dir)
    state = json.loads((d/"state.json").read_text(encoding="utf-8"))
    holdings = json.loads((d/"holdings.json").read_text(encoding="utf-8")).get("holdings", [])
    txs = json.loads((d/"transactions.json").read_text(encoding="utf-8")).get("transactions", [])
    ff_path = d/"loans"/"firefish-active.json"
    bank_path = d/"loans"/"bank-loans.json"
    ff = json.loads(ff_path.read_text(encoding="utf-8")).get("loans", []) if ff_path.exists() else []
    bank = json.loads(bank_path.read_text(encoding="utf-8")).get("loans", []) if bank_path.exists() else []
    s = state["strategy"]

    snap = {
        "version": 1,
        "exportedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fiat": "CZK",
        "strategy": {
            "type": "NUPL",
            "nuplBottomValue": 0.0, "nuplCenterValue": 0.5,
            "nuplMinMultiplier": 0.5, "nuplMaxMultiplier": 3.0,
            "baseChunkCzk": str(s["baseChunkCzk"]),
            "baseChunkMultiplier": "0.8",
            "lastProcessedDate": day(s["lastProcessedDate"]),
            "availableCashCzk": str(s["availableCashCzk"]),
        },
        "holdings": [{
            "id": h["id"], "amount": str(h["amount"]),
            "acquisitionDate": day(h["acquisitionDate"]),
            "purchasePriceCzk": str(h["purchasePriceCzk"]),
            "isCollateralized": h["isCollateralized"],
            "loanId": (h.get("collateralForLoanIds") or [None])[0],
            "source": h["source"], "notes": h.get("notes", ""),
        } for h in holdings],
        "transactions": [{
            "date": day(t["date"]), "type": t["type"],
            "amountBtc": str(t["amountBtc"]), "amountCzk": str(t["amountCzk"]),
            "btcPriceCzk": str(t["btcPriceCzk"]), "exchangeOrderId": None,
        } for t in txs],
        "firefishLoans": [{
            "externalLoanId": l.get("externalLoanId", l.get("ExternalLoanId", "")),
            "loanDate": day(l.get("loanDate", l.get("LoanDate", ""))),
            "maturityDate": day(l.get("maturityDate", l.get("MaturityDate", ""))),
            "loanAmountCzk": str(l.get("loanAmountCzk", l.get("LoanAmountCzk", 0))),
            "interestRate": str(l.get("interestRate", l.get("InterestRate", 0))),
            "btcFeeRate": str(l.get("btcFeeRate", l.get("BtcFeeRate", 0))),
            "btcPriceAtLoan": str(l.get("btcPriceAtLoan", l.get("BtcPriceAtLoan", 0))),
            "collateralBtcAmount": str(l.get("collateralBtcAmount", l.get("CollateralBtcAmount", 0))),
            "isRepaid": l.get("isRepaid", l.get("IsRepaid", False)),
        } for l in ff],
        "bankLoans": [{
            "principalCzk": str(l.get("principalCzk", l.get("PrincipalCzk", 0))),
            "annualInterestRate": str(l.get("annualInterestRate", l.get("AnnualInterestRate", 0))),
            "durationMonths": int(l.get("durationMonths", l.get("DurationMonths", 0))),
            "remainingPrincipalCzk": str(l.get("remainingPrincipalCzk", l.get("RemainingPrincipalCzk", 0))),
            "nextPaymentDate": day(l.get("nextPaymentDate", l.get("NextPaymentDate", ""))),
            "isFullyPaid": l.get("isFullyPaid", l.get("IsFullyPaid", False)),
        } for l in bank],
    }
    print(json.dumps(snap, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main(sys.argv[1])
```
Run: `python -m pytest tools/migrate-csharp/test_convert.py -v` → PASS.

- [ ] **Step 4: Manuální migrace (jednorázově, dokumentuj v README skriptu):**
```bash
python tools/migrate-csharp/convert.py <cesta>/smart-dca-leveraged-local-first/SmartDcaLeveraged/data > snapshot.json
# commitni snapshot.json do private repa smart-dca-data
```

- [ ] **Step 5: Commit** `feat(migrate): konverzní skript C# JSON -> snapshot.json + golden test`.

---

## Self-review (spec coverage Plánu 2)

- **C. Git záloha (push, potvrzený SHA, retry, stav)** → Task 4 (`push` vrací SHA) + Task 5 (`backupAfterChange`, `lastBackupAt`). ✓
- **C. Obnova (pull → load)** → Task 5 Step 3. ✓
- **C. PAT v Keychain** → Task 4 (`TokenStore`). ✓
- **C. Plain JSON** → Task 2/3 (`JSONEncoder`, žádné šifrování). ✓
- **B. Konverzní skript C#→snapshot, app bez C# parseru** → Task 6 (Python, app čte jen `AppSnapshot`). ✓
- **B. Import = obnova** → Task 5/6 (skript vyrobí snapshot → stejná load cesta). ✓
- **Holdings s acquisitionDate (pro daně)** → Task 1. ✓

## Otevřené body (předané)

- `transactionDao.getAll(limit:)` existuje; ověřit horní limit pro velkou historii (Task 3 používá 100_000).
- Loany v `load()` + `build()` doplní Plán 3 (Task 6 tam) — Plán 2 řeší holdings/transactions/strategy.
- Restore-on-start: rozhodnout přesné místo (splash vs AppDependencies) a guard prázdné DB.
- GitHub PAT scope: `contents:write` jen na `smart-dca-data` (fine-grained token).
