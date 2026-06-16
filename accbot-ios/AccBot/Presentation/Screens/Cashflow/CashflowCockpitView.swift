import SwiftUI

/// Cashflow kokpit: hlavní otázka „vydělávám hodně, ale šetřím?" — příjem vs výdaje (medián),
/// strukturální bilance, kam peníze jdou (kategorie), a pevné platby.
struct CashflowCockpitView: View {
    @StateObject private var vm: CashflowCockpitViewModel
    @Environment(\.accBotColors) private var colors

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
                    balanceCard
                    categoriesCard
                    if !vm.standingVisible.isEmpty { standingCard }
                    if !vm.investedFlow.isEmpty { investedCard }
                    Text(String(localized: "Typický (medián) měsíc z dat 2026. Živé útraty tohoto měsíce přijdou s napojením Fio."))
                        .font(AccBotFonts.captionSmall)
                        .foregroundStyle(colors.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.lg)
        }
        .background(colors.background)
        .navigationTitle(String(localized: "Cashflow"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    // MARK: - Balance headline

    private var balanceCard: some View {
        let negative = vm.balanceCzk < 0
        return VStack(alignment: .leading, spacing: Spacing.md) {
            Text(String(localized: "Strukturální bilance / měsíc"))
                .font(AccBotFonts.titleSmall)
                .foregroundStyle(colors.onSurface)
            Text(signed(vm.balanceCzk))
                .font(AccBotFonts.titleLarge)
                .foregroundStyle(negative ? colors.error : colors.success)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(alignment: .top) {
                stat(String(localized: "Vyděláváš"), vm.incomeCzk, colors.success)
                Spacer()
                stat(String(localized: "Utrácíš"), vm.expensesCzk, colors.onSurface, trailing: true)
            }
            if negative {
                Text(String(localized: "Každý měsíc ti chybí \(fmt(-vm.balanceCzk)) — koukni níž, kam to teče, a co osekat."))
                    .font(AccBotFonts.caption)
                    .foregroundStyle(colors.error)
            }
        }
        .modifier(Card(colors: colors))
    }

    private func stat(_ label: String, _ value: Int, _ color: Color, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: Spacing.xs) {
            Text(label).font(AccBotFonts.caption).foregroundStyle(colors.onSurfaceVariant)
            Text(fmt(value)).font(AccBotFonts.headline).foregroundStyle(color)
        }
    }

    // MARK: - Categories

    private var categoriesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "Kam jdou peníze (medián/měs)"))
                .font(AccBotFonts.titleSmall)
                .foregroundStyle(colors.onSurface)
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
                            .font(AccBotFonts.captionSmall)
                            .foregroundStyle(colors.onSurfaceVariant)
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

    // MARK: - Standing orders

    private var standingCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(String(localized: "Pevné platby (trvalé příkazy)"))
                .font(AccBotFonts.titleSmall)
                .foregroundStyle(colors.onSurface)
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
            Text(String(localized: "Investice/převody nepočítáme jako útratu — je to odkládání z přebytku."))
                .font(AccBotFonts.captionSmall).foregroundStyle(colors.onSurfaceVariant)
        }
        .modifier(Card(colors: colors))
    }

    // MARK: - Helpers

    private func infoCard(_ text: String, system: String) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: system).font(.system(size: 32)).foregroundStyle(colors.warning)
            Text(text).font(AccBotFonts.body).foregroundStyle(colors.onSurface)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .modifier(Card(colors: colors))
    }

    private func fmt(_ v: Int) -> String {
        AccBotFormatters.formatFiat(Decimal(v), symbol: "CZK")
    }

    private func signed(_ v: Int) -> String {
        (v >= 0 ? "+" : "−") + AccBotFormatters.formatFiat(Decimal(abs(v)), symbol: "CZK")
    }
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
