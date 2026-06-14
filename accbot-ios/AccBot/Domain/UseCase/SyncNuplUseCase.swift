import Foundation
import os

/// Stáhne NUPL historii z bitcoin-data.com a uloží do nupl_values.
/// ⚠️ bitcoin-data.com má RATE LIMIT → stahuj MAX 1× denně. nupl_values je
/// perzistentní cache/záloha: přežije výpadek API a jde do git snapshotu, takže
/// catch-up i strategie fungují i offline / když API odmítne.
/// Idempotentní (save = insert-or-replace). Vrací počet uložených řádků (0 = skip/neúspěch).
final class SyncNuplUseCase {
    private let nuplDao: NuplDao
    private let marketDataService: MarketDataService
    private let userPreferences: UserPreferences
    private let logger = Logger(subsystem: "com.accbot.dca", category: "SyncNupl")

    init(nuplDao: NuplDao, marketDataService: MarketDataService, userPreferences: UserPreferences) {
        self.nuplDao = nuplDao
        self.marketDataService = marketDataService
        self.userPreferences = userPreferences
    }

    /// `force` obejde 1×/den guard (manuální refresh).
    @discardableResult
    func sync(force: Bool = false) async -> Int {
        let todayEpoch = NuplDao.epochDay(Date())
        // 1×/den guard: pokud už dnes staženo, použij cache (nupl_values), nestahuj.
        if !force, userPreferences.lastNuplSyncDay == todayEpoch {
            logger.info("NUPL už staženo dnes (rate-limit guard) — používám cache")
            return 0
        }
        guard let history = await marketDataService.getNuplHistory(), !history.isEmpty else {
            logger.warning("NUPL history unavailable — ponechávám cache z nupl_values")
            return 0
        }
        do {
            try nuplDao.insertBatch(history)
            userPreferences.lastNuplSyncDay = todayEpoch   // zapiš guard až po úspěchu
            logger.info("Synced \(history.count) NUPL values")
            return history.count
        } catch {
            logger.error("Failed to persist NUPL: \(error.localizedDescription)")
            return 0
        }
    }
}
