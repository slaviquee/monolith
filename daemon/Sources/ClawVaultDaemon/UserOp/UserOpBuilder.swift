import Foundation

/// Constructs complete UserOperations from intents.
/// The daemon exclusively owns nonce, gas, chainId, fees — the skill MUST NOT set these.
actor UserOpBuilder {
    private let chainClient: ChainClient
    private let bundlerClient: BundlerClient
    private let entryPoint: String
    private let chainId: UInt64

    init(chainClient: ChainClient, bundlerClient: BundlerClient, entryPoint: String, chainId: UInt64) {
        self.chainClient = chainClient
        self.bundlerClient = bundlerClient
        self.entryPoint = entryPoint
        self.chainId = chainId
    }

    /// Build a complete UserOperation from an intent.
    func build(
        sender: String,
        target: String,
        value: UInt64,
        calldata: Data,
        initCode: Data = Data()
    ) async throws -> UserOperation {
        // 1. Get nonce from EntryPoint
        let nonce = try await getNonce(sender: sender)

        // 2. Encode the wallet's execute() call
        let walletCallData = encodeExecuteCall(target: target, value: value, data: calldata)

        // 3. Fetch current gas prices from the chain
        let gasPrice = try await chainClient.getGasPrice()
        // Use 2x base fee as maxFeePerGas with a reasonable floor
        let maxFeePerGas = max(gasPrice * 2, 100_000_000) // at least 0.1 gwei
        let maxPriorityFeePerGas = max(gasPrice / 10, 10_000_000) // ~10% of base, floor 0.01 gwei

        // 4. Build preliminary UserOp for gas estimation
        var userOp = UserOperation(
            sender: sender,
            nonce: nonce,
            initCode: initCode,
            callData: walletCallData,
            accountGasLimits: UserOperation.packGasLimits(
                verificationGasLimit: 200_000, callGasLimit: 200_000),
            preVerificationGas: uint256(50_000),
            gasFees: UserOperation.packGasFees(
                maxPriorityFeePerGas: maxPriorityFeePerGas,
                maxFeePerGas: maxFeePerGas
            ),
            paymasterAndData: Data(),  // Always empty — no paymasters
            signature: Data(count: 64)  // Dummy signature for estimation
        )

        // 5. Estimate gas via bundler
        let gasEstimate = try await bundlerClient.estimateUserOperationGas(
            userOp: userOp.toDict(),
            entryPoint: entryPoint
        )

        // 6. Add safety margins to gas limits
        // P-256 verification via Daimo verifier is gas-heavy; use 50% margin for verification
        let verificationGas = max(gasEstimate.verificationGasLimit, 300_000) * 15 / 10
        let callGas = max(gasEstimate.callGasLimit, 50_000) * 12 / 10
        let preVerGas = max(gasEstimate.preVerificationGas, 21_000) * 12 / 10

        userOp.accountGasLimits = UserOperation.packGasLimits(
            verificationGasLimit: verificationGas,
            callGasLimit: callGas
        )
        userOp.preVerificationGas = uint256(preVerGas)

        // D8: No paymasters — paymasterAndData must always be empty
        assert(userOp.paymasterAndData.isEmpty, "paymasterAndData must always be empty — no paymasters allowed")

        return userOp
    }

    /// Compute the userOpHash for signing.
    func computeHash(userOp: UserOperation) -> Data {
        UserOpHash.compute(
            sender: userOp.sender,
            nonce: userOp.nonce,
            initCode: userOp.initCode,
            callData: userOp.callData,
            accountGasLimits: userOp.accountGasLimits,
            preVerificationGas: userOp.preVerificationGas,
            gasFees: userOp.gasFees,
            paymasterAndData: userOp.paymasterAndData,
            entryPoint: entryPoint,
            chainId: chainId
        )
    }

    // MARK: - Private

    /// Get the nonce from the EntryPoint via eth_call to getNonce(address,uint192).
    private func getNonce(sender: String) async throws -> Data {
        // getNonce(address,uint192) selector = 0x35567e1a
        let senderPadded = String(repeating: "0", count: 24) + sender.dropFirst(2)
        let keyPadded = String(repeating: "0", count: 64) // key = 0
        let calldata = "0x35567e1a" + senderPadded + keyPadded

        let result = try await chainClient.ethCall(to: entryPoint, data: calldata)
        guard let nonceData = SignatureUtils.fromHex(result) else {
            return Data(count: 32)
        }
        // Pad to 32 bytes if needed
        if nonceData.count < 32 {
            return Data(count: 32 - nonceData.count) + nonceData
        }
        return nonceData.prefix(32)
    }

    /// Encode ClawVaultWallet.execute(address,uint256,bytes) calldata.
    private func encodeExecuteCall(target: String, value: UInt64, data: Data) -> Data {
        // execute(address,uint256,bytes) selector = 0xb61d27f6
        var encoded = Data()

        // Selector
        encoded.append(contentsOf: [0xb6, 0x1d, 0x27, 0xf6])

        // address target (padded to 32 bytes)
        encoded.append(Data(count: 12))
        if let targetBytes = SignatureUtils.fromHex(target) {
            encoded.append(targetBytes)
        } else {
            encoded.append(Data(count: 20))
        }

        // uint256 value
        encoded.append(uint256(value))

        // bytes offset (dynamic type — offset to data location)
        encoded.append(uint256(UInt64(96))) // 3 * 32

        // bytes length
        encoded.append(uint256(UInt64(data.count)))

        // bytes data (padded to 32-byte boundary)
        encoded.append(data)
        let padding = (32 - (data.count % 32)) % 32
        if padding > 0 {
            encoded.append(Data(count: padding))
        }

        return encoded
    }

    /// Encode a UInt64 as a 32-byte big-endian uint256.
    private func uint256(_ value: UInt64) -> Data {
        var result = Data(count: 24)
        withUnsafeBytes(of: value.bigEndian) { result.append(contentsOf: $0) }
        return result
    }
}
