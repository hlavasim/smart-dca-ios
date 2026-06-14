# Plán 4 — Lifecycle půjček (LIFO) + prodej BTC s FIFO daní

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Plný lifecycle půjček v appce — vytvoření/top-up/splacení FF (s LIFO alokací kolaterálu a split holdingů zachovávajícím daňové metadaty), vytvoření/splátky bankovní půjčky (anuita), a prodej BTC s FIFO cost basis + českým daňovým eventem.

**Architecture:** `CollateralService` = čistá `planAllocation` (LIFO) + IO `apply`/`release` nad `HoldingDao`. Lifecycle use-casy port 1:1 z C# (`BtcOperationsService`, `CollateralService`, `Tui/TuiApp`). Prodej BTC = FIFO alokace nejstarších holdingů + `BtcSale` transakce s daňovými poli. Vše čisté funkce kde to jde → testovatelné bez DB/sítě.

**Tech Stack:** Swift / GRDB / XCTest. Zdroj pravdy: `smart-dca-leveraged-local-first` (`Services/CollateralService.cs`, `Services/BtcOperationsService.cs`, `Models/FirefishLoan.cs`, `Models/BankLoan.cs`, `Models/FifoAllocationDb.cs`).

**Předpoklad:** Plány 1–3 hotové (holdings/loans tabulky, FF/Bank modely, RiskMetrics, TaxRules, FirefishLoanDao/BankLoanDao).

## ⚠️ Verifikace na CI (žádný Mac) — viz Plán 1. Kadence per-task.

Pracovní větev: `feature/loan-lifecycle-btc-sale`.

## Klíčové invarianty (z C#)

- **LIFO** kolaterál: ber **nejnovější** holdingy first → chrání 3letou daňovou výjimku starých.
- **Split zachovává** `acquisitionDate` + `purchasePriceCzk` + `source` (kvůli FIFO dani).
- **Epsilon** pro BTC porovnání: `0.00000001`.
- **Splacení neprodává** — kolaterál se jen uvolní (`isCollateralized=false`, `loanId=nil`); žádný daňový event.
- **FF poplatek 1,5 % p.a. se platí v BTC** (`btcFeeAmount`), CoinMate trading fee v CZK.
- **Prodej BTC** = jediná FIFO daňová událost (nejstarší lots first; >1095 dní osvobozeno; daní se jen zisk).

## Soubory

```
accbot-ios/AccBot/
  Domain/UseCase/CollateralService.swift             (NEW — planAllocation/apply/release)
  Data/Local/Database/Dao/HoldingDao.swift           (MODIFY — getFree/getByLoanId)
  Domain/UseCase/CreateFirefishLoanUseCase.swift     (NEW)
  Domain/UseCase/TopUpCollateralUseCase.swift        (NEW)
  Domain/UseCase/RepayFirefishLoanUseCase.swift      (NEW)
  Domain/UseCase/BankLoanUseCase.swift               (NEW — create + payment + catch-up)
  Domain/UseCase/SellBtcUseCase.swift                (NEW — FIFO daň)
  Exchange/CoinmateApi.swift                         (MODIFY — marketSell)
  Exchange/ExchangeApi.swift                         (MODIFY — marketSell protokol)
  Data/Local/UserPreferences.swift                  (MODIFY — taxRate)
  Data/Local/Database/Records/FifoAllocationRecord.swift (NEW)
  Data/Local/Database/Dao/FifoAllocationDao.swift    (NEW)
  Data/Local/Database/DcaDatabase.swift             (MODIFY — v8 fifo_allocations)
  Presentation/Screens/Loans/...                     (NEW — UI, lehčí)
accbot-ios/AccBotTests/
  CollateralServiceTests.swift, LoanLifecycleTests.swift, SellBtcFifoTests.swift
```

---

### Task 1: HoldingDao rozšíření + CollateralService.planAllocation (LIFO, čistá)

**Files:** Modify `HoldingDao.swift`; Create `CollateralService.swift`; Test `CollateralServiceTests.swift`.

- [ ] **Step 1: HoldingDao dotazy**
```swift
    func getFree() throws -> [HoldingRecord] {
        try dbPool.read { try HoldingRecord.filter(Column("isCollateralized") == false).fetchAll($0) }
    }
    func getByLoanId(_ loanId: String) throws -> [HoldingRecord] {
        try dbPool.read { try HoldingRecord.filter(Column("loanId") == loanId).fetchAll($0) }
    }
    func update(_ r: HoldingRecord) throws { try dbPool.write { try r.update($0) } }
```

- [ ] **Step 2: Padající test planAllocation** (port detailního C# příkladu CollateralService.cs:36-76)
```swift
import XCTest
@testable import AccBot
final class CollateralServiceTests: XCTestCase {
    func h(_ id: String,_ amt: Double,_ acqEpoch: Double) -> HoldingRecord {
        HoldingRecord(id: id, amount: "\(amt)", acquisitionDate: acqEpoch, purchasePriceCzk: "0",
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0)
    }
    func test_lifo_markWholeAndSplit() {
        // A 0.5 (nejnovější), B 1.0, C 0.3 ; potřeba 1.2 → A celé, B split 0.7/0.3
        let free = [h("A",0.5, 300), h("B",1.0, 200), h("C",0.3, 100)]
        let plan = CollateralService.planAllocation(free: free, amountBtc: 1.2, loanId: "L1")
        XCTAssertEqual(plan.markWhole, ["A"])
        XCTAssertEqual(plan.splits.count, 1)
        XCTAssertEqual(plan.splits[0].sourceHoldingId, "B")
        XCTAssertEqual(Double(plan.splits[0].collateralAmount)!, 0.7, accuracy: 1e-9)
        XCTAssertEqual(Double(plan.splits[0].remainingFree)!, 0.3, accuracy: 1e-9)
    }
}
```
- [ ] **Step 3: Implementuj** `CollateralService.swift` (pure planAllocation)
```swift
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

enum CollateralService {
    static let epsilon = 0.00000001

    /// LIFO: nejnovější holdingy first. Čistá funkce (žádné IO).
    static func planAllocation(free: [HoldingRecord], amountBtc: Double, loanId: String) -> AllocationPlan {
        var plan = AllocationPlan()
        var remaining = amountBtc
        let sorted = free.sorted { $0.acquisitionDate > $1.acquisitionDate }  // DESC
        for h in sorted {
            if remaining <= 0 { break }
            let amt = Double(h.amount) ?? 0
            let use = min(amt, remaining)
            if use >= amt - epsilon {
                plan.markWhole.append(h.id)
            } else {
                plan.splits.append(.init(
                    sourceHoldingId: h.id,
                    remainingFree: "\(amt - use)",
                    collateralAmount: "\(use)",
                    acquisitionDate: h.acquisitionDate,
                    purchasePriceCzk: h.purchasePriceCzk,
                    source: h.source))
            }
            remaining -= use
        }
        return plan
    }
}
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(collateral): LIFO planAllocation + HoldingDao dotazy`.

---

### Task 2: CollateralService.apply / release (IO nad HoldingDao)

**Files:** Modify `CollateralService.swift`; Test (in-memory DB).

- [ ] **Step 1: Padající test** — apply → source zkrácen + nový collateral holding; release → uvolnění
```swift
func test_apply_marksAndSplits() throws {
    let db = try DcaDatabase(path: nil)
    try db.holdingDao.upsertBatch([
        HoldingRecord(id: "A", amount: "0.5", acquisitionDate: 300, purchasePriceCzk: "0",
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0),
        HoldingRecord(id: "B", amount: "1.0", acquisitionDate: 200, purchasePriceCzk: "0",
            isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0),
    ])
    try CollateralService.apply(db: db, amountBtc: 1.2, loanId: "L1")
    let all = try db.holdingDao.getAll()
    // A celé collateralized, B zkráceno na 0.3 + nový holding 0.7 collateralized
    XCTAssertEqual(try db.holdingDao.getByLoanId("L1").count, 2)
    let bFree = all.first { $0.id == "B" }!
    XCTAssertEqual(Double(bFree.amount)!, 0.3, accuracy: 1e-9)
    XCTAssertFalse(bFree.isCollateralized)
}
func test_release_freesCollateral() throws {
    let db = try DcaDatabase(path: nil)
    try db.holdingDao.upsert(HoldingRecord(id: "A", amount: "0.5", acquisitionDate: 300,
        purchasePriceCzk: "0", isCollateralized: true, loanId: "L1", isAvailableForDca: false,
        source: "X", notes: "", createdAt: 0))
    try CollateralService.release(db: db, loanId: "L1")
    let a = try db.holdingDao.getAll().first!
    XCTAssertFalse(a.isCollateralized)
    XCTAssertNil(a.loanId)
}
```
- [ ] **Step 2-3: Implementuj** (do `enum CollateralService`)
```swift
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
            h.isCollateralized = false; h.loanId = nil
            try db.holdingDao.update(h)
        }
    }
    static func totalFree(db: DcaDatabase) throws -> Double {
        try db.holdingDao.getFree().reduce(0) { $0 + (Double($1.amount) ?? 0) }
    }
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(collateral): apply/release (split zachovává daňové metadaty)`.

---

### Task 3: CreateFirefishLoanUseCase (FF poplatek v BTC)

**Files:** Create `CreateFirefishLoanUseCase.swift`; Test.
> Port BtcOperationsService.cs:263-325 + TuiApp.cs:1457-1565.

- [ ] **Step 1: Padající test**
```swift
final class LoanLifecycleTests: XCTestCase {
    func test_createFF_allocatesAndComputesFee() throws {
        let db = try DcaDatabase(path: nil)
        try db.holdingDao.upsert(HoldingRecord(id: "A", amount: "0.2", acquisitionDate: 300,
            purchasePriceCzk: "0", isCollateralized: false, loanId: nil, isAvailableForDca: true,
            source: "X", notes: "", createdAt: 0))
        let uc = CreateFirefishLoanUseCase(db: db)
        let loan = try uc.create(externalId: "FF1", loanAmountCzk: 50000, collateralBtc: 0.1,
            durationDays: 365, interestRate: 0.10, btcFeeRate: 0.015, btcPriceAtLoan: 1_000_000,
            loanDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(loan.totalRepaymentCzk, 55000, accuracy: 0.01)
        XCTAssertEqual(loan.btcFeeAmount, 0.00075, accuracy: 1e-8)   // 50000*0.015*1/1_000_000
        XCTAssertEqual(try db.firefishLoanDao.getActive().count, 1)
        XCTAssertEqual(try db.holdingDao.getByLoanId("FF1").count, 1)  // 0.1 alokováno
    }
    func test_createFF_insufficientFree_throws() throws {
        let db = try DcaDatabase(path: nil)
        let uc = CreateFirefishLoanUseCase(db: db)
        XCTAssertThrowsError(try uc.create(externalId: "FF1", loanAmountCzk: 50000, collateralBtc: 0.1,
            durationDays: 365, interestRate: 0.10, btcFeeRate: 0.015, btcPriceAtLoan: 1_000_000, loanDate: Date()))
    }
}
```
- [ ] **Step 2-3: Implementuj**
```swift
import Foundation
enum LoanError: Error { case insufficientFreeBtc }

final class CreateFirefishLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    @discardableResult
    func create(externalId: String, loanAmountCzk: Decimal, collateralBtc: Decimal,
                durationDays: Int, interestRate: Decimal, btcFeeRate: Decimal,
                btcPriceAtLoan: Decimal, loanDate: Date) throws -> FirefishLoan {
        let free = try CollateralService.totalFree(db: db)
        guard Double(truncating: collateralBtc as NSNumber) <= free + CollateralService.epsilon else {
            throw LoanError.insufficientFreeBtc
        }
        let maturity = Calendar.current.date(byAdding: .day, value: durationDays, to: loanDate) ?? loanDate
        let loan = FirefishLoan(externalLoanId: externalId, loanDate: loanDate, maturityDate: maturity,
            durationDays: durationDays, loanAmountCzk: loanAmountCzk, interestRate: interestRate,
            btcFeeRate: btcFeeRate, btcPriceAtLoan: btcPriceAtLoan, collateralBtcAmount: collateralBtc,
            isRepaid: false)
        // alokuj kolaterál (LIFO)
        try CollateralService.apply(db: db, amountBtc: Double(truncating: collateralBtc as NSNumber), loanId: externalId)
        // ulož loan (mapuj na record)
        try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(
            externalLoanId: externalId, loanDate: loanDate.timeIntervalSince1970,
            maturityDate: maturity.timeIntervalSince1970, durationDays: durationDays,
            loanAmountCzk: "\(loanAmountCzk)", interestRate: "\(interestRate)", btcFeeRate: "\(btcFeeRate)",
            btcPriceAtLoan: "\(btcPriceAtLoan)", collateralBtcAmount: "\(collateralBtc)", isRepaid: false)])
        // transakce: cash in + BTC fee jako náklad (informativně)
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: loanAmountCzk, cryptoAmount: 0, price: 0, fee: 0, status: .completed,
            exchangeOrderId: "FF-\(externalId)", warningMessage: "FF fee \(loan.btcFeeAmount) BTC"))
        return loan
    }
}
```
> FF `btcFeeAmount` (1,5 % p.a. v BTC) se počítá z modelu a uloží do popisu transakce jako BTC náklad. (CoinMate trading fee je řešen v `marketBuy` v CZK — sem nepatří.)
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(loans): vytvoření FF půjčky (LIFO kolaterál + BTC fee)`.

---

### Task 4: TopUpCollateralUseCase (manuální + auto LTV)

**Files:** Create `TopUpCollateralUseCase.swift`; Test.
> Port BtcOperationsService.cs:478-515 + auto: LTV≥0.80 → addBtc = collateral×0.20.

- [ ] **Step 1: Padající test**
```swift
func test_topUp_addsCollateralLifo() throws {
    let db = try DcaDatabase(path: nil)
    // existující půjčka FF1 s 0.1 kolaterálem + volný holding 0.1
    try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(externalLoanId: "FF1", loanDate: 0,
        maturityDate: 0, durationDays: 365, loanAmountCzk: "50000", interestRate: "0.1",
        btcFeeRate: "0.015", btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: false)])
    try db.holdingDao.upsert(HoldingRecord(id: "F", amount: "0.1", acquisitionDate: 400,
        purchasePriceCzk: "0", isCollateralized: false, loanId: nil, isAvailableForDca: true,
        source: "X", notes: "", createdAt: 0))
    let uc = TopUpCollateralUseCase(db: db)
    try uc.topUp(externalId: "FF1", addBtc: 0.05)
    XCTAssertEqual(try db.holdingDao.getByLoanId("FF1").map { Double($0.amount)! }.reduce(0,+), 0.05, accuracy: 1e-9)
    let loan = try db.firefishLoanDao.getActive().first!
    XCTAssertEqual(Double(loan.collateralBtcAmount)!, 0.15, accuracy: 1e-9)
}
func test_autoTopUpAmount() {
    XCTAssertEqual(TopUpCollateralUseCase.autoAmount(collateralBtc: 2.0), 0.4, accuracy: 1e-9) // 20 %
}
```
- [ ] **Step 2-3: Implementuj**
```swift
import Foundation
final class TopUpCollateralUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    /// auto top-up množství při LTV≥warning: 20 % aktuálního kolaterálu.
    static func autoAmount(collateralBtc: Double) -> Double { collateralBtc * RiskConstants.ltvTopUpPercentage }

    func topUp(externalId: String, addBtc: Double) throws {
        guard addBtc <= (try CollateralService.totalFree(db: db)) + CollateralService.epsilon else {
            throw LoanError.insufficientFreeBtc
        }
        try CollateralService.apply(db: db, amountBtc: addBtc, loanId: externalId)
        guard var loan = try db.firefishLoanDao.getActive().first(where: { $0.externalLoanId == externalId }) else { return }
        let newColl = (Double(loan.collateralBtcAmount) ?? 0) + addBtc
        loan.collateralBtcAmount = "\(newColl)"
        try db.firefishLoanDao.upsertBatch([loan])
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: 0, cryptoAmount: Decimal(addBtc), price: 0, fee: 0, status: .completed,
            exchangeOrderId: "TOPUP-\(externalId)"))
    }
}
```
> Auto top-up volání (LTV monitoring) napoj v `MaturityAlertService` (Plán 3 Task 5) nebo `executeDuePlans`: při LTV≥0.80 zavolej `topUp(autoAmount)` pokud je dost volných BTC, jinak alert.
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(loans): top-up kolaterálu (manuální + auto LTV)`.

---

### Task 5: RepayFirefishLoanUseCase

**Files:** Create `RepayFirefishLoanUseCase.swift`; Test.
> Port BtcOperationsService.cs:330-361. Uvolní kolaterál, žádný prodej/daň.

- [ ] **Step 1: Padající test**
```swift
func test_repay_marksRepaidAndReleasesCollateral() throws {
    let db = try DcaDatabase(path: nil)
    try db.firefishLoanDao.upsertBatch([FirefishLoanRecord(externalLoanId: "FF1", loanDate: 0,
        maturityDate: 0, durationDays: 365, loanAmountCzk: "50000", interestRate: "0.1",
        btcFeeRate: "0.015", btcPriceAtLoan: "1000000", collateralBtcAmount: "0.1", isRepaid: false)])
    try db.holdingDao.upsert(HoldingRecord(id: "A", amount: "0.1", acquisitionDate: 300,
        purchasePriceCzk: "0", isCollateralized: true, loanId: "FF1", isAvailableForDca: false,
        source: "X", notes: "", createdAt: 0))
    try RepayFirefishLoanUseCase(db: db).repay(externalId: "FF1")
    XCTAssertTrue(try db.firefishLoanDao.getAll().first!.isRepaid)
    XCTAssertEqual(try db.firefishLoanDao.getActive().count, 0)
    let a = try db.holdingDao.getAll().first!
    XCTAssertFalse(a.isCollateralized); XCTAssertNil(a.loanId)
}
```
- [ ] **Step 2-3: Implementuj**
```swift
import Foundation
final class RepayFirefishLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }
    func repay(externalId: String) throws {
        guard var loan = try db.firefishLoanDao.getAll().first(where: { $0.externalLoanId == externalId }) else { return }
        loan.isRepaid = true
        try db.firefishLoanDao.upsertBatch([loan])
        try CollateralService.release(db: db, loanId: externalId)  // uvolni kolaterál, NEPRODÁVÁ
        let repay = (Decimal(string: loan.loanAmountCzk) ?? 0) * (1 + (Decimal(string: loan.interestRate) ?? 0) * Decimal(loan.durationDays) / 365)
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: repay, cryptoAmount: 0, price: 0, fee: 0, status: .completed,
            exchangeOrderId: "REPAY-\(externalId)"))
    }
}
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(loans): splacení FF (uvolnění kolaterálu, bez prodeje/daně)`.

---

### Task 6: BankLoanUseCase (vytvoření + splátky + catch-up)

**Files:** Create `BankLoanUseCase.swift`; Test.
> Port BtcOperationsService.cs:106-253.

- [ ] **Step 1: Padající test**
```swift
final class BankLoanUseCaseTests: XCTestCase {
    func test_create_setsMonthlyAndRemaining() throws {
        let db = try DcaDatabase(path: nil)
        let uc = BankLoanUseCase(db: db)
        let id = try uc.create(principalCzk: 1_000_000, annualRate: 0.07, durationMonths: 120,
            loanDate: Date(timeIntervalSince1970: 1_700_000_000))
        let l = try db.bankLoanDao.getActive().first!
        XCTAssertEqual(Double(l.remainingPrincipalCzk)!, 1_000_000, accuracy: 1)
        XCTAssertEqual(l.id, id)
    }
    func test_payment_splitsInterestPrincipal() throws {
        let db = try DcaDatabase(path: nil)
        let uc = BankLoanUseCase(db: db)
        let id = try uc.create(principalCzk: 1_000_000, annualRate: 0.07, durationMonths: 120, loanDate: Date())
        try uc.recordPayment(id: id, months: 1)
        let l = try db.bankLoanDao.getActive().first!
        // interest = 1M*0.07/12 ≈ 5833; principal ≈ 6040; remaining ≈ 993960
        XCTAssertEqual(Double(l.remainingPrincipalCzk)!, 993_960, accuracy: 50)
    }
}
```
- [ ] **Step 2-3: Implementuj** (create počítá anuitu z `BankLoan.monthlyPaymentCzk`; recordPayment iteruje měsíce: interest = remaining×rate/12, principal = monthly − interest, remaining −= principal; finální splátka nastaví isFullyPaid; catchUp spočítá due měsíce dle nextPaymentDate≤today).
```swift
import Foundation
final class BankLoanUseCase {
    private let db: DcaDatabase
    init(db: DcaDatabase) { self.db = db }

    @discardableResult
    func create(principalCzk: Decimal, annualRate: Decimal, durationMonths: Int, loanDate: Date) throws -> String {
        let model = BankLoan(principalCzk: principalCzk, annualInterestRate: annualRate,
            durationMonths: durationMonths, remainingPrincipalCzk: principalCzk,
            nextPaymentDate: Calendar.current.date(byAdding: .month, value: 1, to: loanDate) ?? loanDate,
            isFullyPaid: false)
        let id = model.id
        try db.bankLoanDao.upsertBatch([BankLoanRecord(id: id, principalCzk: "\(principalCzk)",
            annualInterestRate: "\(annualRate)", durationMonths: durationMonths,
            remainingPrincipalCzk: "\(principalCzk)",
            nextPaymentDate: model.nextPaymentDate.timeIntervalSince1970, isFullyPaid: false)])
        return id
    }

    func recordPayment(id: String, months: Int) throws {
        guard var rec = try db.bankLoanDao.getActive().first(where: { $0.id == id }) else { return }
        let rate = (Double(rec.annualInterestRate) ?? 0) / 12.0
        let monthly = BankLoan(principalCzk: Decimal(string: rec.principalCzk) ?? 0,
            annualInterestRate: Decimal(string: rec.annualInterestRate) ?? 0,
            durationMonths: rec.durationMonths, remainingPrincipalCzk: 0, nextPaymentDate: Date(), isFullyPaid: false)
            .monthlyPaymentCzk
        let monthlyD = Double(truncating: monthly as NSNumber)
        var remaining = Double(rec.remainingPrincipalCzk) ?? 0
        var next = Date(timeIntervalSince1970: rec.nextPaymentDate)
        for _ in 0..<months {
            if remaining <= 0 { break }
            let interest = remaining * rate
            let principalPortion = monthlyD - interest
            if principalPortion >= remaining {
                remaining = 0; rec.isFullyPaid = true
            } else {
                remaining -= principalPortion
                next = Calendar.current.date(byAdding: .month, value: 1, to: next) ?? next
            }
        }
        rec.remainingPrincipalCzk = "\(remaining)"
        rec.nextPaymentDate = next.timeIntervalSince1970
        try db.bankLoanDao.upsertBatch([rec])
    }

    /// Catch-up: spočti due měsíce (nextPaymentDate ≤ today) a aplikuj.
    func catchUp(today: Date = Date()) throws {
        for rec in try db.bankLoanDao.getActive() {
            var due = 0; var pd = Date(timeIntervalSince1970: rec.nextPaymentDate)
            while pd <= today { due += 1; pd = Calendar.current.date(byAdding: .month, value: 1, to: pd) ?? pd }
            if due > 0 { try recordPayment(id: rec.id, months: due) }
        }
    }
}
```
- [ ] **Step 4: Ověř pass (CI). Step 5: Commit** `feat(loans): bankovní půjčka (anuita, splátky, catch-up)`.

---

### Task 7: Prodej BTC s FIFO daní

**Files:** Modify `ExchangeApi.swift` (+ `CoinmateApi.swift` marketSell); Create `FifoAllocationRecord.swift`, `FifoAllocationDao.swift`, `SellBtcUseCase.swift`; Modify `DcaDatabase.swift` (v8); `UserPreferences.swift` (taxRate). Test `SellBtcFifoTests.swift`.
> App je dnes buy-only → přidáváme sell. Sell je **CoinMate-only** (páka/daně jsou CoinMate/CZK).

- [ ] **Step 1: marketSell na CoinMate** — do `ExchangeApi` protokolu přidej `func marketSell(crypto:fiat:cryptoAmount:) async -> DcaResult` (default impl `return .error(message:"sell unsupported", retryable:false)` v extension). V `CoinmateApi` implementuj přes `/sellInstant` (mirror `marketBuy`: body `currencyPair` + `amount` = BTC množství; reconcile přes `tradeHistory` side=SELL).

- [ ] **Step 2: fifo_allocations tabulka (v8)** — záznam daňové alokace prodeje:
```swift
struct FifoAllocationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "fifo_allocations"
    var id: String
    var saleDate: Double
    var sourceHoldingId: String
    var allocatedBtc: String
    var acquisitionPriceCzk: String
    var salePriceCzk: String
    var profitCzk: String
    var daysHeld: Int
    var isExempt: Bool
    var taxAmountCzk: String
}
```
Migrace v8 + `fifoAllocationDao` (upsertBatch/getAll/deleteAll).

- [ ] **Step 3: UserPreferences.taxRate** — `var taxRate: Double` (default 0.15; UI přepínač 0.15/0.23 high income).

- [ ] **Step 4: Padající test FIFO** (nejstarší lots first; >1095 dní osvobozeno)
```swift
final class SellBtcFifoTests: XCTestCase {
    func test_fifo_consumesOldestFirst_andTaxesYoungGain() throws {
        let db = try DcaDatabase(path: nil)
        // starý lot 1 BTC (>3 roky, osvobozen) + mladý 1 BTC (<3 roky)
        let old = Date().addingTimeInterval(-200*86400*20).timeIntervalSince1970   // ~>3y
        let young = Date().addingTimeInterval(-100*86400).timeIntervalSince1970
        try db.holdingDao.upsertBatch([
            HoldingRecord(id: "OLD", amount: "1.0", acquisitionDate: old, purchasePriceCzk: "1000000",
                isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0),
            HoldingRecord(id: "YOUNG", amount: "1.0", acquisitionDate: young, purchasePriceCzk: "1000000",
                isCollateralized: false, loanId: nil, isAvailableForDca: true, source: "X", notes: "", createdAt: 0),
        ])
        // prodej 1.5 BTC @ 2M; taxRate 0.15
        let alloc = SellBtcUseCase.fifoAllocate(holdings: try db.holdingDao.getFree(),
            sellAmount: 1.5, salePrice: 2_000_000, taxRate: 0.15, saleDate: Date())
        XCTAssertEqual(alloc.count, 2)
        XCTAssertEqual(alloc[0].sourceHoldingId, "OLD")    // nejstarší first
        XCTAssertTrue(alloc[0].isExempt)                    // >3 roky → daň 0
        XCTAssertEqual(Double(alloc[0].taxAmountCzk)!, 0, accuracy: 0.01)
        // 0.5 BTC z young: zisk (2M-1M)*0.5 = 500k, daň 0.15 → 75k
        XCTAssertFalse(alloc[1].isExempt)
        XCTAssertEqual(Double(alloc[1].taxAmountCzk)!, 75_000, accuracy: 1)
    }
}
```
- [ ] **Step 5: Implementuj** `SellBtcUseCase.swift`
```swift
import Foundation
final class SellBtcUseCase {
    private let db: DcaDatabase
    private let coinmate: CoinmateApi
    private let taxRate: Double
    init(db: DcaDatabase, coinmate: CoinmateApi, taxRate: Double) {
        self.db = db; self.coinmate = coinmate; self.taxRate = taxRate
    }

    /// Čistá FIFO alokace (nejstarší free holdingy first). Bez IO.
    static func fifoAllocate(holdings: [HoldingRecord], sellAmount: Double, salePrice: Double,
                             taxRate: Double, saleDate: Date) -> [FifoAllocationRecord] {
        var remaining = sellAmount
        var out: [FifoAllocationRecord] = []
        for h in holdings.sorted(by: { $0.acquisitionDate < $1.acquisitionDate }) {  // ASC = nejstarší first
            if remaining <= 0 { break }
            let amt = Double(h.amount) ?? 0
            let use = min(amt, remaining)
            let acqPrice = Double(h.purchasePriceCzk) ?? 0
            let daysHeld = Int((saleDate.timeIntervalSince1970 - h.acquisitionDate) / 86400)
            let gain = SmartGainTax.fifoGain(amount: use, acquisitionPrice: acqPrice, salePrice: salePrice,
                daysHeld: daysHeld, taxRate: taxRate)
            out.append(FifoAllocationRecord(id: UUID().uuidString, saleDate: saleDate.timeIntervalSince1970,
                sourceHoldingId: h.id, allocatedBtc: "\(use)", acquisitionPriceCzk: "\(acqPrice)",
                salePriceCzk: "\(salePrice)", profitCzk: "\(gain.profit)", daysHeld: daysHeld,
                isExempt: gain.isExempt, taxAmountCzk: "\(gain.taxAmount)"))
            remaining -= use
        }
        return out
    }

    /// Provede prodej: CoinMate sell → spotřebuj holdingy (FIFO) → ulož FifoAllocation + BtcSale tx.
    func sell(cryptoAmount: Decimal) async throws {
        let result = await coinmate.marketSell(crypto: "BTC", fiat: "CZK", cryptoAmount: cryptoAmount)
        guard case .success(let tx) = result else { return }
        let free = try db.holdingDao.getFree()
        let allocs = Self.fifoAllocate(holdings: free, sellAmount: Double(truncating: cryptoAmount as NSNumber),
            salePrice: Double(truncating: tx.price as NSNumber), taxRate: taxRate, saleDate: Date())
        try db.fifoAllocationDao.upsertBatch(allocs)
        // sniž/odstraň spotřebované holdingy (dle allocs) — update HoldingDao
        try applyHoldingReduction(allocs)
        try? db.transactionDao.insert(Transaction(planId: 0, exchange: .coinmate, crypto: "BTC", fiat: "CZK",
            fiatAmount: tx.fiatAmount, cryptoAmount: tx.cryptoAmount, price: tx.price, fee: tx.fee,
            feeAsset: tx.feeAsset, status: .completed, exchangeOrderId: tx.exchangeOrderId))
    }
    private func applyHoldingReduction(_ allocs: [FifoAllocationRecord]) throws {
        // pro každý alloc: sniž source holding o allocatedBtc; když dojde na 0, smaž.
        for a in allocs {
            guard var h = try db.holdingDao.getAll().first(where: { $0.id == a.sourceHoldingId }) else { continue }
            let left = (Double(h.amount) ?? 0) - (Double(a.allocatedBtc) ?? 0)
            if left <= CollateralService.epsilon { try db.holdingDao.delete(id: h.id) }
            else { h.amount = "\(left)"; try db.holdingDao.update(h) }
        }
    }
}
```
> `SmartGainTax.fifoGain` = `TaxRules.fifoGain` z Plánu 3 (přejmenuj konzistentně na `TaxRules`). Přidej `HoldingDao.delete(id:)`.
- [ ] **Step 6: Ověř pass (CI). Step 7: Commit** `feat(sell): prodej BTC s FIFO cost basis + daň (CoinMate marketSell)`.

---

### Task 8: UI — správa půjček + prodej (lehčí)

**Files:** Create `Presentation/Screens/Loans/LoanManagementView.swift` (+ ViewModel), formuláře create/topup/repay/sell; napoj do `MainTabView`/Risk cockpit.
- [ ] Formuláře volají use-casy z Tasků 3–7; po operaci spusť git zálohu (Plán 2 `backupAfterChange`). Bez unit testů (jen build). Daňová sazba přepínač → `UserPreferences.taxRate`.
- [ ] **Commit** `feat(ui): správa půjček + prodej BTC`.

---

## Self-review (spec coverage Plánu 4)

- **LIFO alokace + split (daňové metadaty)** → Task 1+2. ✓
- **FF vytvoření (BTC fee 1,5 % p.a.)** → Task 3. ✓
- **Top-up (manuální + auto LTV 0.80/0.20)** → Task 4. ✓
- **FF splacení (uvolnění kolaterálu, bez prodeje)** → Task 5. ✓
- **Bank vytvoření + splátky (anuita) + catch-up** → Task 6. ✓
- **Prodej BTC + FIFO daň (3letý test, jen zisk)** → Task 7. ✓
- **Daňová sazba 0.15/0.23** → Task 7 Step 3 (UserPreferences). ✓

## Otevřené body (předané)

- `CoinmateApi.marketSell` přes `/sellInstant` — ověřit přesný endpoint/parametry CoinMate API (mirror `buyInstant`).
- `ExchangeApi.marketSell` default no-op pro ostatní burzy (sell je CoinMate-only).
- Konverzní skript (Plán 2) už migruje loany; ověřit, že `loanId` na holdingech sedí s `externalLoanId`.
- Auto top-up vs jen alert: rozhodnout UX (Task 4 — auto provést, nebo jen navrhnout?).
