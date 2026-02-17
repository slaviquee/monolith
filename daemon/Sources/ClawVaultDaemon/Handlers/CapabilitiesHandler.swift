import Foundation

/// GET /capabilities — Return current limits, budgets, gas status.
struct CapabilitiesHandler {
    let configStore: ConfigStore
    let services: ServiceContainer

    func handle(request: HTTPRequest) async -> HTTPResponse {
        let config = configStore.read()

        guard let walletAddress = config.walletAddress else {
            return .error(503, "Wallet not deployed yet")
        }

        let baseProfile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let profile = baseProfile.withOverrides(
            perTxStablecoinCap: config.customPerTxStablecoinCap,
            dailyStablecoinCap: config.customDailyStablecoinCap,
            perTxEthCap: config.customPerTxEthCap,
            dailyEthCap: config.customDailyEthCap,
            maxTxPerHour: config.customMaxTxPerHour,
            maxSlippageBps: config.customMaxSlippageBps
        )
        let budgets = await services.policyEngine.remainingBudgets()
        let gasStatus = await GasPreflight.gasStatus(
            walletAddress: walletAddress,
            chainClient: services.chainClient
        )
        let isFrozen = await services.policyEngine.isFrozen
        let allowlist = await services.policyEngine.currentAllowlist
        let protocols = services.protocolRegistry.protocols(forChain: config.homeChainId)

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
                "minCooldownSeconds": profile.minCooldownSeconds,
            ],
            "remaining": [
                "ethDaily": budgets.ethRemaining,
                "stablecoinDaily": budgets.stablecoinRemaining,
            ],
            "allowlistedAddresses": Array(allowlist),
            "allowedProtocols": protocols,
            "autopilotEligible": [
                "eth_transfer_allowlisted",
                "stablecoin_transfer_allowlisted",
                "uniswap_swap",
                "aave_deposit",
                "aave_withdraw",
            ],
        ] as [String: Any])
    }
}
