import Foundation

/// Syncs on-chain freeze state to the local daemon.
/// One-way: on-chain frozen → force local frozen. Never auto-unfreezes.
/// Runs an initial sync before the daemon accepts connections, then polls every 60s.
actor FreezeSyncService {
    private let services: ServiceContainer
    private let configStore: ConfigStore
    private let auditLogger: AuditLogger
    private let syncInterval: TimeInterval = 60

    /// frozen() selector on MonolithWallet
    private static let frozenSelector = "0x054f7d9c"

    init(services: ServiceContainer, configStore: ConfigStore, auditLogger: AuditLogger) {
        self.services = services
        self.configStore = configStore
        self.auditLogger = auditLogger
    }

    /// Synchronous startup check — call before server accepts connections.
    /// Queries on-chain frozen state and forces local freeze if needed.
    func syncOnce() async {
        let config = configStore.read()
        guard let walletAddress = config.walletAddress else {
            print("[FreezeSync] No wallet deployed — skipping sync")
            return
        }

        do {
            // Counterfactual wallet address may be configured before deployment.
            // Skip freeze sync until code exists at the address to avoid false "frozen" reads.
            let deployed = try await isWalletDeployed(walletAddress: walletAddress)
            guard deployed else {
                print("[FreezeSync] Wallet not yet deployed — skipping sync")
                return
            }

            let frozenOnChain = try await queryOnChainFrozen(walletAddress: walletAddress)

            if frozenOnChain && !config.frozen {
                // On-chain frozen but local is not → force local freeze
                await services.policyEngine.freeze()
                try? configStore.update { $0.frozen = true }
                await auditLogger.log(
                    action: "freeze_sync",
                    decision: "forced",
                    reason: "On-chain wallet is frozen — forcing local freeze"
                )
                print("[FreezeSync] On-chain freeze detected — local state forced frozen")
            } else {
                print("[FreezeSync] Sync OK (onChain=\(frozenOnChain), local=\(config.frozen))")
            }
            // Never auto-unfreeze: if local frozen && !onChain frozen, user must explicitly /unfreeze
        } catch {
            // Network errors → fail safe (don't change state)
            print("[FreezeSync] Warning: sync failed (network error: \(error.localizedDescription))")
            await auditLogger.log(
                action: "freeze_sync",
                decision: "warning",
                reason: "Sync failed: \(error.localizedDescription)"
            )
        }
    }

    /// Start periodic sync loop. Call from a detached task after startup.
    func startPeriodicSync() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(syncInterval * 1_000_000_000))
            guard !Task.isCancelled else { break }
            await syncOnce()
        }
    }

    // MARK: - Private

    private func isWalletDeployed(walletAddress: String) async throws -> Bool {
        let code = try await services.chainClient.getCode(address: walletAddress)
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "0x", with: "")
        return !cleaned.isEmpty && cleaned.contains { $0 != "0" }
    }

    /// Query the on-chain `frozen()` view function.
    private func queryOnChainFrozen(walletAddress: String) async throws -> Bool {
        let result = try await services.chainClient.ethCall(to: walletAddress, data: Self.frozenSelector)
        guard let resultData = SignatureUtils.fromHex(result), resultData.count >= 32 else {
            // Can't parse → assume frozen (fail safe)
            return true
        }
        return resultData[31] != 0
    }
}
