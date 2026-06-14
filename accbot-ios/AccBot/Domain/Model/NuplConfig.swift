import Foundation

/// NUPL strategy configuration — port z C# settings.json (NuplBottomValue/Center/Min/MaxMultiplier).
struct NuplConfig: Codable, Equatable, Sendable {
    let bottomValue: Double   // NUPL ≤ bottom → maxMultiplier
    let centerValue: Double   // NUPL ≥ center → minMultiplier
    let minMultiplier: Float
    let maxMultiplier: Float

    static let `default` = NuplConfig(
        bottomValue: 0.0, centerValue: 0.5, minMultiplier: 0.5, maxMultiplier: 3.0
    )

    /// Čistá funkce — port z C# TuiDcaService.CalculateMultiplier.
    /// nil NUPL → 1.0 (fallback, jako C#).
    static func multiplier(nupl: Double?, config: NuplConfig) -> Float {
        guard let nupl else { return 1.0 }
        if nupl <= config.bottomValue { return config.maxMultiplier }
        if nupl >= config.centerValue { return config.minMultiplier }
        let range = config.centerValue - config.bottomValue
        let position = Float((nupl - config.bottomValue) / range)
        return config.maxMultiplier - position * (config.maxMultiplier - config.minMultiplier)
    }
}
