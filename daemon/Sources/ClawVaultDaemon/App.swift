import Foundation

/// ClawVault Signing Daemon
/// macOS background service that manages Secure Enclave keys, enforces spending policy,
/// and constructs/signs ERC-4337 UserOperations.

@main
struct ClawVaultDaemon {
    static func main() async {
        print("[ClawVault] Starting daemon v0.1.0")

        // Load or create config
        var config: DaemonConfig
        do {
            // Ensure config directory exists
            let fm = FileManager.default
            if !fm.fileExists(atPath: DaemonConfig.configDir.path) {
                try fm.createDirectory(at: DaemonConfig.configDir, withIntermediateDirectories: true)
                try fm.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: DaemonConfig.configDir.path)
            }

            config = (try? DaemonConfig.load()) ?? DaemonConfig.defaultConfig()
            try config.save()
        } catch {
            print("[ClawVault] ERROR: Failed to initialize config: \(error)")
            return
        }

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

        // Initialize policy engine
        let profile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let stablecoinRegistry = StablecoinRegistry()
        let protocolRegistry = ProtocolRegistry(profile: config.activeProfile)
        let policyEngine = PolicyEngine(
            profile: profile,
            protocolRegistry: protocolRegistry,
            stablecoinRegistry: stablecoinRegistry,
            frozen: config.frozen,
            chainClient: chainClient,
            chainId: config.homeChainId
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
        let addressHandler = AddressHandler(config: config, seManager: seManager)
        router.register("GET", "/address") { req in
            await addressHandler.handle(request: req)
        }

        // Capabilities
        let capsHandler = CapabilitiesHandler(
            config: config,
            policyEngine: policyEngine,
            chainClient: chainClient
        )
        router.register("GET", "/capabilities") { req in
            await capsHandler.handle(request: req)
        }

        // Decode
        let decodeHandler = DecodeHandler(
            config: config,
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
            config: config
        )
        router.register("POST", "/sign") { req in
            await signHandler.handle(request: req)
        }

        // Policy
        let policyHandler = PolicyHandler(
            config: config,
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

        // Allowlist
        let allowlistHandler = AllowlistHandler(
            policyEngine: policyEngine,
            seManager: seManager,
            auditLogger: auditLogger
        )
        router.register("POST", "/allowlist") { req in
            await allowlistHandler.handle(request: req)
        }

        // Panic
        let panicHandler = PanicHandler(
            policyEngine: policyEngine,
            auditLogger: auditLogger,
            configUpdater: { cfg in cfg.frozen = true },
            userOpBuilder: userOpBuilder,
            seManager: seManager,
            bundlerClient: bundlerClient,
            config: config
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
