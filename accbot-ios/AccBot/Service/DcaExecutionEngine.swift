import Foundation
import os

/// Core DCA execution logic, shared across BGTask, foreground catch-up, and manual "Run Now".
/// Ported from Android DcaWorker.doWork().
final class DcaExecutionEngine {
    private let database: DcaDatabase
    private let sandboxDatabase: DcaDatabase
    private let credentialsStore: CredentialsStore
    private let userPreferences: UserPreferences
    private let exchangeApiFactory: ExchangeApiFactory
    private let notificationService: NotificationService
    private let marketDataService: MarketDataService
    private let strategyMultiplierUseCase: CalculateStrategyMultiplierUseCase
    private let logger = Logger(subsystem: "com.accbot.dca", category: "DcaExecutionEngine")

    private let maxAttempts = 3
    private let retryDelayNs: UInt64 = 2_000_000_000 // 2s
    private let maxCatchupDays = 30 // strop zmeškaných dnů na jeden běh (bezpečnost)

    init(
        database: DcaDatabase,
        sandboxDatabase: DcaDatabase,
        credentialsStore: CredentialsStore,
        userPreferences: UserPreferences,
        exchangeApiFactory: ExchangeApiFactory,
        notificationService: NotificationService,
        marketDataService: MarketDataService
    ) {
        self.database = database
        self.sandboxDatabase = sandboxDatabase
        self.credentialsStore = credentialsStore
        self.userPreferences = userPreferences
        self.exchangeApiFactory = exchangeApiFactory
        self.notificationService = notificationService
        self.marketDataService = marketDataService
        self.strategyMultiplierUseCase = CalculateStrategyMultiplierUseCase(marketDataService: marketDataService)
    }

    private var activeDb: DcaDatabase {
        userPreferences.sandboxMode ? sandboxDatabase : database
    }

    // MARK: - Execute Due Plans

    /// Execute all enabled plans that are due. Called from BGTask, foreground catch-up, etc.
    func executeDuePlans() async {
        logger.info("DCA execution started")

        // Resolve PENDING transactions from previous runs
        await resolvePendingTransactions()

        do {
            let duePlans = try activeDb.planDao.getDuePlans()
            if duePlans.isEmpty {
                logger.info("No due DCA plans")
                return
            }

            for plan in duePlans {
                await executePlan(plan, forceRun: false)
            }
        } catch {
            logger.error("Failed to fetch due plans: \(error.localizedDescription)")
        }
    }

    /// Execute a specific plan (for "Run Now")
    func executePlan(_ planId: Int64) async {
        do {
            guard let plan = try activeDb.planDao.getById(planId) else {
                logger.error("Plan \(planId) not found")
                return
            }
            await executePlan(plan, forceRun: true)
        } catch {
            logger.error("Failed to fetch plan \(planId): \(error.localizedDescription)")
        }
    }

    /// Execute selected plans (for "Run Now" with multi-select)
    func executePlans(_ planIds: [Int64]) async {
        for planId in planIds {
            await executePlan(planId)
        }
    }

    // MARK: - Core Execution

    private func executePlan(_ plan: DcaPlan, forceRun: Bool) async {
        let now = Date()

        // Check if it's time to execute
        if !forceRun, let nextExecution = plan.nextExecutionAt, nextExecution > now {
            logger.info("Plan \(plan.id) not due yet, skipping")
            return
        }

        // Get credentials
        let isSandbox = userPreferences.isSandboxMode()
        guard let credentials = credentialsStore.get(for: plan.exchange, isSandbox: isSandbox) else {
            logger.error("No credentials for \(plan.exchange.displayName) (sandbox=\(isSandbox))")
            return
        }

        // NUPL strategie → idempotentní catch-up (per-day historický NUPL, timeout-safe).
        // Pro force i non-force; idempotence zabrání dvojímu nákupu.
        if case .nupl(let config) = plan.strategy {
            let api = exchangeApiFactory.create(credentials: credentials)
            await runNuplCatchup(plan: plan, config: config, api: api, now: now)
            return
        }

        // Calculate strategy multiplier
        let strategyResult = await calculateStrategyMultiplier(
            strategy: plan.strategy,
            crypto: plan.crypto,
            fiat: plan.fiat
        )

        let purchaseAmount = roundDecimal(
            plan.amount * Decimal(Double(strategyResult.multiplier)),
            scale: 2
        )

        logger.info("Strategy: \(plan.strategy.dbString), Base: \(plan.amount), Multiplier: \(strategyResult.multiplier), Final: \(purchaseAmount)")

        // Check minimum order size
        let minOrderSize = MinOrderSizeRepository.getMinOrderSize(exchange: plan.exchange, fiat: plan.fiat)
        if purchaseAmount < minOrderSize {
            logger.warning("Plan \(plan.id): \(purchaseAmount) < minimum \(minOrderSize), skipping")
            let failedTx = Transaction(
                planId: plan.id,
                exchange: plan.exchange,
                crypto: plan.crypto,
                fiat: plan.fiat,
                fiatAmount: purchaseAmount,
                cryptoAmount: 0,
                price: 0,
                fee: 0,
                status: .failed,
                errorMessage: "Amount \(purchaseAmount) \(plan.fiat) below minimum \(minOrderSize) \(plan.fiat)"
            )
            saveTransactionAndAdvance(failedTx, plan: plan, now: now)
            saveInAppNotification(type: .error, title: "DCA Failed", message: "Amount below minimum for \(plan.crypto)", plan: plan)
            return
        }

        // Execute with retry
        let api = exchangeApiFactory.create(credentials: credentials)
        var failedAttemptMessages: [String] = []
        var finalResult: DcaResult?

        for attempt in 1...maxAttempts {
            let result = await withTimeout(seconds: 30) {
                await api.marketBuy(crypto: plan.crypto, fiat: plan.fiat, fiatAmount: purchaseAmount)
            }

            let attemptResult = result ?? .error(message: "API call timed out after 30s", retryable: true)

            if case .success = attemptResult {
                finalResult = attemptResult
                break
            }

            if case .error(let msg, _) = attemptResult {
                failedAttemptMessages.append("Attempt \(attempt): \(msg)")
                logger.warning("Plan \(plan.id) attempt \(attempt)/\(self.maxAttempts) failed: \(msg)")
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: retryDelayNs)
            } else {
                finalResult = attemptResult
            }
        }

        let warningMessage: String? = if case .success = finalResult, !failedAttemptMessages.isEmpty {
            failedAttemptMessages.joined(separator: "; ")
        } else {
            nil
        }

        switch finalResult {
        case .success(let tx):
            let savedTx = Transaction(
                planId: plan.id,
                exchange: plan.exchange,
                crypto: plan.crypto,
                fiat: plan.fiat,
                fiatAmount: tx.fiatAmount,
                cryptoAmount: tx.cryptoAmount,
                price: tx.price,
                fee: tx.fee,
                feeAsset: tx.feeAsset,
                status: tx.status,
                exchangeOrderId: tx.exchangeOrderId,
                warningMessage: warningMessage
            )
            saveTransactionAndAdvance(savedTx, plan: plan, now: now)

            // Post notification
            if userPreferences.notificationsEnabled && userPreferences.purchaseNotifications {
                notificationService.postPurchaseNotification(
                    crypto: plan.crypto,
                    fiat: plan.fiat,
                    amount: tx.fiatAmount,
                    exchange: plan.exchange
                )
            }
            saveInAppNotification(
                type: .purchase,
                title: "DCA Purchase",
                message: "Bought \(tx.cryptoAmount) \(plan.crypto) for \(tx.fiatAmount) \(plan.fiat)",
                plan: plan
            )

            // Check withdrawal threshold
            await checkWithdrawalThreshold(plan: plan, api: api)

            // Check low balance
            await checkLowBalance(api: api, plan: plan)

            logger.info("DCA purchase successful: \(tx.cryptoAmount) \(plan.crypto)")

        case .error(let msg, let retryable):
            if retryable {
                // Network error - retry in 5 min
                let retryTime = now.addingTimeInterval(300)
                try? activeDb.planDao.updateExecution(id: plan.id, lastExecutedAt: now, nextExecutionAt: retryTime)
                logger.warning("Network error for plan \(plan.id), retry at \(retryTime): \(msg)")
            } else {
                let failedTx = Transaction(
                    planId: plan.id,
                    exchange: plan.exchange,
                    crypto: plan.crypto,
                    fiat: plan.fiat,
                    fiatAmount: plan.amount,
                    cryptoAmount: 0,
                    price: 0,
                    fee: 0,
                    status: .failed,
                    errorMessage: msg,
                    warningMessage: failedAttemptMessages.count > 1
                        ? failedAttemptMessages.dropLast().joined(separator: "; ")
                        : nil
                )
                saveTransactionAndAdvance(failedTx, plan: plan, now: now)

                if userPreferences.notificationsEnabled && userPreferences.errorNotifications {
                    notificationService.postErrorNotification(exchange: plan.exchange, message: msg)
                }
                saveInAppNotification(type: .error, title: "DCA Failed", message: "\(plan.crypto): \(msg)", plan: plan)
            }

        case nil:
            logger.error("Plan \(plan.id): no result (unexpected)")
        }
    }

    // MARK: - Helpers

    private func saveTransactionAndAdvance(_ transaction: Transaction, plan: DcaPlan, now: Date) {
        do {
            try activeDb.transactionDao.insert(transaction)
            let nextExecution = calculateNextExecution(plan: plan, from: now)
            try activeDb.planDao.updateExecution(id: plan.id, lastExecutedAt: now, nextExecutionAt: nextExecution)
        } catch {
            logger.error("Failed to save transaction for plan \(plan.id): \(error.localizedDescription)")
        }
    }

    private func calculateNextExecution(plan: DcaPlan, from now: Date) -> Date {
        if let cron = plan.cronExpression {
            return CronUtils.getNextExecution(cron: cron, from: now)
                ?? now.addingTimeInterval(TimeInterval(plan.frequency.intervalMinutes * 60))
        }
        let interval = plan.frequency.intervalMinutes > 0 ? plan.frequency.intervalMinutes : 1440
        return now.addingTimeInterval(TimeInterval(interval * 60))
    }

    private func calculateStrategyMultiplier(
        strategy: DcaStrategy,
        crypto: String,
        fiat: String
    ) async -> StrategyMultiplierResult {
        await strategyMultiplierUseCase.invoke(strategy: strategy, crypto: crypto, fiat: fiat)
    }

    private func checkWithdrawalThreshold(plan: DcaPlan, api: ExchangeApi) async {
        do {
            guard let threshold = try activeDb.withdrawalThresholdDao.get(crypto: plan.crypto, exchange: plan.exchange) else { return }
            guard let balance = await api.getBalance(currency: plan.crypto) else { return }
            if balance >= threshold.thresholdAmount {
                notificationService.postWithdrawalThresholdNotification(
                    crypto: plan.crypto,
                    exchange: plan.exchange,
                    amount: balance
                )
                saveInAppNotification(
                    type: .withdrawalThreshold,
                    title: "Withdrawal Threshold",
                    message: "\(balance) \(plan.crypto) ready for withdrawal from \(plan.exchange.displayName)",
                    plan: plan
                )
            }
        } catch {
            logger.error("Error checking withdrawal threshold: \(error.localizedDescription)")
        }
    }

    private func checkLowBalance(api: ExchangeApi, plan: DcaPlan) async {
        do {
            guard let balance = await api.getBalance(currency: plan.fiat) else { return }
            guard plan.amount > 0 else { return }
            let remainingExec = NSDecimalNumber(decimal: balance / plan.amount).intValue
            let intervalMinutes = plan.cronExpression != nil
                ? (CronUtils.getIntervalMinutesEstimate(cron: plan.cronExpression!) ?? 1440)
                : plan.frequency.intervalMinutes
            let remainingDays = Double(remainingExec * intervalMinutes) / 1440.0
            let thresholdDays = userPreferences.lowBalanceThresholdDays

            if remainingDays < Double(thresholdDays) {
                if userPreferences.notificationsEnabled {
                    notificationService.postLowBalanceNotification(
                        exchange: plan.exchange,
                        fiat: plan.fiat,
                        balance: balance,
                        daysLeft: Int(remainingDays)
                    )
                }
                saveInAppNotification(
                    type: .lowBalance,
                    title: "Low Balance",
                    message: "\(plan.exchange.displayName): ~\(Int(remainingDays)) days of \(plan.fiat) remaining",
                    plan: plan
                )
            }
        } catch {
            logger.error("Error checking low balance: \(error.localizedDescription)")
        }
    }

    private func saveInAppNotification(type: NotificationType, title: String, message: String, plan: DcaPlan) {
        let notification = AppNotification(
            type: type,
            title: title,
            message: message,
            planId: plan.id,
            crypto: plan.crypto,
            exchange: plan.exchange
        )
        try? activeDb.notificationDao.insert(notification)
    }

    // MARK: - NUPL Catch-up (idempotentní, timeout-safe)

    /// Dokoupí zmeškané dny pro NUPL plán. Každý den: idempotency zámek PŘED nákupem,
    /// multiplikátor z historického NUPL daného dne, timeout = rekonciliace (ne re-buy).
    private func runNuplCatchup(plan: DcaPlan, config: NuplConfig, api: ExchangeApi, now: Date) async {
        let todayEpoch = NuplDao.epochDay(now)
        let lastEpoch = plan.lastExecutedAt.map { NuplDao.epochDay($0) } ?? (todayEpoch - 1)
        let firstDay = max(lastEpoch + 1, todayEpoch - Int64(maxCatchupDays) + 1)
        guard firstDay <= todayEpoch else { return }

        let execDao = activeDb.dcaExecutionDao
        let nuplValues = activeDb.nuplDao

        for day in firstDay...todayEpoch {
            // 1) Už completed → přeskoč.
            if let rec = try? execDao.get(planId: plan.id, dayEpoch: day), rec.status == "completed" {
                continue
            }
            // 2) Pending z minula → rekonciliace (s orderId), jinak bezpečně zastav.
            if let rec = try? execDao.get(planId: plan.id, dayEpoch: day), rec.status == "pending" {
                if let orderId = rec.exchangeOrderId {
                    if await reconcile(orderId: orderId, plan: plan, api: api, day: day) { continue }
                    else { return } // neznámý výsledek → zkus příště
                } else {
                    // pending bez orderId (timeout před získáním orderId) → neblokuj dvojím nákupem,
                    // zastav catch-up dokud uživatel ručně neověří (už byl upozorněn při timeoutu).
                    return
                }
            }
            // 3) Claim zámku PŘED nákupem (idempotence).
            guard (try? execDao.tryClaim(planId: plan.id, dayEpoch: day)) == true else { continue }

            // 4) Multiplikátor z historického NUPL daného dne (nil → 1.0 fallback).
            let nupl = (try? nuplValues.get(dateEpochDay: day)) ?? nil
            let multiplier = NuplConfig.multiplier(nupl: nupl, config: config)
            let amount = roundDecimal(plan.amount * Decimal(Double(multiplier)), scale: 2)

            let minOrderSize = MinOrderSizeRepository.getMinOrderSize(exchange: plan.exchange, fiat: plan.fiat)
            if amount < minOrderSize {
                try? execDao.mark(planId: plan.id, dayEpoch: day, status: .failed, orderId: nil)
                continue
            }

            // 5) Nákup s timeoutem.
            let result = await withTimeout(seconds: 30) {
                await api.marketBuy(crypto: plan.crypto, fiat: plan.fiat, fiatAmount: amount)
            }

            switch result {
            case .some(.success(let tx)):
                let saved = Transaction(
                    planId: plan.id, exchange: plan.exchange, crypto: plan.crypto, fiat: plan.fiat,
                    fiatAmount: tx.fiatAmount, cryptoAmount: tx.cryptoAmount, price: tx.price,
                    fee: tx.fee, feeAsset: tx.feeAsset, status: tx.status, exchangeOrderId: tx.exchangeOrderId
                )
                try? activeDb.transactionDao.insert(saved)
                try? execDao.mark(planId: plan.id, dayEpoch: day,
                    status: tx.status == .pending ? .pending : .completed, orderId: tx.exchangeOrderId)
                // Postup lastExecutedAt jen po potvrzeném dni (poledne daného dne).
                try? activeDb.planDao.updateExecution(id: plan.id,
                    lastExecutedAt: Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200),
                    nextExecutionAt: calculateNextExecution(plan: plan, from: now))
                if tx.status == .pending { return } // neznámé → nepokračuj dál
            case .some(.error):
                // Známá chyba (order neproběhl) → mark failed, pokračuj dalším dnem.
                try? execDao.mark(planId: plan.id, dayEpoch: day, status: .failed, orderId: nil)
            case .none:
                // Timeout = NEZNÁMÝ výsledek → ponech pending (bez orderId), upozorni a NEPOKRAČUJ
                // (žádný re-buy naslepo; transakce se případně dohledá z CoinMate).
                saveInAppNotification(type: .error, title: "DCA výsledek nejistý",
                    message: "Nákup \(plan.crypto) (den \(day)) timeoutoval — ověř ručně na burze.", plan: plan)
                return
            }
        }
    }

    /// Rekonciliace: ověř přes order status, jestli order proběhl. true = vyřešeno, false = neznámé.
    private func reconcile(orderId: String, plan: DcaPlan, api: ExchangeApi, day: Int64) async -> Bool {
        guard let resolved = await api.getOrderStatus(orderId: orderId) else { return false }
        let saved = Transaction(
            planId: plan.id, exchange: plan.exchange, crypto: plan.crypto, fiat: plan.fiat,
            fiatAmount: resolved.fiatAmount, cryptoAmount: resolved.cryptoAmount, price: resolved.price,
            fee: resolved.fee, feeAsset: resolved.feeAsset, status: resolved.status, exchangeOrderId: orderId
        )
        try? activeDb.transactionDao.insert(saved)
        try? activeDb.dcaExecutionDao.mark(planId: plan.id, dayEpoch: day, status: .completed, orderId: orderId)
        return true
    }

    // MARK: - Pending Resolution

    private func resolvePendingTransactions() async {
        do {
            let pendingTxs = try activeDb.transactionDao.getPendingTransactions()
            let isSandbox = userPreferences.isSandboxMode()

            for tx in pendingTxs {
                guard let orderId = tx.exchangeOrderId else { continue }
                guard let credentials = credentialsStore.get(for: tx.exchange, isSandbox: isSandbox) else { continue }

                let api = exchangeApiFactory.create(credentials: credentials)
                if let resolved = await api.getOrderStatus(orderId: orderId) {
                    let updatedTx = Transaction(
                        id: tx.id,
                        planId: tx.planId,
                        exchange: tx.exchange,
                        crypto: tx.crypto,
                        fiat: tx.fiat,
                        fiatAmount: resolved.fiatAmount,
                        cryptoAmount: resolved.cryptoAmount,
                        price: resolved.price,
                        fee: resolved.fee,
                        feeAsset: resolved.feeAsset,
                        status: resolved.status,
                        exchangeOrderId: tx.exchangeOrderId,
                        executedAt: tx.executedAt
                    )
                    try activeDb.transactionDao.update(updatedTx)
                }
            }
        } catch {
            logger.warning("Failed to resolve pending transactions: \(error.localizedDescription)")
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func roundDecimal(_ value: Decimal, scale: Int) -> Decimal {
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain, scale: Int16(scale),
            raiseOnExactness: false, raiseOnOverflow: false,
            raiseOnUnderflow: false, raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value).rounding(accordingToBehavior: handler).decimalValue
    }
}
