import SwiftUI

/// Přehledová karta na vrcholu Dashboardu: čisté jmění (hodnota BTC − dluhy)
/// jako hlavní číslo, vizuální stacked bar equity vs. dluh (LTV), a rozpad
/// na držené BTC, hodnotu a jednotlivé dluhy. Klepnutí → správa půjček / risk.
struct NetWorthCard: View {
    let summary: DashboardViewModel.NetWorthSummary
    var onTapLoans: () -> Void = {}
    var onTapRisk: () -> Void = {}

    @Environment(\.accBotColors) private var colors
    @AppStorage("hideNetWorth") private var hideNetWorth = true

    private func mask(_ s: String) -> String { hideNetWorth ? "••••••" : s }

    /// Podíl equity (zelená) z celkové hodnoty aktiv, 0...1. Zbytek = dluh (oranžová).
    private var equityFraction: Double {
        guard let value = summary.btcValueCzk,
              Double(truncating: value as NSDecimalNumber) > 0,
              let net = summary.netWorthCzk else { return 0 }
        let v = Double(truncating: value as NSDecimalNumber)
        let n = Double(truncating: net as NSDecimalNumber)
        return min(max(n / v, 0), 1)
    }

    private var ltvColor: Color {
        guard let ltv = summary.ltvPercent else { return colors.onSurfaceVariant }
        if ltv < 35 { return colors.success }
        if ltv < 55 { return colors.warning }
        return colors.error
    }

    private var netWorthColor: Color {
        guard let net = summary.netWorthCzk else { return colors.onSurface }
        return net >= 0 ? colors.onSurface : colors.error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            netWorthValue
            if !hideNetWorth, !runwayRows.isEmpty {
                runwayBlock
            }
            if summary.btcValueCzk != nil {
                equityBar
            }
            statTiles
            Divider().background(colors.onSurfaceVariant.opacity(0.2))
            debtRows
        }
        .padding(Spacing.lg)
        .background(colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(String(localized: "Čisté jmění"))
                .font(AccBotFonts.titleSmall)
                .foregroundStyle(colors.onSurface)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let ltv = summary.ltvPercent {
                Text(String(localized: "LTV \(Int(ltv.rounded())) %"))
                    .font(AccBotFonts.caption)
                    .foregroundStyle(ltvColor)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 2)
                    .background(ltvColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            Button { hideNetWorth.toggle() } label: {
                Image(systemName: hideNetWorth ? "eye.slash" : "eye")
                    .font(AccBotFonts.caption).foregroundStyle(colors.onSurfaceVariant)
            }
            .accessibilityLabel(String(localized: "Skrýt/zobrazit čisté jmění"))
        }
    }

    // MARK: - Net worth headline

    private var netWorthValue: some View {
        Text(mask(summary.netWorthCzk.map { AccBotFormatters.formatFiat($0, symbol: "CZK") } ?? "—"))
            .font(AccBotFonts.titleLarge)
            .foregroundStyle(netWorthColor)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .accessibilityLabel(String(localized: "Čisté jmění"))
            .accessibilityValue(summary.netWorthCzk.map { AccBotFormatters.formatFiat($0, symbol: "CZK") } ?? String(localized: "Neznámé"))
    }

    // MARK: - Runway „na nulu" (jak rychle dojde jmění při baseline deficitu)

    private struct RunwayRow: Identifiable {
        let label: String
        let months: Double
        let deficit: Int
        var id: String { label }
    }

    /// Tři odhady, kolik vydrží jmění: baseline (medián), skutečnost posl. 3 měs, tento cyklus (živě).
    private var runwayRows: [RunwayRow] {
        var rows: [RunwayRow] = []
        if let m = summary.runwayMonths(summary.monthlyDeficitCzk) {
            rows.append(RunwayRow(label: String(localized: "baseline"), months: m, deficit: summary.monthlyDeficitCzk))
        }
        if let m = summary.runwayMonths(summary.recentDeficitCzk) {
            rows.append(RunwayRow(label: String(localized: "posl. 3 měs"), months: m, deficit: summary.recentDeficitCzk))
        }
        if let m = summary.runwayMonths(summary.currentDeficitCzk) {
            rows.append(RunwayRow(label: String(localized: "tento cyklus"), months: m, deficit: summary.currentDeficitCzk))
        }
        return rows
    }

    private var runwayBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "hourglass")
                    .font(AccBotFonts.captionSmall).foregroundStyle(colors.warning)
                Text(String(localized: "Jmění vydrží (runway na nulu)"))
                    .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
            }
            ForEach(runwayRows) { r in
                HStack(spacing: Spacing.sm) {
                    Text(r.label)
                        .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
                        .frame(width: 84, alignment: .leading)
                    Text(String(localized: "~\(yearsMonths(r.months)) · do \(targetMonth(r.months))"))
                        .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurface)
                    Spacer(minLength: Spacing.xs)
                    Text(String(localized: "−\(AccBotFormatters.formatFiat(Decimal(r.deficit), symbol: "CZK"))/měs"))
                        .font(AccBotFonts.captionSmall).foregroundStyle(colors.warning)
                }
            }
        }
    }

    private func yearsMonths(_ months: Double) -> String {
        let m = max(0, Int(months.rounded()))
        let y = m / 12, mm = m % 12
        if y > 0 && mm > 0 { return "\(y) r \(mm) m" }
        if y > 0 { return "\(y) r" }
        return "\(mm) m"
    }

    private static let myFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/yyyy"; f.locale = Locale(identifier: "cs_CZ"); return f
    }()
    private func targetMonth(_ months: Double) -> String {
        let d = Calendar.current.date(byAdding: .month, value: max(0, Int(months.rounded())), to: Date()) ?? Date()
        return Self.myFmt.string(from: d)
    }

    // MARK: - Equity vs. debt bar

    private var equityBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // Celá šířka = hodnota aktiv; oranžová spodní vrstva = dluh.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(colors.warning.opacity(0.85))
                    // Zelená překryje equity část zleva.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(colors.success)
                        .frame(width: max(0, w * equityFraction))
                }
            }
            .frame(height: 10)

            HStack(spacing: Spacing.md) {
                legendDot(colors.success, String(localized: "Vlastní"))
                legendDot(colors.warning, String(localized: "Dluh"))
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(AccBotFonts.captionSmall)
                .foregroundStyle(colors.onSurfaceVariant)
        }
    }

    // MARK: - Stat tiles (held BTC + value)

    private var statTiles: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(String(localized: "Drženo"))
                    .font(AccBotFonts.caption)
                    .foregroundStyle(colors.onSurfaceVariant)
                Text(mask(AccBotFormatters.formatCrypto(summary.heldBtc, symbol: "BTC")))
                    .font(AccBotFonts.body)
                    .foregroundStyle(colors.onSurface)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Text(String(localized: "Hodnota"))
                    .font(AccBotFonts.caption)
                    .foregroundStyle(colors.onSurfaceVariant)
                Text(mask(summary.btcValueCzk.map { AccBotFormatters.formatFiat($0, symbol: "CZK") } ?? "—"))
                    .font(AccBotFonts.body)
                    .foregroundStyle(colors.onSurface)
            }
        }
    }

    // MARK: - Debt rows (tappable → loans / risk)

    private var debtRows: some View {
        VStack(spacing: Spacing.sm) {
            if summary.firefishDebtCzk > 0 {
                Button(action: onTapLoans) {
                    debtRow(
                        icon: "bolt.fill",
                        title: String(localized: "Firefish (\(summary.firefishLoanCount))"),
                        amount: summary.firefishDebtCzk,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            if summary.bankDebtCzk > 0 {
                Button(action: onTapLoans) {
                    debtRow(
                        icon: "building.columns.fill",
                        title: String(localized: "Banka"),
                        amount: summary.bankDebtCzk,
                        showChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
            if summary.firefishLoanCount > 0 {
                Button(action: onTapRisk) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(AccBotFonts.caption)
                            .foregroundStyle(colors.primary)
                        Text(String(localized: "Riziko likvidace"))
                            .font(AccBotFonts.label)
                            .foregroundStyle(colors.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(AccBotFonts.captionSmall)
                            .foregroundStyle(colors.onSurfaceVariant)
                    }
                    .contentShape(Rectangle())
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func debtRow(icon: String, title: String, amount: Decimal, showChevron: Bool) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(AccBotFonts.caption)
                .foregroundStyle(colors.warning)
                .frame(width: 20)
            Text(title)
                .font(AccBotFonts.body)
                .foregroundStyle(colors.onSurface)
            Spacer()
            Text(mask(AccBotFormatters.formatFiat(amount, symbol: "CZK")))
                .font(AccBotFonts.body)
                .foregroundStyle(colors.onSurface)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(AccBotFonts.captionSmall)
                    .foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: 36)
    }
}
