import Foundation
import os

/// Calculates DCA purchase multiplier based on strategy and current market conditions.
final class CalculateStrategyMultiplierUseCase {
    private let marketDataService: MarketDataService
    private let logger = Logger(subsystem: "com.accbot.dca", category: "StrategyMultiplier")

    init(marketDataService: MarketDataService) {
        self.marketDataService = marketDataService
    }

    func invoke(
        strategy: DcaStrategy,
        crypto: String,
        fiat: String
    ) async -> StrategyMultiplierResult {
        switch strategy {
        case .classic:
            return StrategyMultiplierResult(
                multiplier: 1.0,
                reason: "Classic DCA: Fixed amount purchase"
            )

        case .athBased(let tiers):
            return await calculateAthBased(tiers: tiers, crypto: crypto, fiat: fiat)

        case .fearAndGreed(let tiers):
            return await calculateFearAndGreed(tiers: tiers)

        case .nupl(let config):
            // Live cesta (dnešní den): NUPL z MarketDataService. Per-day catch-up
            // (Plán 1 Task 6) počítá multiplikátor z NuplDao přímo.
            let nupl = await marketDataService.getNuplToday()
            let mult = NuplConfig.multiplier(nupl: nupl, config: config)
            return StrategyMultiplierResult(
                multiplier: mult,
                reason: nupl.map { "NUPL \(String(format: "%.3f", $0)) → \(formatMultiplier(mult))" }
                    ?? "NUPL nedostupné, výchozí množství"
            )
        }
    }

    private func calculateAthBased(tiers: [AthTier], crypto: String, fiat: String) async -> StrategyMultiplierResult {
        guard let currentPrice = await marketDataService.getCurrentPrice(crypto: crypto, fiat: fiat),
              let ath = await marketDataService.getAllTimeHigh(crypto: crypto, fiat: fiat),
              ath > 0
        else {
            logger.warning("Could not fetch ATH data for \(crypto)/\(fiat), using default multiplier")
            return StrategyMultiplierResult(multiplier: 1.0, reason: "ATH data unavailable, using default amount")
        }

        let currentDouble = NSDecimalNumber(decimal: currentPrice).doubleValue
        let athDouble = NSDecimalNumber(decimal: ath).doubleValue
        let athDistance = Float(1.0 - (currentDouble / athDouble))

        let sortedTiers = tiers.sorted { $0.maxDistancePercent < $1.maxDistancePercent }
        let multiplier = sortedTiers.first(where: { athDistance <= $0.maxDistancePercent })?.multiplier ?? 1.0

        let distancePercent = Int(athDistance * 100)
        logger.info("ATH-based: \(crypto) is \(distancePercent)% below ATH, multiplier: \(multiplier)")

        return StrategyMultiplierResult(
            multiplier: multiplier,
            reason: "\(crypto) is \(distancePercent)% below ATH \u{2192} \(formatMultiplier(multiplier))",
            marketData: MarketData(currentPrice: currentPrice, allTimeHigh: ath, fearGreedIndex: nil)
        )
    }

    private func calculateFearAndGreed(tiers: [FearGreedTier]) async -> StrategyMultiplierResult {
        guard let index = await marketDataService.getFearGreedIndex() else {
            logger.warning("Could not fetch Fear & Greed data, using default multiplier")
            return StrategyMultiplierResult(multiplier: 1.0, reason: "Fear & Greed data unavailable, using default amount")
        }

        let sortedTiers = tiers.sorted { $0.maxIndex < $1.maxIndex }
        let multiplier = sortedTiers.first(where: { index <= $0.maxIndex })?.multiplier ?? 1.0

        let classification = FearGreedClassification.label(for: index)
        logger.info("Fear & Greed: Index is \(index) (\(classification)), multiplier: \(multiplier)")

        return StrategyMultiplierResult(
            multiplier: multiplier,
            reason: "\(classification) (\(index)) \u{2192} \(formatMultiplier(multiplier))",
            marketData: MarketData(currentPrice: 0, allTimeHigh: nil, fearGreedIndex: index)
        )
    }

    private func formatMultiplier(_ multiplier: Float) -> String {
        let pct = Int(multiplier * 100)
        if multiplier == 1.0 {
            return "normal amount"
        }
        return "\(pct)% of base"
    }
}
