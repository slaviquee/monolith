import Foundation
import Testing

@testable import ClawVaultDaemon

@Suite("SpendingTracker")
struct SpendingTrackerTests {
    @Test func allowWithinLimits() async {
        let tracker = SpendingTracker()
        let result = await tracker.check(ethAmount: 10_000_000_000_000_000, stablecoinAmount: 0, profile: .balanced)
        guard case .allowed = result else { Issue.record("Expected allowed"); return }
    }

    @Test func denyOverPerTxCap() async {
        let tracker = SpendingTracker()
        let result = await tracker.check(ethAmount: 100_000_000_000_000_000, stablecoinAmount: 0, profile: .balanced)
        guard case .denied(let reason) = result else { Issue.record("Expected denied"); return }
        #expect(reason.contains("per-tx cap"))
    }

    @Test func denyOverStablecoinCap() async {
        let tracker = SpendingTracker()
        let result = await tracker.check(ethAmount: 0, stablecoinAmount: 200_000_000, profile: .balanced)
        guard case .denied(let reason) = result else { Issue.record("Expected denied"); return }
        #expect(reason.contains("per-tx cap"))
    }

    @Test func dailyCapAccumulation() async {
        let tracker = SpendingTracker()
        for _ in 0..<5 {
            let result = await tracker.check(ethAmount: 40_000_000_000_000_000, stablecoinAmount: 0, profile: .balanced)
            if case .allowed = result {
                await tracker.record(ethAmount: 40_000_000_000_000_000, stablecoinAmount: 0)
            }
        }
        let result = await tracker.check(ethAmount: 40_000_000_000_000_000, stablecoinAmount: 0, profile: .balanced)
        guard case .denied(let reason) = result else { Issue.record("Expected denied"); return }
        #expect(reason.contains("Daily ETH cap"))
    }

    @Test func remainingBudgets() async {
        let tracker = SpendingTracker()
        await tracker.record(ethAmount: 100_000_000_000_000_000, stablecoinAmount: 0)
        let budgets = await tracker.remainingBudgets(profile: .balanced)
        #expect(budgets.ethRemaining == 150_000_000_000_000_000)
    }
}
