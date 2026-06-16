import SwiftUI
import Combine

/// Hlavní navigace — NATIVNÍ TabView (rendruje jen aktivní tab → plynulý scroll, bez sekání).
/// Taby: Přehled (Cashflow, home) · BTC (DCA dashboard) · Portfolio · Oznámení · Nastavení.
/// (Dřív custom ZStack pager — soupeřil se scrollem a sekal ~15fps; nahrazen.)
struct MainTabView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var dependencies: AppDependencies
    @Environment(\.accBotColors) private var colors

    /// Changelog auto-show on version update.
    @State private var showChangelog = false
    @State private var changelogEntries: [ChangelogEntry] = []

    var body: some View {
        // Nativní TabView — rendruje jen aktivní tab (GPU-optimalizovaný scroll), bez sekání.
        TabView(selection: $router.selectedTab) {
            cashflowTab
                .tag(TabItem.cashflow)
                .tabItem { Label(String(localized: "Přehled"), systemImage: "chart.line.uptrend.xyaxis") }

            dashboardTab
                .tag(TabItem.dashboard)
                .tabItem { Label(String(localized: "Portfolio"), systemImage: "chart.pie") }

            notificationsTab
                .tag(TabItem.notifications)
                .tabItem { Label(String(localized: "Oznámení"), systemImage: "bell") }
                .badge(router.unreadNotificationCount)

            settingsTab
                .tag(TabItem.settings)
                .tabItem { Label(String(localized: "Nastavení"), systemImage: "gearshape") }
        }
        .tint(colors.primary)
        .ignoresSafeArea(.keyboard)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .onReceive(
            dependencies.activeDatabase.notificationDao.observeUnreadCount()
                .replaceError(with: 0)
                .receive(on: DispatchQueue.main)
                .removeDuplicates()
        ) { count in
            router.unreadNotificationCount = count
        }
        .onAppear {
            let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
            let lastSeen = dependencies.userPreferences.lastSeenBuildNumber
            if lastSeen > 0 && currentBuild > lastSeen {
                let newEntries = ChangelogData.getNewEntries(since: lastSeen)
                if !newEntries.isEmpty {
                    changelogEntries = newEntries
                    showChangelog = true
                }
            }
            dependencies.userPreferences.lastSeenBuildNumber = currentBuild
        }
        .sheet(isPresented: $showChangelog) {
            ChangelogView(entries: changelogEntries)
        }
    }

    private var cashflowTab: some View {
        NavigationStack(path: $router.cashflowPath) {
            CashflowCockpitView(deps: dependencies)
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
        }
    }

    private var dashboardTab: some View {
        NavigationStack(path: $router.dashboardPath) {
            DashboardView()
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
        }
    }

    private var portfolioTab: some View {
        NavigationStack(path: $router.portfolioPath) {
            PortfolioView()
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
        }
    }

    private var notificationsTab: some View {
        NavigationStack(path: $router.notificationsPath) {
            NotificationsView()
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
        }
    }

    private var settingsTab: some View {
        NavigationStack(path: $router.settingsPath) {
            SettingsView()
                .navigationDestination(for: AppRoute.self) { route in
                    routeDestination(route)
                }
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: AppRoute) -> some View {
        switch route {
        case .addPlan:
            AddPlanView()
        case .planDetails(let planId):
            PlanDetailsView(planId: planId)
        case .editPlan(let planId):
            EditPlanView(planId: planId)
        case .importCsv(let planId):
            ImportCsvView(planId: planId)
        case .exchangeManagement:
            ExchangeManagementView()
        case .exchangeDetail(let exchange):
            ExchangeDetailView(exchange: exchange)
        case .addExchange(let exchange):
            AddExchangeView(preselectedExchange: exchange)
        case .history(let crypto, let fiat):
            HistoryView(filterCrypto: crypto, filterFiat: fiat)
        case .transactionDetails(let txId):
            TransactionDetailsView(transactionId: txId)
        case .backupExport:
            BackupExportView()
        case .backupImport:
            BackupImportView()
        case .riskCockpit:
            RiskCockpitView(deps: dependencies)
        case .loanManagement:
            LoanManagementView(deps: dependencies)
        case .cashflowCockpit:
            CashflowCockpitView(deps: dependencies)
        case .portfolioChart:
            PortfolioView()
        }
    }
}

