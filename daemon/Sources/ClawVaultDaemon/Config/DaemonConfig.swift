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

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawvault")
    static let configPath = configDir.appendingPathComponent("config.json")
    static let socketPath = configDir.appendingPathComponent("daemon.sock").path

    static let defaultEntryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

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
            factoryAddress: "",
            entryPointAddress: defaultEntryPoint,
            frozen: false
        )
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
