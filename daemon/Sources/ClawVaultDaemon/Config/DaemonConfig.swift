import Foundation

/// Persistent daemon configuration stored at ~/.clawvault/config.json
struct DaemonConfig: Codable {
    var activeProfile: String // "balanced" or "autonomous"
    var homeChainId: UInt64 // 1 or 8453
    var walletAddress: String? // hex address, set after deployment
    var factoryAddress: String
    var entryPointAddress: String
    var recoveryAddress: String?
    var precompileAvailable: Bool?
    var frozen: Bool
    /// D13: Optional custom bundler URL. If set, overrides the default Pimlico public endpoint.
    var customBundlerURL: String?

    // Custom limit overrides — when present, these override the profile defaults
    var customPerTxStablecoinCap: UInt64?
    var customDailyStablecoinCap: UInt64?
    var customPerTxEthCap: UInt64?
    var customDailyEthCap: UInt64?
    var customMaxTxPerHour: Int?
    var customMaxSlippageBps: Int?
    var allowlistedAddresses: [String]?

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawvault")
    static let configPath = configDir.appendingPathComponent("config.json")
    static let socketPath = configDir.appendingPathComponent("daemon.sock").path

    static let defaultEntryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
    // Factory address — set after deployment. This is a placeholder for the deployed ClawVaultFactory.
    static let defaultFactory = "0x0000000000000000000000000000000000000000"

    static func load() throws -> DaemonConfig {
        let data = try Data(contentsOf: configPath)
        return try JSONDecoder().decode(DaemonConfig.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: DaemonConfig.configPath, options: .atomic)
    }

    static func defaultConfig() -> DaemonConfig {
        DaemonConfig(
            activeProfile: "balanced",
            homeChainId: 8453,
            factoryAddress: defaultFactory,
            entryPointAddress: defaultEntryPoint,
            frozen: false
        )
    }
}

/// Thread-safe shared reference to DaemonConfig.
/// Solves the value-type copy problem: all handlers share one ConfigStore instance.
final class ConfigStore: @unchecked Sendable {
    private var config: DaemonConfig
    private let lock = NSLock()

    init(_ config: DaemonConfig) {
        self.config = config
    }

    /// Read a snapshot of the current config.
    func read() -> DaemonConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Mutate the config and persist to disk atomically.
    func update(_ mutate: (inout DaemonConfig) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        mutate(&config)
        try config.save()
    }
}

/// Chain RPC configuration
struct ChainConfig {
    let chainId: UInt64
    let rpcURL: String
    let bundlerURL: String

    static let ethereum = ChainConfig(
        chainId: 1,
        rpcURL: "https://cloudflare-eth.com",
        bundlerURL: "https://public.pimlico.io/v2/1/rpc"
    )

    static let base = ChainConfig(
        chainId: 8453,
        rpcURL: "https://mainnet.base.org",
        bundlerURL: "https://public.pimlico.io/v2/8453/rpc"
    )

    static func forChain(_ chainId: UInt64) -> ChainConfig? {
        switch chainId {
        case 1: return .ethereum
        case 8453: return .base
        default: return nil
        }
    }
}
