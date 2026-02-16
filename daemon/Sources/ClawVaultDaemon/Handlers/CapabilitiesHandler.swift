import Foundation

/// GET /capabilities — Return current limits, budgets, gas status.
struct CapabilitiesHandler {
    let config: DaemonConfig
    let policyEngine: PolicyEngine
    let chainClient: ChainClient

    func handle(request: HTTPRequest) async -> HTTPResponse {
        guard let walletAddress = config.walletAddress else {
            return .error(503, "Wallet not deployed yet")
        }

        let profile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let budgets = await policyEngine.remainingBudgets()
        let gasStatus = await GasPreflight.gasStatus(
            walletAddress: walletAddress,
            chainClient: chainClient
        )
        let isFrozen = await policyEngine.isFrozen

        return .json(200, [
            "profile": profile.name,
            "homeChainId": config.homeChainId,
            "frozen": isFrozen,
            "gasStatus": gasStatus,
            "limits": [
                "perTxStablecoinCap": profile.perTxStablecoinCap,
                "dailyStablecoinCap": profile.dailyStablecoinCap,
                "perTxEthCap": profile.perTxEthCap,
                "dailyEthCap": profile.dailyEthCap,
                "maxTxPerHour": profile.maxTxPerHour,
                "maxSlippageBps": profile.maxSlippageBps,
            ],
            "remaining": [
                "ethDaily": budgets.ethRemaining,
                "stablecoinDaily": budgets.stablecoinRemaining,
            ],
        ] as [String: Any])
    }
}
