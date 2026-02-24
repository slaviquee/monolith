import Foundation

/// Gas preflight check: verify wallet has sufficient ETH before submission.
enum GasPreflight {
    /// D10: Additive gas buffer instead of multiplicative — 0.001 ETH (1_000_000_000_000_000 wei).
    /// A fixed buffer is more predictable than a percentage, especially for small/large transactions.
    static let minBufferWei: UInt64 = 1_000_000_000_000_000

    /// Minimum gas balance to consider "ok" for capabilities reporting (0.005 ETH).
    static let lowGasThreshold: UInt64 = 5_000_000_000_000_000

    struct PreflightResult {
        let sufficient: Bool
        let walletBalance: UInt64
        let estimatedCost: UInt64
        let message: String?
    }

    /// Check if the wallet has enough ETH to cover the estimated gas cost.
    static func check(
        walletAddress: String,
        gasEstimate: BundlerClient.GasEstimate,
        maxFeePerGas: UInt64,
        chainClient: ChainClient,
        bufferWei: UInt64 = minBufferWei
    ) async throws -> PreflightResult {
        let balance = try await chainClient.getBalance(address: walletAddress)

        // Compute estimated maximum cost with additive buffer
        let totalGas = gasEstimate.preVerificationGas + gasEstimate.verificationGasLimit
            + gasEstimate.callGasLimit
        let baseCost = totalGas * maxFeePerGas
        let estimatedCost = baseCost + bufferWei

        if balance >= estimatedCost {
            return PreflightResult(
                sufficient: true,
                walletBalance: balance,
                estimatedCost: estimatedCost,
                message: nil
            )
        }

        let shortfall = estimatedCost - balance
        let shortfallETH = Double(shortfall) / 1e18
        return PreflightResult(
            sufficient: false,
            walletBalance: balance,
            estimatedCost: estimatedCost,
            message: String(
                format: "Insufficient gas: wallet needs ~%.6f more ETH", shortfallETH)
        )
    }

    /// Report gas status for /capabilities endpoint.
    static func gasStatus(walletAddress: String, chainClient: ChainClient) async -> String {
        do {
            let balance = try await chainClient.getBalance(address: walletAddress)
            return balance >= lowGasThreshold ? "ok" : "low"
        } catch {
            return "low"
        }
    }
}
