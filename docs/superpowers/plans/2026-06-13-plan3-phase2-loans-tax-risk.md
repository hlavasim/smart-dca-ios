# Plán 3 — Phase 2: FF/bank půjčky, daně, risk cockpit, maturity alerty

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Port pákové/daňové/risk logiky z C# do iOS: Firefish + bankovní půjčky, český 3letý daňový test + FIFO, risk cockpit (LTV/likvidace/scénáře/udržitelnost) a alerty splatnosti + LTV.

**Architecture:** Nové tabulky `firefish_loans`, `bank_loans` (mirror vzoru). Veškerá finanční matematika je **čistá funkce** (port 1:1 z C# `RiskMetricsService`/`FirefishLoan`/`BankLoan`), testovaná C# vektory. UI cockpit navazuje na existující Dashboard/Portfolio.

**Tech Stack:** Swift / GRDB / XCTest. Zdroj pravdy pro vzorce: `smart-dca-leveraged-local-first` (`Services/RiskMetricsService.cs`, `Models/FirefishLoan.cs`, `Models/BankLoan.cs`, `Models/FifoAllocationDb.cs`, `Services/CollateralService.cs`).

**Předpoklad:** Plán 1 + Plán 2 hotové (holdings tabulka, AppSnapshot, SnapshotService).

## ⚠️ Verifikace na CI (žádný Mac) — viz Plán 1. Kadence per-task.

Pracovní větev: `feature/phase2-loans-tax-risk`.

## Soubory

```
accbot-ios/AccBot/
  Domain/Model/FirefishLoan.swift                  (NEW — model + calc)
  Domain/Model/BankLoan.swift                       (NEW — model + anuita)
  Domain/Model/RiskConstants.swift                  (NEW — LTV prahy)
  Domain/Model/TaxModels.swift                      (NEW — 3letý test, FIFO)
  Domain/Model/RiskMetrics.swift                    (NEW — výstupní struktura)
  Domain/UseCase/RiskMetricsUseCase.swift           (NEW — pure port RiskMetricsService)
  Data/Local/Database/Records/FirefishLoanRecord.swift  (NEW)
  Data/Local/Database/Records/BankLoanRecord.swift      (NEW)
  Data/Local/Database/Dao/FirefishLoanDao.swift     (NEW)
  Data/Local/Database/Dao/BankLoanDao.swift         (NEW)
  Data/Local/Database/DcaDatabase.swift             (MODIFY — v7 loans)
  Domain/UseCase/SnapshotService.swift              (MODIFY — loany v build/load)
  Service/MaturityAlertService.swift                (NEW — alerty splatnosti + LTV)
  Presentation/Screens/Risk/RiskCockpitView.swift   (NEW — UI)
  Presentation/Screens/Risk/RiskCockpitViewModel.swift (NEW)
tools/migrate-csharp/convert.py                     (už hotovo v Plánu 2 — loany)
accbot-ios/AccBotTests/
  FirefishLoanCalcTests.swift, BankLoanCalcTests.swift
  TaxTests.swift, RiskMetricsTests.swift
```

---

### Task 1: Loan modely + výpočty (čisté funkce)

**Files:** Create `FirefishLoan.swift`, `BankLoan.swift`, `RiskConstants.swift`; Test `FirefishLoanCalcTests.swift`, `BankLoanCalcTests.swift`.

- [ ] **Step 1: Padající testy** (C# vektory z FirefishLoan.cs:49-63, BankLoan.cs:25-42)
```swift
import XCTest
@testable import AccBot
final class FirefishLoanCalcTests: XCTestCase {
    func test_interestAndRepayment() {
        // 50000 CZK, 10% p.a., 365 dní → interest 5000, repayment 55000
        let l = FirefishLoan(externalLoanId: "FF1", loanDate: Date(), maturityDate: Date(),
            durationDays: 365, loanAmountCzk: 50000, interestRate: 0.10, btcFeeRate: 0.015,
            btcPriceAtLoan: 1_000_000, collateralBtcAmount: 0.08, isRepaid: false)
        XCTAssertEqual(l.interestCzk, 5000, accuracy: 0.01)
        XCTAssertEqual(l.totalRepaymentCzk, 55000, accuracy: 0.01)
        // fee: 50000*0.015*1 = 750 CZK / 1_000_000 = 0.00075 BTC
        XCTAssertEqual(l.btcFeeAmount, 0.00075, accuracy: 1e-8)
    }
}
final class BankLoanCalcTests: XCTestCase {
    func test_annuity() {
        // 1_000_000, 7% p.a., 120 měsíců → ~11_610.85/měs
        let b = BankLoan(principalCzk: 1_000_000, annualInterestRate: 0.07, durationMonths: 120,
            remainingPrincipalCzk: 1_000_000, nextPaymentDate: Date(), isFullyPaid: false)
        XCTAssertEqual(b.monthlyPaymentCzk, 11_610.85, accuracy: 1.0)
    }
    func test_zeroInterest() {
        let b = BankLoan(principalCzk: 120_000, annualInterestRate: 0, durationMonths: 120,
            remainingPrincipalCzk: 120_000, nextPaymentDate: Date(), isFullyPaid: false)
        XCTAssertEqual(b.monthlyPaymentCzk, 1000, accuracy: 0.01)
    }
}
```
- [ ] **Step 2: Ověř fail (CI).**
- [ ] **Step 3: Implementuj**

`RiskConstants.swift`:
```swift
enum RiskConstants {
    static let ffLiquidationLtv: Double = 0.95
    static let ffWarnHigh: Double = 0.86       // danger
    static let ffWarnLow: Double = 0.73        // warning
    static let ffOriginationLtv: Double = 0.50 // max nová půjčka
    static let taxFreeYears = 3
    static let ltvWarningThreshold: Double = 0.80
    static let ltvTopUpPercentage: Double = 0.20
    static let maturityAdvanceNoticeDays = 7
}
enum RiskLevel: String, Sendable { case ok, warning, danger }
```

`FirefishLoan.swift` (port FirefishLoan.cs):
```swift
import Foundation
struct FirefishLoan: Identifiable, Equatable, Sendable {
    var id: String { externalLoanId }
    let externalLoanId: String
    let loanDate: Date
    let maturityDate: Date
    let durationDays: Int
    let loanAmountCzk: Decimal
    let interestRate: Decimal      // p.a.
    let btcFeeRate: Decimal        // p.a. v BTC
    let btcPriceAtLoan: Decimal
    let collateralBtcAmount: Decimal
    let isRepaid: Bool

    var yearFraction: Decimal { Decimal(durationDays) / 365 }
    var interestCzk: Decimal { loanAmountCzk * interestRate * yearFraction }
    var totalRepaymentCzk: Decimal { loanAmountCzk + interestCzk }
    var btcFeeAmount: Decimal {
        let feeCzk = loanAmountCzk * btcFeeRate * yearFraction
        return btcPriceAtLoan > 0 ? feeCzk / btcPriceAtLoan : 0
    }
}
```

`BankLoan.swift` (port BankLoan.cs anuita):
```swift
import Foundation
struct BankLoan: Identifiable, Equatable, Sendable {
    var id: String { "\(principalCzk)-\(nextPaymentDate.timeIntervalSince1970)" }
    let principalCzk: Decimal
    let annualInterestRate: Decimal
    let durationMonths: Int
    let remainingPrincipalCzk: Decimal
    let nextPaymentDate: Date
    let isFullyPaid: Bool

    var monthlyPaymentCzk: Decimal {
        guard durationMonths > 0 else { return 0 }
        let p = NSDecimalNumber(decimal: principalCzk).doubleValue
        let r = NSDecimalNumber(decimal: annualInterestRate).doubleValue / 12.0
        if r == 0 { return Decimal(p / Double(durationMonths)) }
        let factor = pow(1 + r, Double(durationMonths))
        return Decimal(p * (r * factor) / (factor - 1))
    }
}
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(loans): FF/bank modely + výpočty (port z C#)`.

---

### Task 2: Loan persistence (tabulky + DAO)

**Files:** Create `FirefishLoanRecord.swift`, `BankLoanRecord.swift`, `FirefishLoanDao.swift`, `BankLoanDao.swift`; Modify `DcaDatabase.swift` (v7).

- [ ] **Step 1: Records** (string Decimaly, Double data)
```swift
import GRDB
struct FirefishLoanRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "firefish_loans"
    var externalLoanId: String
    var loanDate: Double
    var maturityDate: Double
    var durationDays: Int
    var loanAmountCzk: String
    var interestRate: String
    var btcFeeRate: String
    var btcPriceAtLoan: String
    var collateralBtcAmount: String
    var isRepaid: Bool
}
struct BankLoanRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "bank_loans"
    var id: String
    var principalCzk: String
    var annualInterestRate: String
    var durationMonths: Int
    var remainingPrincipalCzk: String
    var nextPaymentDate: Double
    var isFullyPaid: Bool
}
```
- [ ] **Step 2: DAOs** (getActive, upsert, upsertBatch, deleteAll — mirror HoldingDao; mapování Record↔doménový model přes helpery). 
```swift
import GRDB
import Foundation
struct FirefishLoanDao {
    let dbPool: DatabasePool
    func getActive() throws -> [FirefishLoanRecord] {
        try dbPool.read { try FirefishLoanRecord.filter(Column("isRepaid") == false).fetchAll($0) }
    }
    func getAll() throws -> [FirefishLoanRecord] { try dbPool.read { try FirefishLoanRecord.fetchAll($0) } }
    func upsertBatch(_ rows: [FirefishLoanRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.insert(db, onConflict: .replace) } }
    }
    func deleteAll() throws { try dbPool.write { try FirefishLoanRecord.deleteAll($0) } }
}
struct BankLoanDao {
    let dbPool: DatabasePool
    func getActive() throws -> [BankLoanRecord] {
        try dbPool.read { try BankLoanRecord.filter(Column("isFullyPaid") == false).fetchAll($0) }
    }
    func getAll() throws -> [BankLoanRecord] { try dbPool.read { try BankLoanRecord.fetchAll($0) } }
    func upsertBatch(_ rows: [BankLoanRecord]) throws {
        try dbPool.write { db in try rows.forEach { try $0.insert(db, onConflict: .replace) } }
    }
    func deleteAll() throws { try dbPool.write { try BankLoanRecord.deleteAll($0) } }
}
```
- [ ] **Step 3: Migrace v7 + DAO props** (`DcaDatabase.swift`)
```swift
    migrator.registerMigration("v7_loans") { db in
        try db.create(table: "firefish_loans") { t in
            t.column("externalLoanId", .text).notNull().primaryKey()
            t.column("loanDate", .double).notNull()
            t.column("maturityDate", .double).notNull()
            t.column("durationDays", .integer).notNull()
            t.column("loanAmountCzk", .text).notNull()
            t.column("interestRate", .text).notNull()
            t.column("btcFeeRate", .text).notNull()
            t.column("btcPriceAtLoan", .text).notNull()
            t.column("collateralBtcAmount", .text).notNull()
            t.column("isRepaid", .boolean).notNull().defaults(to: false)
        }
        try db.create(table: "bank_loans") { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("principalCzk", .text).notNull()
            t.column("annualInterestRate", .text).notNull()
            t.column("durationMonths", .integer).notNull()
            t.column("remainingPrincipalCzk", .text).notNull()
            t.column("nextPaymentDate", .double).notNull()
            t.column("isFullyPaid", .boolean).notNull().defaults(to: false)
        }
    }
```
Props `let firefishLoanDao`, `let bankLoanDao` + init.
- [ ] **Step 4: Test** (in-memory: upsert FF/bank, getActive filtruje isRepaid/isFullyPaid). **Step 5: Commit** `feat(loans): firefish_loans + bank_loans tabulky + DAO`.

---

### Task 3: Daně — 3letý test + FIFO (čisté funkce)

**Files:** Create `TaxModels.swift`; Test `TaxTests.swift`.

- [ ] **Step 1: Padající testy** (port RiskMetricsService.cs:194-208 + FifoAllocationDb.cs)
```swift
import XCTest
@testable import AccBot
final class TaxTests: XCTestCase {
    let cal = Calendar(identifier: .gregorian)
    func d(_ y: Int,_ m: Int,_ day: Int) -> Date {
        DateComponents(calendar: cal, year: y, month: m, day: day).date!
    }
    func test_threeYearTest_exemptWhenOlder() {
        let today = d(2026,6,14)
        XCTAssertTrue(TaxRules.isExempt(acquisition: d(2023,6,13), today: today))   // >3 roky
        XCTAssertFalse(TaxRules.isExempt(acquisition: d(2023,6,15), today: today))  // <3 roky
    }
    func test_classification_splitsHoldings() {
        let today = d(2026,6,14)
        let h = [
            TaxHolding(amount: 1.0, acquisition: d(2021,1,1)),  // free
            TaxHolding(amount: 0.5, acquisition: d(2025,1,1)),  // taxable
        ]
        let c = TaxRules.classify(holdings: h, today: today)
        XCTAssertEqual(c.taxFree, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.taxable, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.nextExemption, DateComponents(calendar: cal, year: 2028, month: 1, day: 1).date!)
    }
    func test_fifoProfit_andTax() {
        // prodej 1 BTC za 2M, koupeno za 1M, drženo <3 roky, sazba 0.15
        let lot = TaxRules.fifoGain(amount: 1.0, acquisitionPrice: 1_000_000, salePrice: 2_000_000,
            daysHeld: 100, taxRate: 0.15)
        XCTAssertEqual(lot.profit, 1_000_000, accuracy: 0.01)
        XCTAssertFalse(lot.isExempt)
        XCTAssertEqual(lot.taxAmount, 150_000, accuracy: 0.01)
    }
    func test_fifoProfit_exemptOver3y() {
        let lot = TaxRules.fifoGain(amount: 1.0, acquisitionPrice: 1_000_000, salePrice: 2_000_000,
            daysHeld: 1100, taxRate: 0.15)
        XCTAssertTrue(lot.isExempt)
        XCTAssertEqual(lot.taxAmount, 0, accuracy: 0.01)
    }
}
```
- [ ] **Step 2: Ověř fail (CI).**
- [ ] **Step 3: Implementuj** `TaxModels.swift`
```swift
import Foundation
struct TaxHolding { let amount: Double; let acquisition: Date }
struct TaxClassification { let taxFree: Double; let taxable: Double; let nextExemption: Date? }
struct FifoGain { let profit: Double; let isExempt: Bool; let taxAmount: Double }

enum TaxRules {
    private static var cal: Calendar { Calendar(identifier: .gregorian) }

    /// 3letý test: osvobozeno když acquisition + 3 roky <= today (kalendářní).
    static func isExempt(acquisition: Date, today: Date) -> Bool {
        guard let plus3 = cal.date(byAdding: .year, value: RiskConstants.taxFreeYears, to: acquisition) else { return false }
        return plus3 <= today
    }
    static func classify(holdings: [TaxHolding], today: Date) -> TaxClassification {
        var free = 0.0, taxable = 0.0
        var earliestTaxable: Date?
        for h in holdings {
            if isExempt(acquisition: h.acquisition, today: today) { free += h.amount }
            else {
                taxable += h.amount
                if earliestTaxable == nil || h.acquisition < earliestTaxable! { earliestTaxable = h.acquisition }
            }
        }
        let next = earliestTaxable.flatMap { cal.date(byAdding: .year, value: RiskConstants.taxFreeYears, to: $0) }
        return TaxClassification(taxFree: free, taxable: taxable, nextExemption: next)
    }
    /// FIFO zisk + daň. Jen zisky se daní; >=1095 dní → osvobozeno.
    static func fifoGain(amount: Double, acquisitionPrice: Double, salePrice: Double,
                         daysHeld: Int, taxRate: Double) -> FifoGain {
        let profit = amount * salePrice - amount * acquisitionPrice
        let exempt = daysHeld >= 1095
        let taxable = (!exempt && profit > 0) ? profit : 0
        return FifoGain(profit: profit, isExempt: exempt, taxAmount: taxable * taxRate)
    }
}
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(tax): 3letý test + klasifikace + FIFO zisk/daň (port z C#)`.

---

### Task 4: RiskMetricsUseCase — cockpit + scénáře (čistá funkce)

**Files:** Create `RiskMetrics.swift`, `RiskMetricsUseCase.swift`; Test `RiskMetricsTests.swift`.
> Port `RiskMetricsService.Build` (RiskMetricsService.cs:112-327). Vstup = doménové modely + ceny; výstup = `RiskMetrics`. Bez DB/sítě → plně testovatelné.

- [ ] **Step 1: Padající testy** (vektory dle C# vzorců)
```swift
import XCTest
@testable import AccBot
final class RiskMetricsTests: XCTestCase {
    func makeLoan(_ repay: Decimal, _ collateral: Decimal) -> FirefishLoan {
        FirefishLoan(externalLoanId: "L", loanDate: Date(), maturityDate: Date(),
            durationDays: 365, loanAmountCzk: repay, interestRate: 0, btcFeeRate: 0,
            btcPriceAtLoan: 1_000_000, collateralBtcAmount: collateral, isRepaid: false)
    }
    func test_perLoanLtvAndLiquidation() {
        // repay 50000, collateral 0.1 BTC, price 1_000_000 → LTV 0.5; liq = 50000/(0.1*0.95)=526315.79
        let r = RiskMetricsUseCase.perLoan(loan: makeLoan(50000, 0.1), btcPrice: 1_000_000, ath: 2_000_000)
        XCTAssertEqual(r.ltv, 0.5, accuracy: 1e-6)
        XCTAssertEqual(r.liquidationPriceCzk, 526_315.79, accuracy: 0.5)
        XCTAssertEqual(r.level, .ok)
    }
    func test_levelThresholds() {
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.72), .ok)
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.80), .warning)
        XCTAssertEqual(RiskMetricsUseCase.level(ltv: 0.90), .danger)
    }
    func test_yearsSustainable() {
        // headroom/ffDebt = (btc*price*0.95 - bank)/ffDebt; ln(...)/ln(1+rate)
        let y = RiskMetricsUseCase.yearsAtPrice(price: 1_000_000, btc: 1.0, ffDebt: 100_000,
            bankDebt: 0, avgFfRate: 0.10)
        // maxDebt 950000, headroom 950000, ln(9.5)/ln(1.1) ≈ 23.6
        XCTAssertEqual(y, 23.6, accuracy: 0.3)
    }
}
```
- [ ] **Step 2: Ověř fail (CI).**
- [ ] **Step 3: Implementuj** `RiskMetrics.swift` (výstupní struktury — LoanRisk, ScenarioRow, RiskMetrics; pole dle spec sekce F) a `RiskMetricsUseCase.swift` s čistými funkcemi:
```swift
import Foundation
struct LoanRisk: Equatable {
    let externalLoanId: String
    let ltv: Double
    let liquidationPriceCzk: Double
    let bufferPct: Double
    let liquidationFromAthPct: Double
    let level: RiskLevel
}
// ScenarioRow + RiskMetrics: pole viz spec sekce F (worstLtv, effectiveLiqPrice,
// nextMaturity*, yearsSustainable, netBtcAfterDebt, breakEvenPrice, scénáře...).

enum RiskMetricsUseCase {
    static func level(ltv: Double) -> RiskLevel {
        if ltv >= RiskConstants.ffWarnHigh { return .danger }
        if ltv >= RiskConstants.ffWarnLow { return .warning }
        return .ok
    }
    static func perLoan(loan: FirefishLoan, btcPrice: Decimal, ath: Decimal) -> LoanRisk {
        let repay = NSDecimalNumber(decimal: loan.totalRepaymentCzk).doubleValue
        let coll = NSDecimalNumber(decimal: loan.collateralBtcAmount).doubleValue
        let price = NSDecimalNumber(decimal: btcPrice).doubleValue
        let athD = NSDecimalNumber(decimal: ath).doubleValue
        let ltv = coll > 0 && price > 0 ? repay / (coll * price) : 0
        let liq = coll > 0 ? repay / (coll * RiskConstants.ffLiquidationLtv) : 0
        let buffer = price > 0 ? (price - liq) / price : 0
        let liqFromAth = athD > 0 ? (liq - athD) / athD : 0
        return LoanRisk(externalLoanId: loan.externalLoanId, ltv: ltv, liquidationPriceCzk: liq,
            bufferPct: buffer, liquidationFromAthPct: liqFromAth, level: level(ltv: ltv))
    }
    /// roky udržitelnosti (infinite roll) — port RiskMetricsService.cs:160-168
    static func yearsAtPrice(price: Double, btc: Double, ffDebt: Double, bankDebt: Double, avgFfRate: Double) -> Double {
        let maxDebt = btc * price * RiskConstants.ffLiquidationLtv
        let headroom = maxDebt - bankDebt
        if ffDebt <= 0 || avgFfRate <= 0 { return 99 }
        if headroom <= ffDebt { return 0 }
        return log(headroom / ffDebt) / log(1 + avgFfRate)
    }
    static func effectiveLiquidationPrice(totalDebt: Double, totalBtc: Double) -> Double {
        totalBtc > 0 ? totalDebt / (totalBtc * RiskConstants.ffLiquidationLtv) : 0
    }
    static func breakEvenPrice(totalDebt: Double, totalBtc: Double, initialBtc: Double) -> Double {
        totalBtc > initialBtc ? totalDebt / (totalBtc - initialBtc) : 0
    }
    // build(...) -> RiskMetrics: složí výše uvedené + scénáře (6 cen + extra +200k páka).
    // Scénáře: ceny [ath*0.20, price*0.5, price*0.75, price, price*1.5, price*2.5].
}
```
> `build(...)` (kompletní agregace + scénáře) implementuj dle spec sekce F; každou dílčí funkci pokryj testem. Pokud je `build` velké, rozsekni na `buildScenarios`, `buildMaturity`, `buildTax` se samostatnými testy.

- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(risk): RiskMetricsUseCase — LTV/likvidace/udržitelnost/scénáře (port z C#)`.

---

### Task 5: Maturity alerty + LTV monitoring

**Files:** Create `MaturityAlertService.swift`; Test (alert na 7 dní, critical na 0).
> Port ProductionEngine.cs:705-799. Používá existující `NotificationService` + `notificationDao`.

- [ ] **Step 1: Padající test**
```swift
final class MaturityAlertTests: XCTestCase {
    func test_alertWithin7Days() {
        let today = Date()
        let due = Calendar.current.date(byAdding: .day, value: 5, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: due, today: today), .upcoming(daysLeft: 5))
    }
    func test_criticalWhenOverdue() {
        let today = Date()
        let past = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: past, today: today), .overdue)
    }
    func test_noneWhenFar() {
        let today = Date()
        let far = Calendar.current.date(byAdding: .day, value: 30, to: today)!
        XCTAssertEqual(MaturityAlertService.evaluate(maturity: far, today: today), .none)
    }
}
```
- [ ] **Step 2-3: Implementuj** `MaturityAlertService` — čistá `evaluate(maturity:today:) -> Alert` (`.none`/`.upcoming(daysLeft:)`/`.overdue`) + metoda `run(loans:)` co pro `.upcoming`/`.overdue` vytvoří `AppNotification` přes `notificationDao` (mirror `saveInAppNotification`). LTV monitoring: pro každou aktivní FF půjčku spočti LTV; když `>= ltvWarningThreshold (0.80)`, vytvoř varování. Zavolej `run` v `executeDuePlans` (po resolve pending).
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(alerts): maturity + LTV alerty (port z C#)`.

---

### Task 6: Loany v SnapshotService + obnova

**Files:** Modify `SnapshotService.swift`.

- [ ] **Step 1: Rozšiř `build`** — přidej `firefishLoans`/`bankLoans` z `db.firefishLoanDao.getAll()` / `db.bankLoanDao.getAll()` mapované na `AppSnapshot.FirefishLoan`/`BankLoan` (datumy přes `dayFmt`).
- [ ] **Step 2: Rozšiř `load`** — `deleteAll` + `upsertBatch` pro obě loan tabulky z `snap.firefishLoans`/`snap.bankLoans`; nahraj i transakce a strategii (vytvoř/aktualizuj NUPL `DcaPlan` z `snap.strategy`: amount = baseChunkCzk×baseChunkMultiplier, strategy = `.nupl(config z snap)`, lastExecutedAt = lastProcessedDate).
- [ ] **Step 3: Test** — round trip s loany (rozšiř `SnapshotServiceTests`). **Step 4: Commit** `feat(snapshot): loany + strategie + transakce v build/load`.

---

### Task 7: Risk cockpit UI

**Files:** Create `RiskCockpitView.swift`, `RiskCockpitViewModel.swift`; přidat tab/odkaz do `MainTabView`/Dashboard.
> UI navazuje na existující styl (`AccBotTheme`, `PlanCard`, Dashboard sekce). Lehčí task — žádné unit testy (jen build).

- [ ] **Step 1: ViewModel** — `@MainActor final class RiskCockpitViewModel: ObservableObject` s `@Published var metrics: RiskMetrics?`; v `load()` načte holdingy/loany z DAO + ceny (`marketDataService.getCurrentPrice` + `getAllTimeHigh`) → `RiskMetricsUseCase.build(...)`.
- [ ] **Step 2: View** — sekce: cockpit dlaždice (LTV badge dle `RiskLevel` barvy, likvidační cena, nejbližší maturita, daňový rozpad free/taxable/nextExemption), scénářová tabulka (6 cen), profit v BTC. Použij `AccBotTheme` barvy a existující komponenty.
- [ ] **Step 3: Napojení** — přidej do `MainTabView` (nebo jako drill-in z Dashboard/Portfolio). Ověř lazy tab (vzor z `2015c3a`).
- [ ] **Step 4: Ověř build (CI). Step 5: Commit** `feat(ui): risk cockpit (LTV/likvidace/scénáře/daně)`.

---

## Self-review (spec coverage Plánu 3)

- **D. FF/bank půjčky + výpočty** → Task 1 (calc) + Task 2 (persistence). ✓
- **D. LIFO collateral alokace** → není v Phase 2 MVP nutná pro zobrazení rizika (alokace se přebírá z C# migrace přes `loanId` na holdingech); přidat až při tvorbě nové půjčky v appce → **odloženo, zdokumentováno** (zatím se loany zadávají/migrují, nealokují v appce).
- **E. Daně 3letý test + FIFO** → Task 3. ✓
- **F. Risk cockpit + scénáře** → Task 4 (logika) + Task 7 (UI). ✓
- **F. effectiveLiq, yearsSustainable, breakEven** → Task 4. ✓
- **Maturity alerty + LTV monitoring** → Task 5. ✓
- **Loany v záloze/obnově** → Task 6. ✓
- **Migrace loanů** → Plán 2 Task 6 (convert.py už loany řeší). ✓

## Otevřené body (předané)

- **LIFO collateral alokace** (CollateralService.cs) — potřeba až když půjde vytvořit FF půjčku přímo v appce; pro Phase 2 (zobrazení + migrace existujících) stačí `loanId` na holdingech. Naplánovat samostatně, pokud bude potřeba.
- `RiskMetricsUseCase.build` je velký — při implementaci rozsekni na podfunkce (scenarios/maturity/tax) s vlastními testy.
- Tax sazba 0.15 vs 0.23 (high income) — kde nastavit (UserPreferences?).
- UI scénářové tabulky — sladit s C# zobrazením (6 řádků + „+200k FF" podlinka).
