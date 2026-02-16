import Foundation

/// Tracks spending locally: per-tx, daily, hourly rate, and cooldown enforcement.
actor SpendingTracker {
    private var dailyEthSpent: UInt64 = 0
    private var dailyStablecoinSpent: UInt64 = 0
    private var currentDay: Int = 0
    private var txTimestamps: [Date] = []
    private var lastTxTime: Date?

    /// Check if a transaction is within spending limits.
    func check(
        ethAmount: UInt64,
        stablecoinAmount: UInt64,
        profile: SecurityProfile
    ) -> SpendingCheckResult {
        let now = Date()
        let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0

        // Reset daily counters if new day
        if day != currentDay {
            dailyEthSpent = 0
            dailyStablecoinSpent = 0
            currentDay = day
        }

        // Clean up old tx timestamps (keep last hour)
        let oneHourAgo = now.addingTimeInterval(-3600)
        txTimestamps.removeAll { $0 < oneHourAgo }

        // Per-tx ETH cap
        if ethAmount > profile.perTxEthCap {
            return .denied("ETH amount \(ethAmount) exceeds per-tx cap \(profile.perTxEthCap)")
        }

        // Per-tx stablecoin cap
        if stablecoinAmount > profile.perTxStablecoinCap {
            return .denied("Stablecoin amount \(stablecoinAmount) exceeds per-tx cap \(profile.perTxStablecoinCap)")
        }

        // Daily ETH cap
        if dailyEthSpent + ethAmount > profile.dailyEthCap {
            return .denied("Daily ETH cap would be exceeded")
        }

        // Daily stablecoin cap
        if dailyStablecoinSpent + stablecoinAmount > profile.dailyStablecoinCap {
            return .denied("Daily stablecoin cap would be exceeded")
        }

        // Hourly tx rate
        if txTimestamps.count >= profile.maxTxPerHour {
            return .denied("Hourly transaction limit reached (\(profile.maxTxPerHour)/hr)")
        }

        // Cooldown
        if let last = lastTxTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < Double(profile.minCooldownSeconds) {
                return .denied("Cooldown not elapsed (\(Int(elapsed))s / \(profile.minCooldownSeconds)s)")
            }
        }

        return .allowed
    }

    /// Record a completed transaction.
    func record(ethAmount: UInt64, stablecoinAmount: UInt64) {
        let now = Date()
        dailyEthSpent += ethAmount
        dailyStablecoinSpent += stablecoinAmount
        txTimestamps.append(now)
        lastTxTime = now
    }

    /// Get remaining daily budgets.
    func remainingBudgets(profile: SecurityProfile) -> (ethRemaining: UInt64, stablecoinRemaining: UInt64) {
        let ethRemaining = profile.dailyEthCap > dailyEthSpent ? profile.dailyEthCap - dailyEthSpent : 0
        let stableRemaining =
            profile.dailyStablecoinCap > dailyStablecoinSpent
            ? profile.dailyStablecoinCap - dailyStablecoinSpent : 0
        return (ethRemaining, stableRemaining)
    }

    /// Get current hourly tx count.
    func currentHourlyCount() -> Int {
        let oneHourAgo = Date().addingTimeInterval(-3600)
        return txTimestamps.filter { $0 >= oneHourAgo }.count
    }
}

enum SpendingCheckResult {
    case allowed
    case denied(String)
}
