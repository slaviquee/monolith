import Foundation

/// Spending limits and DeFi configuration for a security profile.
struct SecurityProfile {
    let name: String
    let perTxStablecoinCap: UInt64   // in USDC minor units (6 decimals)
    let dailyStablecoinCap: UInt64
    let perTxEthCap: UInt64          // in wei
    let dailyEthCap: UInt64
    let maxTxPerHour: Int
    let minCooldownSeconds: Int
    let maxSlippageBps: Int          // basis points (100 = 1%)

    static let balanced = SecurityProfile(
        name: "balanced",
        perTxStablecoinCap: 100_000_000,         // 100 USDC (6 decimals)
        dailyStablecoinCap: 500_000_000,          // 500 USDC
        perTxEthCap: 50_000_000_000_000_000,      // 0.05 ETH
        dailyEthCap: 250_000_000_000_000_000,     // 0.25 ETH
        maxTxPerHour: 10,
        minCooldownSeconds: 5,
        maxSlippageBps: 100                        // 1%
    )

    static let autonomous = SecurityProfile(
        name: "autonomous",
        perTxStablecoinCap: 250_000_000,          // 250 USDC
        dailyStablecoinCap: 2_000_000_000,         // 2000 USDC
        perTxEthCap: 150_000_000_000_000_000,      // 0.15 ETH
        dailyEthCap: 750_000_000_000_000_000,      // 0.75 ETH
        maxTxPerHour: 30,
        minCooldownSeconds: 2,
        maxSlippageBps: 200                         // 2%
    )

    static func forName(_ name: String) -> SecurityProfile? {
        switch name.lowercased() {
        case "balanced": return .balanced
        case "autonomous": return .autonomous
        default: return nil
        }
    }
}
