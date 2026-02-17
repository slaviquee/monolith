import Foundation

/// Thread-safe container for chain-dependent services that must be rebuilt
/// when /setup changes homeChainId or activeProfile.
/// All handlers access services through this container per-request.
final class ServiceContainer: @unchecked Sendable {
    private let lock = NSLock()
    private var _chainClient: ChainClient
    private var _bundlerClient: BundlerClient
    private var _userOpBuilder: UserOpBuilder
    private var _policyEngine: PolicyEngine
    private var _protocolRegistry: ProtocolRegistry
    private var _stablecoinRegistry: StablecoinRegistry

    var chainClient: ChainClient {
        lock.lock()
        defer { lock.unlock() }
        return _chainClient
    }

    var bundlerClient: BundlerClient {
        lock.lock()
        defer { lock.unlock() }
        return _bundlerClient
    }

    var userOpBuilder: UserOpBuilder {
        lock.lock()
        defer { lock.unlock() }
        return _userOpBuilder
    }

    var policyEngine: PolicyEngine {
        lock.lock()
        defer { lock.unlock() }
        return _policyEngine
    }

    var protocolRegistry: ProtocolRegistry {
        lock.lock()
        defer { lock.unlock() }
        return _protocolRegistry
    }

    var stablecoinRegistry: StablecoinRegistry {
        lock.lock()
        defer { lock.unlock() }
        return _stablecoinRegistry
    }

    init(
        chainClient: ChainClient,
        bundlerClient: BundlerClient,
        userOpBuilder: UserOpBuilder,
        policyEngine: PolicyEngine,
        protocolRegistry: ProtocolRegistry,
        stablecoinRegistry: StablecoinRegistry
    ) {
        self._chainClient = chainClient
        self._bundlerClient = bundlerClient
        self._userOpBuilder = userOpBuilder
        self._policyEngine = policyEngine
        self._protocolRegistry = protocolRegistry
        self._stablecoinRegistry = stablecoinRegistry
    }

    /// Rebuild all chain-dependent services from updated config.
    /// Called by SetupHandler after configStore.update().
    func reconfigure(config: DaemonConfig) {
        lock.lock()
        defer { lock.unlock() }

        guard let chainConfig = ChainConfig.forChain(config.homeChainId) else { return }

        let newChainClient = ChainClient(rpcURL: chainConfig.rpcURL)
        let bundlerURL = config.customBundlerURL ?? chainConfig.bundlerURL
        let newBundlerClient = BundlerClient(bundlerURL: bundlerURL)

        let baseProfile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let effectiveProfile = baseProfile.withOverrides(
            perTxStablecoinCap: config.customPerTxStablecoinCap,
            dailyStablecoinCap: config.customDailyStablecoinCap,
            perTxEthCap: config.customPerTxEthCap,
            dailyEthCap: config.customDailyEthCap,
            maxTxPerHour: config.customMaxTxPerHour,
            maxSlippageBps: config.customMaxSlippageBps
        )

        let newStablecoinRegistry = StablecoinRegistry()
        let newProtocolRegistry = ProtocolRegistry(profile: config.activeProfile)
        let persistedAllowlist = Set((config.allowlistedAddresses ?? []).map { $0.lowercased() })

        let newPolicyEngine = PolicyEngine(
            profile: effectiveProfile,
            protocolRegistry: newProtocolRegistry,
            stablecoinRegistry: newStablecoinRegistry,
            allowlistedAddresses: persistedAllowlist,
            frozen: config.frozen,
            chainClient: newChainClient,
            chainId: config.homeChainId,
            walletAddress: config.walletAddress
        )

        let newUserOpBuilder = UserOpBuilder(
            chainClient: newChainClient,
            bundlerClient: newBundlerClient,
            entryPoint: config.entryPointAddress,
            chainId: config.homeChainId
        )

        _chainClient = newChainClient
        _bundlerClient = newBundlerClient
        _userOpBuilder = newUserOpBuilder
        _policyEngine = newPolicyEngine
        _protocolRegistry = newProtocolRegistry
        _stablecoinRegistry = newStablecoinRegistry
    }
}
