import Combine
import Foundation
import SwiftUI

/// Dependency injection container.
/// Injected via @EnvironmentObject from the root AccBotApp.
@MainActor
final class AppDependencies: ObservableObject {
    /// Shared instance for background tasks (avoids creating duplicate DatabasePools).
    /// Set by AccBotApp on launch, read by DcaBackgroundService.
    static var shared: AppDependencies?

    let database: DcaDatabase
    let sandboxDatabase: DcaDatabase
    let credentialsStore: CredentialsStore
    var userPreferences: UserPreferences
    var onboardingPreferences: OnboardingPreferences
    let networkClient: NetworkClient
    let exchangeApiFactory: ExchangeApiFactory
    let marketDataService: MarketDataService
    let notificationService: NotificationService
    let dcaExecutionEngine: DcaExecutionEngine
    let syncNuplUseCase: SyncNuplUseCase
    let tokenStore: TokenStore
    let snapshotService: SnapshotService
    let gitHubBackupService: GitHubBackupService
    private var cancellables = Set<AnyCancellable>()

    /// Get the active database based on sandbox mode
    var activeDatabase: DcaDatabase {
        userPreferences.sandboxMode ? sandboxDatabase : database
    }

    init() {
        // Initialize core infrastructure
        let credentialsStore = CredentialsStore()
        let userPreferences = UserPreferences(defaults: UserDefaults(suiteName: "com.accbot.dca.preferences") ?? .standard)
        let onboardingPreferences = OnboardingPreferences()
        let networkClient = NetworkClient()
        let exchangeApiFactory = ExchangeApiFactory(
            userPreferences: userPreferences,
            networkClient: networkClient
        )

        // Initialize databases
        let database: DcaDatabase
        let sandboxDatabase: DcaDatabase
        do {
            database = try DcaDatabase.production()
            sandboxDatabase = try DcaDatabase.sandbox()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }

        // Initialize services
        let marketDataService = MarketDataService(client: networkClient)
        let notificationService = NotificationService()
        let tokenStore = TokenStore()
        let snapshotService = SnapshotService()
        let gitHubBackupService = GitHubBackupService(client: networkClient, tokenStore: tokenStore)
        let dcaExecutionEngine = DcaExecutionEngine(
            database: database,
            sandboxDatabase: sandboxDatabase,
            credentialsStore: credentialsStore,
            userPreferences: userPreferences,
            exchangeApiFactory: exchangeApiFactory,
            notificationService: notificationService,
            marketDataService: marketDataService,
            snapshotService: snapshotService,
            gitHubBackupService: gitHubBackupService
        )
        let syncNuplUseCase = SyncNuplUseCase(
            nuplDao: database.nuplDao,
            marketDataService: marketDataService,
            userPreferences: userPreferences
        )

        // Assign properties
        self.database = database
        self.sandboxDatabase = sandboxDatabase
        self.credentialsStore = credentialsStore
        self.userPreferences = userPreferences
        self.onboardingPreferences = onboardingPreferences
        self.networkClient = networkClient
        self.exchangeApiFactory = exchangeApiFactory
        self.marketDataService = marketDataService
        self.notificationService = notificationService
        self.dcaExecutionEngine = dcaExecutionEngine
        self.syncNuplUseCase = syncNuplUseCase
        self.tokenStore = tokenStore
        self.snapshotService = snapshotService
        self.gitHubBackupService = gitHubBackupService

        // Forward onboardingPreferences changes so RootView re-renders
        // when onboarding completes (rare event, no perf concern).
        onboardingPreferences.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // NUPL sync při startu (1×/den guard uvnitř) — mimo main (těžký zápis do DB, ať nesekne UI)
        Task.detached { await syncNuplUseCase.sync() }

        // Obnova z gitu, když chybí holdingy (migrace z C# i disaster recovery) — mimo main.
        // Pozor: stačí prázdné holdingy, NE celá DB. DB mohla mít transakce z předchozí
        // verze a přesto 0 holdingů — pak load() doplní holdingy + půjčky (a transakce jen
        // pokud chybí). To je přesně stav, kdy appka kdysi přepsala migraci prázdnotou.
        Task.detached { [database, snapshotService, gitHubBackupService] in
            let needsRestore = ((try? database.holdingDao.getAll().isEmpty) ?? true)
            guard needsRestore, let (json, _) = await gitHubBackupService.fetch(),
                  let snap = try? JSONDecoder().decode(AppSnapshot.self, from: json) else { return }
            try? snapshotService.load(snap, into: database)
        }
    }
}
