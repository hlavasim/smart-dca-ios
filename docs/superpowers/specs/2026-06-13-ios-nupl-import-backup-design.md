# iOS Phase 1 — NUPL strategie, migrace z C#, git záloha

**Datum:** 2026-06-13
**Status:** Schváleno (návrh), čeká na implementační plán
**Repo:** [smart-dca-ios](https://github.com/hlavasim/smart-dca-ios) (public) + [smart-dca-data](https://github.com/hlavasim/smart-dca-data) (private)

## Kontext a cíl

`smart-dca-ios` je nativní SwiftUI klient (derivát [AccBot](https://github.com/Crynners/AccBot),
~25k LOC, čistá architektura Data/Domain/Presentation, lokální GRDB/SQLite, 7 burz
vč. CoinMate). Cílem je, aby **nahradil** stávajícího C# bota
`smart-dca-leveraged-local-first` — webová/konzolová varianta přestala vyhovovat.

**Phase 1** přenese do iOS appky jádro toho, co dělá C# bot:
1. **NUPL DCA strategii** (signature metoda uživatele)
2. **jednorázovou migraci** existujících dat z C# (holdingy/transakce/stav, CZK)
3. **automatickou git zálohu** stavu + on-device catch-up exekuci

**Phase 2** (samostatný spec, později): Firefish pákové půjčky, český daňový režim
(3letý test, FIFO), alerty splatnosti, risk cockpit (LTV/likvidace).

## Klíčová rozhodnutí (z brainstormingu)

| Rozhodnutí | Volba | Důvod |
|---|---|---|
| Role iOS appky | **Nahradí C# bota** | Web/konzole nevyhovuje; iOS bude exekutor i přehled |
| Spolehlivost exekuce | **On-device + catch-up** | Žádný server; zmeškané dny se dokoupí při otevření, každý se svým historickým NUPL |
| Sync/záloha | **Git push (GitHub API)** | Přímý, potvrzený (commit SHA), na rozdíl od iCloud Drive (líný/neprůhledný upload) neřeší OS |
| Distribuce | **SideStore (nepodepsaná .ipa z CI)** | Mimo App Store → vylučuje CloudKit/iCloud Keychain (placené entitlements) |
| Klíče (CoinMate API) | **Nezálohují se** | Na novém zařízení se vygenerují znovu |
| Repo strategie | **Public app repo + private data repo** | CI zdarma (public), citlivá data v privátu; $0 náklad |
| Import z C# | **Konverzní skript → nativní formát** | App nemá C# parser; import = obnova (jedna vstupní cesta) |

## Architektura — přehled

```
┌─────────────────────────┐         ┌──────────────────────────┐
│  smart-dca-leveraged-    │  one-   │   konverzní skript       │
│  local-first (C# JSON)   │──time──▶│  C# JSON → snapshot.json │
│  holdings/transactions/  │         └────────────┬─────────────┘
│  state                   │                      │ push
└─────────────────────────┘                       ▼
                                       ┌──────────────────────────┐
   ┌──────────────────────┐  pull/     │  smart-dca-data (private)│
   │   iOS app (GRDB)     │◀─push──────│  snapshot.json (plain)   │
   │   - NUPL strategie   │            └──────────────────────────┘
   │   - DCA + catch-up   │
   │   - CoinMate buy     │  fetch     ┌──────────────────────────┐
   │   - NUPL history sync│◀───────────│  bitcoin-data.com (NUPL) │
   └──────────────────────┘            │  CoinMate (cena, balance)│
                                       └──────────────────────────┘
```

**Import = obnova:** migrace z C# i disaster recovery sdílí jednu vstupní cestu
„stáhni `snapshot.json` z gitu → nahraj do GRDB".

---

## A. Rozsah a fázování

**Phase 1 (tento spec):** NUPL strategie · migrace z C# · git záloha/obnova + catch-up.

**Phase 2 (deferred, samostatný spec):** FF půjčky · daně (3letý test, FIFO) ·
alerty splatnosti · risk cockpit.

**Schéma s výhledem na Phase 2:** holdingy už v Phase 1 nesou `acquisitionDate`
a snapshot má pole `version`, aby Phase 2 mohla přidat `loanId` / tax-lot pole bez
bolestivé migrace. Logika půjček/daní se přidá až v Phase 2; schéma se nechá připravené.

## B. NUPL strategie

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

Konfig hodnoty (0.0 / 0.5 / 0.5 / 3.0) převzaté z C# `config/settings.json`.
Příklady: NUPL 0.25 → 1.75×; 0.10 → 2.5×; 0.40 → 1.0×.

**Denní chunk:** `baseChunk = baseChunkCzk × baseChunkMultiplier`,
`dailyChunk = baseChunk × multiplier` (stejně jako C#).

**Datový zdroj NUPL:** `bitcoin-data.com` (jako C#). Do `MarketDataService` přibyde
`getNupl(date)` + **historická synchronizace** — nová tabulka `nupl_values`
(crypto, dateEpochDay, nupl, fetchedAt) + `SyncNuplUseCase`, zrcadlí stávající
`SyncDailyPricesUseCase` (forward fill + historical backfill).

**Catch-up s věrným NUPL:** každý zmeškaný den použije **svůj historický NUPL** z
`nupl_values` (ne dnešní) — odpovídá C# fixu `136ebe0`.

**Refresh cash před nákupem (port C# fixu):** před kontrolou dostupné hotovosti
app obnoví `availableCash` z **živého CoinMate zůstatku** (nenulový přepíše uloženou
hodnotu; nula = možná chyba API → ponechat). Odpovídá C# fixu `a43c97c` — bez toho
vznikají falešné „Insufficient cash" skipy po vkladu na burzu.

**Po nákupu** se hned spustí git záloha (sekce D).

## C. Migrace z C# (konverzní skript)

- **Samostatný skript** (běží jednou na Windows) přečte `holdings.json`,
  `transactions.json`, `state.json` ze `smart-dca-leveraged-local-first`, namapuje
  do snapshot formátu (sekce E) a commitne `snapshot.json` do **smart-dca-data**.
- Mapování: C# `BtcHoldingDb` → holding s `acquisitionDate`; `TransactionDb` →
  transaction; `StrategyState` (LastProcessedDate, AvailableCashCzk, BaseChunkCzk,
  NUPL config) → strategy state. Vše CZK.
- **iOS app nemá žádný C# parser** — čte jen nativní snapshot.
- Umístění skriptu a jazyk se rozhodne v plánu (kandidáti: Python, nebo C# protože
  zdroj je C#). Skript je bez osobních dat → může žít i ve public repu pod `tools/`.

## D. Git záloha / obnova

**Snapshot:** jeden `snapshot.json` v smart-dca-data; verzovaná historie přirozeně
přes git commity.

**Záloha (push):**
- Trigger: po každém DCA běhu + po významné změně stavu (nový holding, změna plánu).
- Mechanika: serializace GRDB stavu → `PUT /repos/hlavasim/smart-dca-data/contents/snapshot.json`
  přes GitHub Contents API (potřebuje aktuální blob SHA → nejdřív `GET`).
- Potvrzení: úspěch = commit SHA. Selhání → retry při příštím spuštění; UI ukazuje
  „poslední záloha před X / čeká se".

**Obnova (pull):**
- Při čisté instalaci / v nastavení: `GET` `snapshot.json` → deserializace → nahrání
  do GRDB. **Stejná cesta pro migraci i recovery.**

**Formát:** plain JSON (private repo, API klíče uvnitř nejsou → diffovatelné).
Šifrování případně později jako volitelné.

**Auth:** GitHub **PAT v iOS Keychain** (scope: jen `smart-dca-data`). Nastaví se
jednou. Při ztrátě zařízení se PAT vygeneruje znovu.

**Konflikty:** jedno aktivní zařízení → pull-then-push, last-write-wins. Žádná
CRDT/merge složitost. (Multi-device není cíl Phase 1.)

## E. Snapshot schéma

Plain JSON, zrcadlí GRDB tabulky potřebné pro obnovu. Náčrt:

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
      "loanId": null }
  ],
  "transactions": [
    { "date": "2026-06-05", "type": "DCA_PURCHASE",
      "amountBtc": "0.0123", "amountCzk": "-16100",
      "btcPriceCzk": "1310069", "exchangeOrderId": "..." }
  ]
}
```

`version` umožní Phase 2 přidat `loans`, `taxLots` a pole `loanId`/`acquisitionDate`
využít pro daňové stáří bez rozbití starších snapshotů. Decimaly jako string
(přesnost, konzistentní s GRDB TEXT).

## F. Testy (TDD)

- **NUPL multiplikátor:** test vektory z C# — NUPL 0.0→3.0×, 0.25→1.75×, 0.5→0.5×,
  0.6→0.5× (clamp), null→1.0×.
- **Catch-up:** N zmeškaných dnů → každý použije svůj historický NUPL z `nupl_values`,
  ne dnešní.
- **Refresh cash:** živý CoinMate zůstatek přepíše uloženou cash; nula ponechá uloženou;
  výjimka při dotazu ponechá uloženou (port C# `DcaCashRefreshTests`).
- **Snapshot round-trip:** serialize → deserialize → rovnost (věrnost migrace i recovery).
- **Konverzní skript:** golden test — vzorek C# JSON → očekávaný `snapshot.json`.

## Non-goals (Phase 1)

- Firefish půjčky, daně, alerty splatnosti, risk cockpit (→ Phase 2).
- Multi-device real-time sync / CRDT (jen single-device git záloha).
- Šifrování snapshotu (plain JSON v private repu stačí).
- CloudKit / iCloud Keychain (nekompatibilní se SideStore signingem).

## Otevřené body pro plán

- Jazyk a umístění konverzního skriptu.
- Přesné schéma `nupl_values` a integrace `SyncNuplUseCase` do startup/refresh toku.
- UI: kde v appce zobrazit stav zálohy a NUPL náhled (drobnost, navazuje na existující Dashboard).
- Onboarding pro PAT (kde a jak ho uživatel zadá).
