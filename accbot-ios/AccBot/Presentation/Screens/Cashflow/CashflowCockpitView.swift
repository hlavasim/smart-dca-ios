import SwiftUI

/// Cashflow kokpit — hero je VÝHLED do výplaty (vyjdeš/zbyde, runway, safe-to-spend), ne strašení.
/// Fio (živě) + ruční útraty proti baseline.
struct CashflowCockpitView: View {
    @StateObject private var vm: CashflowCockpitViewModel
    @Environment(\.accBotColors) private var colors

    @State private var showAddSpend = false
    @State private var amountText = ""
    @State private var selectedCategory = ""
    @State private var noteText = ""

    init(deps: AppDependencies) {
        _vm = StateObject(wrappedValue: CashflowCockpitViewModel(deps: deps))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                if vm.isLoading && !vm.loaded {
                    ProgressView().padding(.top, Spacing.xxl)
                } else if let err = vm.errorMessage, !vm.loaded {
                    infoCard(err, system: "exclamationmark.triangle")
                } else {
                    outlookCard
                    fioCard
                    manualCard
                    categoriesCard
                    if !vm.standingVisible.isEmpty { standingCard }
                    if !vm.investedFlow.isEmpty { investedCard }
                    contextCard
                }
            }
            .padding(Spacing.lg)
        }
        .background(colors.background)
        .navigationTitle(String(localized: "Cashflow"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .sheet(isPresented: $showAddSpend) { addSpendSheet }
    }

    // MARK: - Hero: výhled do výplaty

    private var outlookCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "Výhled do výplaty (\(dm(vm.nextPayday)))"))
                .font(AccBotFonts.titleSmall).foregroundStyle(colors.onSurface)

            if let proj = vm.projectedAtPayday {
                let ok = vm.willHaveSurplus
                Text(signedD(proj))
                    .font(AccBotFonts.titleLarge)
                    .foregroundStyle(ok ? colors.success : colors.error)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text(ok
                    ? String(localized: "Vyjdeš a ještě ti zbyde — pěkné. 🎉")
                    : String(localized: "Při tomhle tempu ti do výplaty bude chybět \(fmtD(-proj)). Klid, níž je kde ubrat."))
                    .font(AccBotFonts.caption)
                    .foregroundStyle(ok ? colors.success : colors.error)

                Divider().background(colors.onSurfaceVariant.opacity(0.2))

                if vm.runwayCoversPayday {
                    row(icon: "checkmark.seal.fill", color: colors.success,
                        text: String(localized: "Peníze ti vydrží až do výplaty."))
                } else if let rd = vm.runwayDate {
                    row(icon: "calendar", color: colors.warning,
                        text: String(localized: "Při tomhle tempu peníze vydrží do \(dm(rd))."))
                }
                if let safe = vm.safeToSpendPerDay, vm.daysUntilPayday > 0 {
                    row(icon: "wallet.pass", color: colors.primary,
                        text: String(localized: "Bezpečně utrať ~\(fmtD(safe))/den (zbývá \(vm.daysUntilPayday) dní)."))
                }
            } else {
                Text(String(localized: "Pro výhled klepni na Refresh z Fio níž — vezme tvůj živý zůstatek a tempo."))
                    .font(AccBotFonts.body).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .modifier(Card(colors: colors))
    }

    private func row(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon).font(AccBotFonts.caption).foregroundStyle(color).frame(width: 20)
            Text(text).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Fio

    private var fioCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(String(localized: "Fio účet (živě)")).font(AccBotFonts.titleSmall)
                    .foregroundStyle(colors.onSurface)
                Spacer()
                Button { Task { await vm.refreshFio() } } label: {
                    if vm.fioLoading { ProgressView().frame(width: 18, height: 18) }
                    else {
                        Label(String(localized: "Refresh z Fio"), systemImage: "arrow.clockwise")
                            .font(AccBotFonts.label).foregroundStyle(colors.primary)
                    }
                }.disabled(vm.fioLoading)
            }
            if let bal = vm.fioBalance {
                HStack(alignment: .top) {
                    miniStat(String(localized: "Zůstatek"), fmtD(bal), colors.primary)
                    Spacer()
                    miniStat(String(localized: "Utraceno tento cyklus"), fmtD(vm.spentThisCycle), colors.onSurface, trailing: true)
                }
            } else if let e = vm.fioError {
                Text(e).font(AccBotFonts.caption).foregroundStyle(colors.error)
            } else {
                Text(String(localized: "Klepni Refresh pro živý zůstatek (Fio limit 1×/30 s)."))
                    .font(AccBotFonts.caption).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .modifier(Card(colors: colors))
    }

    // MARK: - Ruční útraty

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(String(localized: "Ruční útraty (kreditka/hotovost)")).font(AccBotFonts.titleSmall)
                    .foregroundStyle(colors.onSurface)
                Spacer()
                Button { showAddSpend = true } label: {
                    Label(String(localized: "Přidat"), systemImage: "plus.circle.fill")
                        .font(AccBotFonts.label).foregroundStyle(colors.primary)
                }
            }
            if vm.manualSpends.isEmpty {
                Text(String(localized: "Když zaplatíš mimo Fio (kreditka, hotovost), přidej to sem — započítá se do výhledu."))
                    .font(AccBotFonts.caption).foregroundStyle(colors.onSurfaceVariant)
            } else {
                ForEach(vm.manualSpends) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.category).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                            if !s.note.isEmpty {
                                Text(s.note).font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
                            }
                        }
                        Spacer()
                        Text(fmtD(s.amountCzk)).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                        Button { vm.removeManual(id: s.id) } label: {
                            Image(systemName: "xmark.circle").foregroundStyle(colors.onSurfaceVariant)
                        }
                    }
                }
            }
        }
        .modifier(Card(colors: colors))
    }

    private var addSpendSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Částka (Kč)"), text: $amountText)
                        .keyboardType(.decimalPad)
                    Picker(String(localized: "Kategorie"), selection: $selectedCategory) {
                        ForEach(categoryOptions, id: \.self) { Text($0).tag($0) }
                    }
                    TextField(String(localized: "Poznámka (volitelně)"), text: $noteText)
                }
            }
            .navigationTitle(String(localized: "Přidat útratu"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Zrušit")) { resetSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Uložit")) {
                        let amt = Decimal(string: amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
                        if amt > 0 {
                            vm.addManual(amountCzk: amt,
                                         category: selectedCategory.isEmpty ? (categoryOptions.first ?? "Nákupy") : selectedCategory,
                                         note: noteText)
                        }
                        resetSheet()
                    }
                }
            }
            .onAppear { if selectedCategory.isEmpty { selectedCategory = categoryOptions.first ?? "Nákupy" } }
        }
    }

    private var categoryOptions: [String] {
        let names = vm.categories.map(\.name)
        return names.isEmpty ? ["Potraviny", "Restaurace", "Nákupy", "Doprava", "Zábava", "Drogerie", "Zdraví"] : names
    }

    private func resetSheet() {
        showAddSpend = false; amountText = ""; noteText = ""
    }

    // MARK: - Kam jdou peníze (kontext)

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "Kam jdou peníze (typicky/měs)"))
                .font(AccBotFonts.titleSmall).foregroundStyle(colors.onSurface)
            ForEach(vm.categories) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(c.name).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                        Spacer()
                        Text(fmt(c.monthlyMedianCzk)).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                    }
                    bar(fraction: Double(c.monthlyMedianCzk) / Double(max(1, vm.maxCategoryCzk)))
                    if let subs = c.subcategories, !subs.isEmpty {
                        Text(subs.map { "\($0.name) \(fmt($0.monthlyMedianCzk))" }.joined(separator: " · "))
                            .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .modifier(Card(colors: colors))
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.onSurfaceVariant.opacity(0.15))
                Capsule().fill(colors.primary)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }

    private var standingCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "Pevné platby (trvalé příkazy)"))
                .font(AccBotFonts.titleSmall).foregroundStyle(colors.onSurface)
            ForEach(vm.standingVisible) { o in
                HStack(spacing: Spacing.sm) {
                    Text(String(localized: "\(o.dayOfMonth).")).font(AccBotFonts.caption)
                        .foregroundStyle(colors.onSurfaceVariant).frame(width: 28, alignment: .leading)
                    Text(o.name).font(AccBotFonts.body).foregroundStyle(colors.onSurface).lineLimit(1)
                    Spacer()
                    Text(fmt(o.amountCzk)).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                }
            }
        }
        .modifier(Card(colors: colors))
    }

    private var investedCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(String(localized: "Odkládáš na investice")).font(AccBotFonts.titleSmall)
                    .foregroundStyle(colors.onSurface)
                Spacer()
                Text(fmt(vm.investedTotalCzk)).font(AccBotFonts.headline).foregroundStyle(colors.primary)
            }
            ForEach(vm.investedFlow) { o in
                HStack {
                    Text(o.name).font(AccBotFonts.body).foregroundStyle(colors.onSurfaceVariant)
                    Spacer()
                    Text(fmt(o.amountCzk)).font(AccBotFonts.body).foregroundStyle(colors.onSurfaceVariant)
                }
            }
            Text(String(localized: "Tohle se nepočítá jako útrata — je to odkládání z přebytku."))
                .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .modifier(Card(colors: colors))
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(String(localized: "Typický měsíc (z historie)")).font(AccBotFonts.caption)
                .foregroundStyle(colors.onSurfaceVariant)
            HStack {
                Text(String(localized: "Vyděláváš \(fmt(vm.incomeCzk)) · utrácíš \(fmt(vm.expensesCzk))"))
                    .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
    }

    // MARK: - Helpers

    private func miniStat(_ label: String, _ value: String, _ color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: Spacing.xs) {
            Text(label).font(AccBotFonts.caption).foregroundStyle(colors.onSurfaceVariant)
            Text(value).font(AccBotFonts.headline).foregroundStyle(color)
        }
    }

    private func infoCard(_ text: String, system: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: system).font(.system(size: 32)).foregroundStyle(colors.warning)
            Text(text).font(AccBotFonts.body).foregroundStyle(colors.onSurface).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .modifier(Card(colors: colors))
    }

    private func fmt(_ v: Int) -> String { AccBotFormatters.formatFiat(Decimal(v), symbol: "CZK") }
    private func fmtD(_ v: Decimal) -> String { AccBotFormatters.formatFiat(v, symbol: "CZK") }
    private func signedD(_ v: Decimal) -> String {
        (v >= 0 ? "+" : "−") + AccBotFormatters.formatFiat(abs(v), symbol: "CZK")
    }

    private static let dmFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d. M."; f.locale = Locale(identifier: "cs_CZ"); return f
    }()
    private func dm(_ d: Date) -> String { Self.dmFmt.string(from: d) }
}

/// Karta — sjednocené pozadí + rádius.
private struct Card: ViewModifier {
    let colors: AccBotColors
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .background(colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
    }
}
