# iOS port C# bota — NUPL, migrace, git záloha, FF páka, daně, risk

**Datum:** 2026-06-13
**Status:** Schváleno (návrh), čeká na implementační plán
**Repo:** [smart-dca-ios](https://github.com/hlavasim/smart-dca-ios) (public) + [smart-dca-data](https://github.com/hlavasim/smart-dca-data) (private)

## Kontext a cíl

`smart-dca-ios` je nativní SwiftUI klient (derivát [AccBot](https://github.com/Crynners/AccBot),
~25k LOC, čistá architektura Data/Domain/Presentation, lokální GRDB/SQLite, 7 burz
vč. CoinMate). Cílem je, aby **plně nahradil** C# bota `smart-dca-leveraged-local-first`.

Rozsah se sloučil do **jednoho specu** (Phase 1 + Phase 2) — uživatel chce testovat
až celek najednou. Implementace přesto poběží ve fázích (P1 jako základ, P2 nad ním),
ale dodá se a otestuje dohromady.

- **Phase 1:** NUPL strategie · migrace z C# · git záloha/obnova + on-device catch-up.
- **Phase 2:** Firefish pákové půjčky · bankovní půjčky · daně (CZ 3letý test + FIFO) ·
  risk cockpit (LTV/likvidace/scénáře) · alerty splatnosti + LTV auto top-up.
- **Průřezově:** bezpečnost exekuce — idempotence buy orderů + ošetření timeoutů
  (sekce G), aby catch-up nikdy nezpůsobil runaway/duplicitní nákup.

## Klíčová rozhodnutí (z brainstormingu)

| Rozhodnutí | Volba | Důvod |
|---|---|---|
| Role iOS appky | **Nahradí C# bota** | Web/konzole nevyhovuje; iOS = exekutor i přehled |
| Spolehlivost exekuce | **On-device + catch-up** | Žádný server; zmeškané dny se dokoupí, každý se svým historickým NUPL |
| Sync/záloha | **Git push (GitHub API)** | Přímý, potvrzený (commit SHA); iCloud Drive má líný/neprůhledný upload |
| Distribuce | **SideStore (nepodepsaná .ipa z CI)** | Mimo App Store → vylučuje CloudKit/iCloud Keychain (placené entitlements) |
| Klíče (CoinMate API) | **Nezálohují se** | Na novém zařízení se vygenerují znovu |
| Repo strategie | **Public app repo + private data repo** | CI zdarma (public), citlivá data v privátu; $0 náklad |
| Import z C# | **Konverzní skript → nativní formát** | App nemá C# parser; import = obnova (jedna vstupní cesta) |
| Měna | **CZK** všude | CoinMate CZK trh |

## Architektura — přehled

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  smart-dca-leveraged-    │  one-   │   konverzní skript       │
│  local-first (C# JSON)   │──time──▶│  C# JSON → snapshot.json │
└─────────────────────────┘         └────────────┬─────────────┘
                                                  │ push
                                                  ▼
   ┌──────────────────────┐  pull/    ┌──────────────────────────┐
   │   iOS app (GRDB)     │◀─push─────│  smart-dca-data (private)│
   │   P1: NUPL DCA       │           │  snapshot.json (plain)   │
   │   + catch-up + buy   │           └──────────────────────────┘
   │   P2: FF/bank loans, │  fetch    ┌──────────────────────────┐
   │   daně, risk cockpit │◀──────────│  bitcoin-data.com (NUPL) │
   │   G: idempotent buys │           │  CoinMate (cena, balance)│
   └──────────────────────┘           └──────────────────────────┘
```

**Import = obnova:** migrace z C# i disaster recovery sdílí jednu vstupní cestu
„stáhni `snapshot.json` z gitu → nahraj do GRDB".

---

# Phase 1

## A. NUPL strategie

**Port 1:1 z C#** (`TuiDcaService.CalculateMultiplier`) jako **spojitá** strategie —
žádná diskretizace na tiery. V `DcaStrategy` enumu přibyde case `.nupl(config)` a
`CalculateStrategyMultiplierUseCase` dostane větev s interpolací:

```
NUPL ≤ NuplBottomValue (0.0)  → NuplMaxMultiplier (3.0×)
NUPL ≥ NuplCenterValue (0.5)  → NuplMinMultiplier (0.5×)
mezi tím:
  range    = NuplCenterValue - NuplBottomValue        // 0.5
  position = (NUPL - NuplBottomValue) / range
  mult     = NuplMaxMultiplier - position·(NuplMaxMultiplier - NuplMinMultiplier)
NUPL nedostupné → 1.0× (fallback)
```

Konfig (0.0 / 0.5 / 0.5 / 3.0) z C# `config/settings.json`.
Příklady: NUPL 0.25 → 1.75×; 0.10 → 2.5×; 0.40 → 1.0×.

**Denní chunk:** `baseChunk = baseChunkCzk × baseChunkMultiplier`,
`dailyChunk = baseChunk × multiplier`.

**Datový zdroj NUPL:** `bitcoin-data.com`. Do `MarketDataService` přibyde
`getNupl(date)` + **historická sync** — tabulka `nupl_values`
(crypto, dateEpochDay, nupl, fetchedAt) + `SyncNuplUseCase`, zrcadlí
`SyncDailyPricesUseCase` (forward fill + historical backfill).

**Catch-up s věrným NUPL:** každý zmeškaný den použije **svůj historický NUPL** z
`nupl_values` (ne dnešní) — odpovídá C# fixu `136ebe0`.

**Refresh cash před nákupem (port C# fixu `a43c97c`):** před kontrolou hotovosti
app obnoví `availableCash` z **živého CoinMate zůstatku** (nenulový přepíše uloženou
hodnotu; nula = možná chyba API → ponechat). Bez toho falešné „Insufficient cash" skipy.

## B. Migrace z C# (konverzní skript)

- **Samostatný skript** (běží jednou na Windows) přečte `holdings.json`,
  `transactions.json`, `state.json` ze `smart-dca-leveraged-local-first`, namapuje
  do snapshot formátu (sekce F) a commitne `snapshot.json` do **smart-dca-data**.
- Mapování: `BtcHoldingDb` → holding s `acquisitionDate` (+ `isCollateralized`, `loanId`);
  `TransactionDb` → transaction; `StrategyState` → strategy state. Vše CZK.
- **iOS app nemá žádný C# parser** — čte jen nativní snapshot.
- Jazyk/umístění skriptu → rozhodne plán (kandidáti: Python, nebo C# kvůli modelům).

## C. Git záloha / obnova

**Snapshot:** jeden `snapshot.json` v smart-dca-data; verzovaná historie přes git commity.

**Záloha (push):** po každém DCA běhu + významné změně stavu → serializace GRDB →
`PUT /repos/hlavasim/smart-dca-data/contents/snapshot.json` (předtím `GET` kvůli blob SHA).
Úspěch = commit SHA; selhání → retry příště; UI „poslední záloha před X".

**Obnova (pull):** při čisté instalaci / v nastavení → `GET snapshot.json` → deserializace
→ GRDB. **Stejná cesta pro migraci i recovery.**

**Formát:** plain JSON (private repo, klíče uvnitř nejsou → diffovatelné).

**Auth:** GitHub **PAT v iOS Keychain** (scope: jen `smart-dca-data`), nastaví se jednou.

**Konflikty:** jedno aktivní zařízení → pull-then-push, last-write-wins. Žádná CRDT.

---

# Phase 2

> Veškerá logika níže je **port 1:1 z C#** `smart-dca-leveraged-local-first`.
> Reference jsou na C# soubory/řádky (zdroj pravdy pro vzorce).

## D. Firefish (FF) + bankovní půjčky

**FF loan model** (`Models/FirefishLoan.cs`): `externalLoanId`, `loanDate`,
`maturityDate`, `durationDays`, `loanAmountCzk`/`principalCzk`, `interestRate` (p.a.),
`btcFeeRate` (p.a. v BTC), `btcPriceAtLoan`, `collateralBtcAmount`, `isRepaid`, `repaidDate`.

Vzorce (FirefishLoan.cs:49-63):
```
yearFraction   = durationDays / 365.0
interestCzk    = loanAmountCzk · interestRate · yearFraction
totalRepayment = loanAmountCzk + interestCzk
feeInCzk       = loanAmountCzk · btcFeeRate · yearFraction
btcFeeAmount   = feeInCzk / btcPriceAtLoan
```

**Bank loan** (`Models/BankLoan.cs`) — měsíčně amortizovaná (anuita), nouzový nástroj
proti likvidaci: `principalCzk`, `annualInterestRate`, `durationMonths`,
`monthlyPaymentCzk`, `remainingPrincipalCzk`, `nextPaymentDate`, `isFullyPaid`.
```
monthlyRate = annualRate / 12
factor      = (1 + monthlyRate)^durationMonths
monthlyPay  = principal · (monthlyRate·factor) / (factor − 1)   // 0% → principal/months
```

**Collateral alokace — LIFO** (`Services/CollateralService.cs:36-76`): kolaterál se bere
z **nejnovějších** holdingů (chrání 3letou daňovou výjimku starých). Výstup `MarkWhole`
(celé) + `Splits` (rozdělené na free/collateral část). Třídit `acquisitionDate DESC`,
brát `min(amount, remaining)` dokud `remaining > 0`.

## E. Daně (CZ 3letý test + FIFO)

**3letý test** (`RiskConstants.TaxFreeYears = 3`): holding je osvobozený, když
`acquisitionDate.AddYears(3) <= today` (kalendářní, ne 365·3).

**Klasifikace** (RiskMetricsService.cs:194-208):
```
cutoff      = today.AddYears(-3)
taxFree     = Σ holdings(acquisitionDate ≤ cutoff)       // osvobozené
taxable     = totalBtc − taxFree                          // zdanitelné
nextExempt  = min(acquisitionDate of taxable) + 3 roky    // nejbližší osvobození
nextExemptBtc = Σ holdings dozrávajících v [nextExempt, +30 dní]
```

**FIFO cost basis při prodeji** (`Models/FifoAllocationDb.cs`): nejstarší lots first.
```
acquisitionCost = allocatedBtc · acquisitionPrice
saleRevenue     = allocatedBtc · salePrice
profit          = saleRevenue − acquisitionCost
daysHeld        = saleDate − acquisitionDate
meetsTimeTest   = daysHeld ≥ 1095  (→ daň 0)
taxableProfit   = profit (jen zisky; ztráty neodečítají)
taxRate         = 0.15 (std) / 0.23 (high income)
taxAmount       = taxableProfit · taxRate
```

## F. Risk cockpit + scénáře (`Services/RiskMetricsService.cs`)

**Konstanty:** `FfLiquidationLtv 0.95` · `FfWarnHigh 0.86` (danger) · `FfWarnLow 0.73`
(warning) · `FfOriginationLtv 0.50` (max nová půjčka).

**Per-loan:** `ltv = totalRepayment / (collateralBtc · price)` ·
`liqPrice = totalRepayment / (collateralBtc · 0.95)` ·
`bufferPct = (price − liqPrice)/price` · `liqFromAthPct = (liqPrice − ath)/ath`.

**Agregace:** worstLtv · highestLiqPrice · `effectiveLiqPrice = totalDebt/(totalBtc·0.95)`
(bankrot i při zastavení všeho) · totalLtv · `additionalBorrowCapacity = max(0, totalBtc·price·0.50 − totalDebt)`.

**Maturita:** nextMaturityDate = min(FF maturityDate) · daysUntil · amountCzk ·
`btcToSell = amount/price` · `canRefinance = freeBtc·price·0.50 ≥ amount`.

**Udržitelnost (infinite roll):**
```
yearsAtPrice(price, btc, ffDebt):
  maxDebt  = btc · price · 0.95
  headroom = maxDebt − bankDebt
  if ffDebt ≤ 0 || avgFfRate ≤ 0: 99
  if headroom ≤ ffDebt: 0
  else: ln(headroom/ffDebt) / ln(1 + avgFfRate)
avgFfRate = Σ(rate·repayment)/Σ(repayment)   // vážený
```

**Profit v BTC:** `netBtcAfterDebt = totalBtc − totalDebt/price` ·
`netBtcVsInitialPct = netBtc/initialBtc − 1` ·
`breakEvenPrice = totalDebt/(totalBtc − initialBtc)` (0 když nemožné).

**Scénáře (6 cen):** −80 % od ATH (ATH·0.20, hard floor) · −50 % · −25 % · současná ·
+50 % · +150 %. Per scénář: worstLtv, survives (lze zastavit dost <95 %?),
collateralToAddBtc, freeBtcAfterTopUp, additionalBorrowCapacity, yearsSustainable,
btcVsInitialPct + varianta „+200k FF půjčka navíc" (extra páka).

## G. Bezpečnost exekuce — idempotence + timeouty

> **Nejdůležitější sekce.** Bot pohybuje reálnými penězi a Phase 1 přidává catch-up
> smyčku — přesně to, co v původním repu způsobilo chybný nákup.

**Známý bug (commit `2015c3a`, už v našem snapshotu — zachovat):** `marketBuy()`
fallbackoval na `getCurrentPrice() ?? 1`; když selhalo i price API, `80 CZK / 1 = 80 BTC`.
Fix: při nedostupné ceně/trade details vrať `.pending` s `cryptoAmount = 0`
(CoinmateApi.swift:67-81). **Nikdy** neodvozovat množství z fallback ceny 1.

**Požadavky na novou catch-up + buy logiku:**

1. **Idempotentní nákupy** — každý `(plán, den)` koupí **max jednou**. Idempotency klíč
   (`planId + date`) se zapíše **před** síťovým voláním; při re-runu/retry se podle něj
   zjistí, že nákup už proběhl. Dedup persistovaný (= C# invariant „každý CoinMate
   nákup uloží dedup záznam", [[coinmate-write-dedup-invariant]]).

2. **Timeout = neznámý výsledek, ne důvod k re-buy.** `marketBuy` má 30 s timeout +
   retry. Po timeoutu se **neopakuje nákup naslepo** — nejdřív **rekonciliace**: dotaz
   na recent orders/transakce podle idempotency klíče; nový order se pošle jen když je
   potvrzeno, že předchozí **nedopadl**. Jinak `.pending`.

3. **Postup jen po potvrzení.** `lastProcessedDate`/`nextExecutionAt` se posune **až po
   potvrzeném completed nákupu**. Pending/neznámý stav neposouvá a neopakuje nákup.

4. **Pending reconciliation** (`ResolvePendingTransactionsUseCase`): nevyřešené nákupy
   → `.pending`; později se spárují s order history burzy (idempotency klíč / orderId)
   → complete/discard. Žádný re-buy bez rekonciliace.

5. **Omezený catch-up.** Strop dnů na jeden běh + throttle „skip `executeDuePlans()`
   když poslední běh < 5 min" (commit `2015c3a`, zachovat). Frekvence < 4 h jsou v iOS
   pozadí nespolehlivé — pro denní NUPL OK.

6. **Sanity ceny.** Množství nikdy z fallback ceny 1; odmítnout/pending když implikovaná
   cena výrazně utíká od spotu.

---

## Snapshot schéma (Phase 1+2)

Plain JSON, zrcadlí GRDB tabulky. `version` umožní evoluci.

```json
{
  "version": 1,
  "exportedAt": "2026-06-13T21:00:00Z",
  "fiat": "CZK",
  "strategy": {
    "type": "NUPL",
    "nuplBottomValue": 0.0, "nuplCenterValue": 0.5,
    "nuplMinMultiplier": 0.5, "nuplMaxMultiplier": 3.0,
    "baseChunkCzk": 2308.36, "baseChunkMultiplier": 0.8,
    "lastProcessedDate": "2026-06-09", "availableCashCzk": 3984.23
  },
  "holdings": [
    { "amount": "0.0123", "acquisitionDate": "2026-06-05",
      "purchasePriceCzk": "1310069", "source": "DCA",
      "isCollateralized": false, "loanId": null }
  ],
  "transactions": [
    { "date": "2026-06-05", "type": "DCA_PURCHASE", "amountBtc": "0.0123",
      "amountCzk": "-16100", "btcPriceCzk": "1310069", "exchangeOrderId": "..." }
  ],
  "firefishLoans": [
    { "externalLoanId": "FF-123", "loanDate": "2026-01-10",
      "maturityDate": "2027-01-10", "loanAmountCzk": "50000",
      "interestRate": "0.10", "btcFeeRate": "0.015",
      "btcPriceAtLoan": "1200000", "collateralBtcAmount": "0.08",
      "isRepaid": false }
  ],
  "bankLoans": [
    { "principalCzk": "763300", "annualInterestRate": "0.07",
      "durationMonths": 120, "remainingPrincipalCzk": "750000",
      "nextPaymentDate": "2026-07-01", "isFullyPaid": false }
  ]
}
```

Decimaly jako string (přesnost, konzistentní s GRDB TEXT). FIFO alokace se odvozují
z holdingů + transakcí (neukládají se do snapshotu zvlášť, dokud nenastane prodej).

## Testy (TDD)

**Phase 1:**
- NUPL multiplikátor: 0.0→3.0×, 0.25→1.75×, 0.5→0.5×, 0.6→0.5× (clamp), null→1.0×.
- Catch-up: N zmeškaných dnů → každý svůj historický NUPL.
- Refresh cash: živý zůstatek přepíše uloženou; nula/výjimka ponechá uloženou (port `DcaCashRefreshTests`).
- Snapshot round-trip: serialize → deserialize → rovnost.
- Konverzní skript: golden test — vzorek C# JSON → očekávaný snapshot.

**Phase 2:**
- FF: interest/fee/totalRepayment; bank anuita; LIFO collateral alokace.
- Daně: 3letý test (1095 dní / AddYears(3)), klasifikace free/taxable/nextExempt, FIFO profit + daň.
- Risk: ltv, liqPrice, effectiveLiqPrice, yearsSustainable, breakEvenPrice, scénáře (6 cen + extra páka).
- Maturita: alert na 7 dní, critical na 0 dní; LTV auto top-up práh 0.80.

**Bezpečnost exekuce (G):**
- Timeout při marketBuy → **žádný druhý order** (rekonciliace, ne naslepo retry).
- Re-run catch-upu přes N dnů → přesně N orderů (idempotence).
- Pending nákup → vyřeší se z order history, neposune `lastProcessedDate`.
- Nedostupná cena → `.pending`, `cryptoAmount = 0` (nikdy /1).

## Non-goals

- Multi-device real-time sync / CRDT (jen single-device git záloha).
- Šifrování snapshotu (plain JSON v private repu stačí).
- CloudKit / iCloud Keychain (nekompatibilní se SideStore signingem).
- Další burzy nad rámec CoinMate pro NUPL/páku (ostatní burzy zůstávají z AccBotu, ale FF/daně jsou CoinMate/CZK).

## Otevřené body pro plán

- Jazyk a umístění konverzního skriptu.
- Idempotency mechanismus buy orderů: client order id (pokud CoinMate podporuje) vs. rekonciliace přes order history.
- Schéma `nupl_values` + integrace `SyncNuplUseCase` do startup/refresh toku.
- GRDB migrace pro nové tabulky (firefish_loans, bank_loans, fifo_allocations) + holding pole `acquisitionDate`/`isCollateralized`/`loanId`.
- UI: risk cockpit + NUPL náhled + stav zálohy (navázat na existující Dashboard).
- Onboarding pro GitHub PAT.
