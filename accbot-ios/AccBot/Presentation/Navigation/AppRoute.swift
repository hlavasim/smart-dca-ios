import Foundation

/// All navigation routes in the app (replaces Android's Screen sealed class)
enum AppRoute: Hashable {
    // Plan screens
    case addPlan
    case planDetails(Int64)
    case editPlan(Int64)
    case importCsv(Int64)

    // Exchange screens
    case exchangeManagement
    case exchangeDetail(Exchange)
    case addExchange(Exchange?)

    // History screens
    case history(crypto: String? = nil, fiat: String? = nil)
    case transactionDetails(Int64)

    // Backup screens
    case backupExport
    case backupImport

    // Finance (Phase 2)
    case riskCockpit
    case loanManagement
    case cashflowCockpit
}

/// Bottom navigation tab items
enum TabItem: Int, CaseIterable, Identifiable {
    case cashflow = 0
    case dashboard = 1
    case portfolio = 2
    case notifications = 3
    case settings = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .cashflow: return String(localized: "Přehled")
        case .dashboard: return String(localized: "BTC")
        case .portfolio: return String(localized: "Portfolio")
        case .notifications: return String(localized: "Notifications")
        case .settings: return String(localized: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .cashflow: return "chart.line.uptrend.xyaxis"
        case .dashboard: return "bitcoinsign.circle.fill"
        case .portfolio: return "chart.pie.fill"
        case .notifications: return "bell.fill"
        case .settings: return "gearshape.fill"
        }
    }

    func systemImage(isSelected: Bool) -> String {
        switch self {
        case .cashflow: return "chart.line.uptrend.xyaxis"
        case .dashboard: return isSelected ? "bitcoinsign.circle.fill" : "bitcoinsign.circle"
        case .portfolio: return isSelected ? "chart.pie.fill" : "chart.pie"
        case .notifications: return isSelected ? "bell.fill" : "bell"
        case .settings: return isSelected ? "gearshape.fill" : "gearshape"
        }
    }
}
