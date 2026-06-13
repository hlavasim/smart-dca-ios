# Smart DCA iOS

Nativní iOS klient pro automatizovaný BTC DCA (Dollar-Cost Averaging) s chytrými
strategiemi. Osobní iOS-zaměřený klon, který rozšiřuju o **NUPL strategii**,
**import transakcí** a **git-based zálohu stavu** (a později Firefish pákové
půjčky + český daňový režim).

## Atribuce

Tohle je derivát projektu **[AccBot](https://github.com/Crynners/AccBot)**
(MIT © 2021 Crynners). iOS klient původně napsal převážně **Jan Hnízdil (SOFTIM)**.
Pokračuje pod stejnou MIT licencí — viz [`LICENSE`](LICENSE).

## Sestavení a instalace

App se distribuuje **mimo App Store** přes SideStore/AltStore:

- **GitHub Actions** (`.github/workflows/ios-build.yml`) při každém pushi do
  `main` / `release/**` / `feature/**` automaticky sestaví **nepodepsanou `.ipa`**
  (bez jakýchkoli secrets) a nahraje ji jako artifact `AccBot-unsigned.ipa`.
  Stáhneš artifact → SideStore ji re-signuje tvým Apple ID a nainstaluje.
- Lokálně (macOS + Xcode): `cd accbot-ios && xcodegen generate && open AccBot.xcodeproj`.

Repo je veřejné záměrně — Actions na public repech běží zdarma (vč. macOS runnerů).

## Data a soukromí

**V tomhle repu nejsou žádná osobní finanční data.** Holdingy, přiřazení do
půjček a daňové stáří se zálohují do **samostatného privátního repa**, kam app
po každém DCA běhu pushne snapshot stavu.

## Tech stack

.NET-free, čistý Swift / SwiftUI, lokální **GRDB/SQLite**, architektura
Data / Domain / Presentation. Projekt generuje **xcodegen** z `accbot-ios/project.yml`.
