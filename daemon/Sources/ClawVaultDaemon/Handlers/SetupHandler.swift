import Foundation

/// POST /setup — Initialize wallet configuration (chain, profile, counterfactual address).
/// POST /setup/deploy — Deploy the wallet on-chain (requires funding).
struct SetupHandler {
    let seManager: SecureEnclaveManager
    let chainClient: ChainClient
    let bundlerClient: BundlerClient
    let userOpBuilder: UserOpBuilder
    let auditLogger: AuditLogger
    let configStore: ConfigStore

    func handleSetup(request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let chainIdValue = json["chainId"] as? UInt64,
            let profile = json["profile"] as? String
        else {
            return .error(400, "Missing required fields: chainId, profile")
        }

        // Validate chainId
        guard chainIdValue == 1 || chainIdValue == 8453 else {
            return .error(400, "Invalid chainId: must be 1 (Ethereum) or 8453 (Base)")
        }

        // Validate profile
        guard SecurityProfile.forName(profile) != nil else {
            return .error(400, "Invalid profile: must be 'balanced' or 'autonomous'")
        }

        // Validate recoveryAddress if provided — must be non-zero
        let recoveryAddress = json["recoveryAddress"] as? String
        if let recovery = recoveryAddress {
            let cleaned = recovery.replacingOccurrences(of: "0x", with: "").lowercased()
            guard cleaned.count == 40,
                cleaned != String(repeating: "0", count: 40)
            else {
                return .error(400, "recoveryAddress must be a valid non-zero Ethereum address")
            }
        }

        let config = configStore.read()

        // Validate factory address is configured
        guard !config.factoryAddress.isEmpty,
            config.factoryAddress != DaemonConfig.defaultFactory
        else {
            return .error(503, "Factory address not configured. Deploy the ClawVaultFactory first.")
        }

        // Get the signing public key for counterfactual address computation
        let pubKey: (x: Data, y: Data)
        do {
            pubKey = try await seManager.signingPublicKey()
        } catch {
            return .error(503, "Secure Enclave not available: \(error.localizedDescription)")
        }

        // Run precompile probe
        let precompileAvailable = await PrecompileProbe.probe(chainClient: chainClient)

        // Compute counterfactual wallet address
        let signerXHex = SignatureUtils.toHex(pubKey.x)
        let signerYHex = SignatureUtils.toHex(pubKey.y)

        // Call factory.getAddress() via eth_call to get the counterfactual address
        let walletAddress: String
        do {
            walletAddress = try await computeCounterfactualAddress(
                factoryAddress: config.factoryAddress,
                signerXHex: signerXHex,
                signerYHex: signerYHex,
                chainId: chainIdValue
            )
        } catch {
            return .error(500, "Failed to compute wallet address: \(error.localizedDescription)")
        }

        // Update config via ConfigStore (shared reference)
        do {
            try configStore.update { cfg in
                cfg.homeChainId = chainIdValue
                cfg.activeProfile = profile
                cfg.walletAddress = walletAddress
                cfg.precompileAvailable = precompileAvailable
                if let recovery = recoveryAddress {
                    cfg.recoveryAddress = recovery
                }
            }
        } catch {
            return .error(500, "Failed to persist config: \(error.localizedDescription)")
        }

        await auditLogger.log(
            action: "setup",
            decision: "approved",
            reason: "Chain: \(chainIdValue), Profile: \(profile), Wallet: \(walletAddress)"
        )

        return .json(200, [
            "walletAddress": walletAddress,
            "chainId": chainIdValue,
            "profile": profile,
            "precompileAvailable": precompileAvailable,
            "funded": false,
        ] as [String: Any])
    }

    func handleDeploy(request: HTTPRequest) async -> HTTPResponse {
        let config = configStore.read()

        guard let walletAddress = config.walletAddress else {
            return .error(400, "Run /setup first to configure the wallet")
        }

        // Validate recoveryAddress is set and non-zero
        let recoveryAddr = config.recoveryAddress ?? ""
        let recoveryCleanCheck = recoveryAddr.replacingOccurrences(of: "0x", with: "").lowercased()
        guard !recoveryCleanCheck.isEmpty,
            recoveryCleanCheck != String(repeating: "0", count: 40)
        else {
            return .error(400, "recoveryAddress not configured. Pass it via POST /setup first.")
        }

        // Check wallet is funded
        let balance: UInt64
        do {
            balance = try await chainClient.getBalance(address: walletAddress)
        } catch {
            return .error(500, "Failed to check balance: \(error.localizedDescription)")
        }

        // Minimum balance: enough for deployment gas (~0.005 ETH)
        let minBalance: UInt64 = 5_000_000_000_000_000 // 0.005 ETH
        guard balance >= minBalance else {
            let balanceEth = String(format: "%.6f", Double(balance) / 1e18)
            return .error(402, "Insufficient balance for deployment. Current: \(balanceEth) ETH, need at least 0.005 ETH. Send ETH to \(walletAddress)")
        }

        // Get signer public key for initCode
        let deployPubKey: (x: Data, y: Data)
        do {
            deployPubKey = try await seManager.signingPublicKey()
        } catch {
            return .error(503, "Secure Enclave not available: \(error.localizedDescription)")
        }

        // Build initCode: factory address (20 bytes) + createAccount calldata
        let signerXHex = SignatureUtils.toHex(deployPubKey.x)
        let signerYHex = SignatureUtils.toHex(deployPubKey.y)
        let initCode = buildInitCode(
            factoryAddress: config.factoryAddress,
            signerXHex: signerXHex,
            signerYHex: signerYHex,
            recoveryAddress: recoveryAddr,
            dailyCap: SecurityProfile.forName(config.activeProfile)?.dailyEthCap ?? 250_000_000_000_000_000,
            usePrecompile: config.precompileAvailable ?? false
        )

        // Build and submit deployment UserOp
        do {
            var userOp = try await userOpBuilder.build(
                sender: walletAddress,
                target: walletAddress,
                value: 0,
                calldata: Data(),
                initCode: initCode
            )

            // Sign the UserOp
            let hash = await userOpBuilder.computeHash(userOp: userOp)
            let rawSignature = try await seManager.sign(hash)
            userOp.signature = SignatureUtils.normalizeSignature(rawSignature)

            // Submit to bundler
            let txHash = try await bundlerClient.sendUserOperation(
                userOp: userOp.toDict(),
                entryPoint: config.entryPointAddress
            )

            await auditLogger.log(
                action: "deploy",
                target: walletAddress,
                decision: "approved",
                txHash: txHash
            )

            return .json(200, [
                "status": "deployed",
                "walletAddress": walletAddress,
                "userOpHash": txHash,
                "chainId": config.homeChainId,
            ] as [String: Any])
        } catch {
            await auditLogger.log(
                action: "deploy",
                target: walletAddress,
                decision: "error",
                reason: error.localizedDescription
            )
            return .error(500, "Deployment failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func computeCounterfactualAddress(
        factoryAddress: String,
        signerXHex: String,
        signerYHex: String,
        chainId: UInt64
    ) async throws -> String {
        let config = configStore.read()
        // Call factory.getAddress(signerX, signerY, recoveryAddress, dailyCap, stablecoins, usePrecompile, salt)
        let profile = SecurityProfile.forName(config.activeProfile) ?? .balanced

        // Encode getAddress call
        // selector for getAddress(uint256,uint256,address,uint256,address[],bool,bytes32)
        let selector = "0x20047a51"

        let signerXClean = signerXHex.hasPrefix("0x") ? String(signerXHex.dropFirst(2)) : signerXHex
        let signerYClean = signerYHex.hasPrefix("0x") ? String(signerYHex.dropFirst(2)) : signerYHex
        let recoveryClean = (config.recoveryAddress ?? "0000000000000000000000000000000000000000")
            .replacingOccurrences(of: "0x", with: "")

        var calldata = selector
        // signerX (uint256)
        calldata += String(repeating: "0", count: 64 - signerXClean.count) + signerXClean
        // signerY (uint256)
        calldata += String(repeating: "0", count: 64 - signerYClean.count) + signerYClean
        // recoveryAddress (address, padded to 32 bytes)
        calldata += String(repeating: "0", count: 24) + recoveryClean
        // dailyCap (uint256)
        let capHex = String(profile.dailyEthCap, radix: 16)
        calldata += String(repeating: "0", count: 64 - capHex.count) + capHex
        // stablecoins array offset (dynamic type)
        calldata += String(repeating: "0", count: 62) + "e0" // offset to stablecoins array
        // usePrecompile (bool)
        let usePrecompile = config.precompileAvailable ?? false
        calldata += String(repeating: "0", count: 63) + (usePrecompile ? "1" : "0")
        // salt (bytes32 = 0)
        calldata += String(repeating: "0", count: 64)
        // stablecoins array: length = 0
        calldata += String(repeating: "0", count: 64)

        let result = try await chainClient.ethCall(to: factoryAddress, data: calldata)

        // Result is a 32-byte address (padded)
        guard let resultData = SignatureUtils.fromHex(result), resultData.count >= 32 else {
            throw ChainClient.ChainError.rpcError("Invalid factory response")
        }

        // Extract address from last 20 bytes of 32-byte word
        let addressBytes = resultData[12..<32]
        return "0x" + addressBytes.map { String(format: "%02x", $0) }.joined()
    }

    private func buildInitCode(
        factoryAddress: String,
        signerXHex: String,
        signerYHex: String,
        recoveryAddress: String,
        dailyCap: UInt64,
        usePrecompile: Bool
    ) -> Data {
        // initCode = factoryAddress (20 bytes) + createAccount calldata
        let factoryClean = factoryAddress.replacingOccurrences(of: "0x", with: "")
        var initCode = SignatureUtils.fromHex("0x" + factoryClean) ?? Data()

        // createAccount selector — same params as constructor
        let selector = SignatureUtils.fromHex("0x03347661") ?? Data()
        initCode.append(selector)

        // Encode params (simplified — actual encoding matches factory ABI)
        let signerXClean = signerXHex.hasPrefix("0x") ? String(signerXHex.dropFirst(2)) : signerXHex
        let signerYClean = signerYHex.hasPrefix("0x") ? String(signerYHex.dropFirst(2)) : signerYHex
        let recoveryClean = recoveryAddress.replacingOccurrences(of: "0x", with: "")

        // signerX
        let xPad = String(repeating: "0", count: 64 - signerXClean.count) + signerXClean
        initCode.append(SignatureUtils.fromHex("0x" + xPad) ?? Data())
        // signerY
        let yPad = String(repeating: "0", count: 64 - signerYClean.count) + signerYClean
        initCode.append(SignatureUtils.fromHex("0x" + yPad) ?? Data())
        // recoveryAddress
        let rPad = String(repeating: "0", count: 24) + recoveryClean
        initCode.append(SignatureUtils.fromHex("0x" + rPad) ?? Data())
        // dailyCap
        let capHex = String(dailyCap, radix: 16)
        let cPad = String(repeating: "0", count: 64 - capHex.count) + capHex
        initCode.append(SignatureUtils.fromHex("0x" + cPad) ?? Data())
        // stablecoins array offset
        let arrayOffset = String(repeating: "0", count: 62) + "e0"
        initCode.append(SignatureUtils.fromHex("0x" + arrayOffset) ?? Data())
        // usePrecompile
        let boolPad = String(repeating: "0", count: 63) + (usePrecompile ? "1" : "0")
        initCode.append(SignatureUtils.fromHex("0x" + boolPad) ?? Data())
        // salt = 0
        initCode.append(SignatureUtils.fromHex("0x" + String(repeating: "0", count: 64)) ?? Data())
        // stablecoins array length = 0
        initCode.append(SignatureUtils.fromHex("0x" + String(repeating: "0", count: 64)) ?? Data())

        return initCode
    }
}
