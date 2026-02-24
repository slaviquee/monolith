import CryptoKit
import Foundation

/// Persistent daemon configuration stored at ~/.monolith/config.json
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
        .appendingPathComponent(".monolith")
    static let configPath = configDir.appendingPathComponent("config.json")
    static let configSigPath = configDir.appendingPathComponent("config.sig")
    static let socketPath = configDir.appendingPathComponent("daemon.sock").path

    static let defaultEntryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
    /// Placeholder for "factory not configured".
    static let unsetFactory = "0x0000000000000000000000000000000000000000"
    /// Shared production MonolithFactory — same address on Ethereum L1 and Base
    /// (deployed via CREATE2 through Nick's deterministic deployer).
    static let sharedFactory = "0x4dA0408c8c655eC8576c33fB3a442412C82d8905"
    /// Backward-compatible default used by older call sites.
    static let defaultFactory = sharedFactory

    static func defaultFactory(forChain chainId: UInt64) -> String {
        switch chainId {
        case 1, 8453:
            return sharedFactory
        default:
            return unsetFactory
        }
    }

    /// Load config without integrity verification (for first-run or legacy migration).
    static func load() throws -> DaemonConfig {
        let data = try Data(contentsOf: configPath)
        return try JSONDecoder().decode(DaemonConfig.self, from: data)
    }

    /// Load config with SE signature verification over raw disk bytes.
    /// Returns nil if signature is missing or invalid (caller should enter safe mode).
    static func loadVerified(publicKey: P256.Signing.PublicKey) -> DaemonConfig? {
        // Read raw bytes from disk — never re-serialize before verifying
        guard let rawBytes = try? Data(contentsOf: configPath) else {
            return nil
        }
        guard let sigBytes = try? Data(contentsOf: configSigPath) else {
            return nil
        }
        // Verify signature over the exact raw bytes
        guard sigBytes.count == 64 else { return nil }
        let r = sigBytes.prefix(32)
        let s = sigBytes.suffix(32)
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: r + s) else {
            return nil
        }
        guard publicKey.isValidSignature(signature, for: rawBytes) else {
            return nil
        }
        // Signature valid — now decode
        guard let config = try? JSONDecoder().decode(DaemonConfig.self, from: rawBytes) else {
            return nil
        }
        return config
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: DaemonConfig.configPath, options: .atomic)
    }

    /// Save config and sign with SE signing key.
    func save(signer: SecureEnclave.P256.Signing.PrivateKey) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: DaemonConfig.configPath, options: .atomic)

        // Sign the exact bytes we wrote and store signature
        let signature = try signer.signature(for: data)
        let sigData = signature.rawRepresentation  // r (32) || s (32)
        try sigData.write(to: DaemonConfig.configSigPath, options: .atomic)
    }

    static func defaultConfig() -> DaemonConfig {
        DaemonConfig(
            activeProfile: "balanced",
            homeChainId: 8453,
            factoryAddress: defaultFactory(forChain: 8453),
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
    /// SE signing key for config integrity. Set after SE initialization.
    private var signer: SecureEnclave.P256.Signing.PrivateKey?

    init(_ config: DaemonConfig) {
        self.config = config
    }

    /// Set the SE signing key for signed config writes.
    func setSigner(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        lock.lock()
        defer { lock.unlock() }
        signer = key
    }

    /// Read a snapshot of the current config.
    func read() -> DaemonConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// Mutate the config and persist to disk atomically.
    /// If a signer is set, the config is also signed with the SE key.
    func update(_ mutate: (inout DaemonConfig) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        mutate(&config)
        if let signer = signer {
            try config.save(signer: signer)
        } else {
            try config.save()
        }
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
