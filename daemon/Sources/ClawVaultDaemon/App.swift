import Foundation

/// ClawVault Signing Daemon
/// macOS background service that manages Secure Enclave keys, enforces spending policy,
/// and constructs/signs ERC-4337 UserOperations.

@main
struct ClawVaultDaemon {
    static func main() async {
        print("[ClawVault] Starting daemon v0.1.0")

        // Load or create config
        let configStore: ConfigStore
        do {
            // Ensure config directory exists
            let fm = FileManager.default
            if !fm.fileExists(atPath: DaemonConfig.configDir.path) {
                try fm.createDirectory(at: DaemonConfig.configDir, withIntermediateDirectories: true)
                try fm.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: DaemonConfig.configDir.path)
            }

            let config = (try? DaemonConfig.load()) ?? DaemonConfig.defaultConfig()
            try config.save()
            configStore = ConfigStore(config)
        } catch {
            print("[ClawVault] ERROR: Failed to initialize config: \(error)")
            return
        }

        // Read initial config snapshot for startup
        var config = configStore.read()

        // Initialize Secure Enclave
        let seManager = SecureEnclaveManager()
        do {
            try await seManager.initialize()
            let pubKey = try await seManager.signingPublicKey()
            print(
                "[ClawVault] Secure Enclave initialized. Signing key: \(SignatureUtils.toHex(pubKey.x).prefix(18))..."
            )
        } catch {
            print("[ClawVault] ERROR: Secure Enclave not available: \(error)")
            print("[ClawVault] Running in degraded mode (no signing capability)")
        }

        // Initialize chain and bundler clients
        guard let chainConfig = ChainConfig.forChain(config.homeChainId) else {
            print("[ClawVault] ERROR: Unknown chain ID \(config.homeChainId)")
            return
        }

        let chainClient = ChainClient(rpcURL: chainConfig.rpcURL)
        // D13: Use custom bundler URL if configured, otherwise use default Pimlico endpoint
        let bundlerURL = config.customBundlerURL ?? chainConfig.bundlerURL
        let bundlerClient = BundlerClient(bundlerURL: bundlerURL)

        // Probe P-256 precompile at 0x100 and cache result
        if config.precompileAvailable == nil {
            let precompileAvailable = await PrecompileProbe.probe(chainClient: chainClient)
            try? configStore.update { $0.precompileAvailable = precompileAvailable }
            config = configStore.read()
            print("[ClawVault] Precompile probe: \(precompileAvailable ? "available" : "not available")")
        }

        // Initialize policy engine with overrides applied
        let baseProfile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let effectiveProfile = baseProfile.withOverrides(
            perTxStablecoinCap: config.customPerTxStablecoinCap,
            dailyStablecoinCap: config.customDailyStablecoinCap,
            perTxEthCap: config.customPerTxEthCap,
            dailyEthCap: config.customDailyEthCap,
            maxTxPerHour: config.customMaxTxPerHour,
            maxSlippageBps: config.customMaxSlippageBps
        )
        let stablecoinRegistry = StablecoinRegistry()
        let protocolRegistry = ProtocolRegistry(profile: config.activeProfile)
        let persistedAllowlist = Set((config.allowlistedAddresses ?? []).map { $0.lowercased() })
        let policyEngine = PolicyEngine(
            profile: effectiveProfile,
            protocolRegistry: protocolRegistry,
            stablecoinRegistry: stablecoinRegistry,
            allowlistedAddresses: persistedAllowlist,
            frozen: config.frozen,
            chainClient: chainClient,
            chainId: config.homeChainId,
            walletAddress: config.walletAddress
        )

        // Initialize other components
        let userOpBuilder = UserOpBuilder(
            chainClient: chainClient,
            bundlerClient: bundlerClient,
            entryPoint: config.entryPointAddress,
            chainId: config.homeChainId
        )
        let approvalManager = ApprovalManager()
        let auditLogger = AuditLogger()

        // Set up router
        let router = RequestRouter()

        // Health — no auth
        router.register("GET", "/health") { req in
            await HealthHandler.handle(request: req)
        }

        // Address
        let addressHandler = AddressHandler(configStore: configStore, seManager: seManager)
        router.register("GET", "/address") { req in
            await addressHandler.handle(request: req)
        }

        // Capabilities
        let capsHandler = CapabilitiesHandler(
            configStore: configStore,
            policyEngine: policyEngine,
            chainClient: chainClient,
            protocolRegistry: protocolRegistry
        )
        router.register("GET", "/capabilities") { req in
            await capsHandler.handle(request: req)
        }

        // Decode
        let decodeHandler = DecodeHandler(
            configStore: configStore,
            stablecoinRegistry: stablecoinRegistry,
            protocolRegistry: protocolRegistry
        )
        router.register("POST", "/decode") { req in
            await decodeHandler.handle(request: req)
        }

        // Sign
        let signHandler = SignHandler(
            policyEngine: policyEngine,
            userOpBuilder: userOpBuilder,
            seManager: seManager,
            bundlerClient: bundlerClient,
            chainClient: chainClient,
            approvalManager: approvalManager,
            auditLogger: auditLogger,
            configStore: configStore
        )
        router.register("POST", "/sign") { req in
            await signHandler.handle(request: req)
        }

        // Policy
        let policyHandler = PolicyHandler(
            configStore: configStore,
            policyEngine: policyEngine,
            seManager: seManager,
            auditLogger: auditLogger
        )
        router.register("GET", "/policy") { req in
            await policyHandler.handleGet(request: req)
        }
        router.register("POST", "/policy/update") { req in
            await policyHandler.handleUpdate(request: req)
        }

        // Setup
        let setupHandler = SetupHandler(
            seManager: seManager,
            chainClient: chainClient,
            bundlerClient: bundlerClient,
            userOpBuilder: userOpBuilder,
            auditLogger: auditLogger,
            configStore: configStore
        )
        router.register("POST", "/setup") { req in
            await setupHandler.handleSetup(request: req)
        }
        router.register("POST", "/setup/deploy") { req in
            await setupHandler.handleDeploy(request: req)
        }

        // Allowlist
        let allowlistHandler = AllowlistHandler(
            policyEngine: policyEngine,
            seManager: seManager,
            auditLogger: auditLogger,
            configStore: configStore
        )
        router.register("POST", "/allowlist") { req in
            await allowlistHandler.handle(request: req)
        }

        // Panic
        let panicHandler = PanicHandler(
            policyEngine: policyEngine,
            auditLogger: auditLogger,
            userOpBuilder: userOpBuilder,
            seManager: seManager,
            bundlerClient: bundlerClient,
            configStore: configStore
        )
        router.register("POST", "/panic") { req in
            await panicHandler.handle(request: req)
        }

        // Audit log
        let auditLogHandler = AuditLogHandler(auditLogger: auditLogger)
        router.register("GET", "/audit-log") { req in
            await auditLogHandler.handle(request: req)
        }

        // Start socket server
        let server = SocketServer(socketPath: DaemonConfig.socketPath, router: router)
        do {
            try await server.start()
            print("[ClawVault] Listening on \(DaemonConfig.socketPath)")
            print(
                "[ClawVault] Profile: \(config.activeProfile), Chain: \(config.homeChainId)"
            )

            // Request notification permission
            await NotificationSender.requestPermission()

            // Accept connections forever
            await server.acceptLoop()
        } catch {
            print("[ClawVault] ERROR: Failed to start server: \(error)")
        }
    }
}
