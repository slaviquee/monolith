import Foundation

/// POST /setup — Initialize wallet configuration (chain, profile, counterfactual address).
/// POST /setup/deploy — Deploy the wallet on-chain (requires funding).
struct SetupHandler {
    let seManager: SecureEnclaveManager
    let services: ServiceContainer
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
        let precompileAvailable = await PrecompileProbe.probe(chainClient: services.chainClient)

        // Resolve profile BEFORE computing address (avoid stale config)
        let resolvedProfile = SecurityProfile.forName(profile)!  // already validated above

        // Compute counterfactual wallet address with explicit resolved values
        let signerXHex = SignatureUtils.toHex(pubKey.x)
        let signerYHex = SignatureUtils.toHex(pubKey.y)

        // Call factory.getAddress() via eth_call to get the counterfactual address
        let walletAddress: String
        do {
            walletAddress = try await computeCounterfactualAddress(
                factoryAddress: config.factoryAddress,
                signerXHex: signerXHex,
                signerYHex: signerYHex,
                chainId: chainIdValue,
                profile: resolvedProfile,
                recoveryAddress: recoveryAddress,
                precompileAvailable: precompileAvailable
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

        // Reconfigure all chain-dependent services with updated config
        services.reconfigure(config: configStore.read())

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
            balance = try await services.chainClient.getBalance(address: walletAddress)
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
        let deployProfile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        // Normalize dailyStablecoinCap from 6-decimal to 18-decimal
        let stableCapNormalized = UInt64(deployProfile.dailyStablecoinCap) * 1_000_000_000_000
        let initCode = buildInitCode(
            factoryAddress: config.factoryAddress,
            signerXHex: signerXHex,
            signerYHex: signerYHex,
            recoveryAddress: recoveryAddr,
            dailyCap: deployProfile.dailyEthCap,
            dailyStablecoinCap: stableCapNormalized,
            usePrecompile: config.precompileAvailable ?? false
        )

        // Build and submit deployment UserOp
        do {
            var userOp = try await services.userOpBuilder.build(
                sender: walletAddress,
                target: walletAddress,
                value: 0,
                calldata: Data(),
                initCode: initCode
            )

            // Sign the UserOp
            let hash = await services.userOpBuilder.computeHash(userOp: userOp)
            let rawSignature = try await seManager.sign(hash)
            userOp.signature = SignatureUtils.normalizeSignature(rawSignature)

            // Submit to bundler
            let txHash = try await services.bundlerClient.sendUserOperation(
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
        chainId: UInt64,
        profile: SecurityProfile,
        recoveryAddress: String?,
        precompileAvailable: Bool
    ) async throws -> String {
        // Call factory.getAddress(signerX, signerY, recoveryAddress, dailyCap, dailyStablecoinCap,
        //   stablecoins, stablecoinDecs, usePrecompile, salt)
        // All values are passed explicitly — no reading from configStore.

        // Encode getAddress call
        // selector for getAddress(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)
        let selector = "0x" + Self.getAddressSelector

        let signerXClean = signerXHex.hasPrefix("0x") ? String(signerXHex.dropFirst(2)) : signerXHex
        let signerYClean = signerYHex.hasPrefix("0x") ? String(signerYHex.dropFirst(2)) : signerYHex
        let recoveryClean = (recoveryAddress ?? "0000000000000000000000000000000000000000")
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
        // dailyStablecoinCap (uint256) — profile.dailyStablecoinCap normalized to 18 decimals
        let stableCapWei = UInt64(profile.dailyStablecoinCap) * 1_000_000_000_000 // 6-dec → 18-dec
        let stableCapHex = String(stableCapWei, radix: 16)
        calldata += String(repeating: "0", count: 64 - stableCapHex.count) + stableCapHex
        // stablecoins array offset (dynamic type) = 9 * 32 = 288 = 0x120
        calldata += String(repeating: "0", count: 61) + "120"
        // stablecoinDecs array offset = 288 + 32 (stablecoins length word) = 320 = 0x140
        calldata += String(repeating: "0", count: 61) + "140"
        // usePrecompile (bool)
        calldata += String(repeating: "0", count: 63) + (precompileAvailable ? "1" : "0")
        // salt (bytes32 = 0)
        calldata += String(repeating: "0", count: 64)
        // stablecoins array: length = 0
        calldata += String(repeating: "0", count: 64)
        // stablecoinDecs array: length = 0
        calldata += String(repeating: "0", count: 64)

        let result = try await services.chainClient.ethCall(to: factoryAddress, data: calldata)

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
        dailyStablecoinCap: UInt64,
        usePrecompile: Bool
    ) -> Data {
        // initCode = factoryAddress (20 bytes) + createAccount calldata
        let factoryClean = factoryAddress.replacingOccurrences(of: "0x", with: "")
        var initCode = SignatureUtils.fromHex("0x" + factoryClean) ?? Data()

        // createAccount selector
        let selector = SignatureUtils.fromHex("0x" + Self.createAccountSelector) ?? Data()
        initCode.append(selector)

        // Encode params matching factory ABI:
        // createAccount(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)
        let signerXClean = signerXHex.hasPrefix("0x") ? String(signerXHex.dropFirst(2)) : signerXHex
        let signerYClean = signerYHex.hasPrefix("0x") ? String(signerYHex.dropFirst(2)) : signerYHex
        let recoveryClean = recoveryAddress.replacingOccurrences(of: "0x", with: "")

        func pad64(_ hex: String) -> String {
            String(repeating: "0", count: 64 - hex.count) + hex
        }
        func appendHex(_ hex: String) {
            initCode.append(SignatureUtils.fromHex("0x" + hex) ?? Data())
        }

        // signerX
        appendHex(pad64(signerXClean))
        // signerY
        appendHex(pad64(signerYClean))
        // recoveryAddress
        appendHex(String(repeating: "0", count: 24) + recoveryClean)
        // dailyCap
        appendHex(pad64(String(dailyCap, radix: 16)))
        // dailyStablecoinCap (18-decimal normalized)
        appendHex(pad64(String(dailyStablecoinCap, radix: 16)))
        // stablecoins array offset = 9 * 32 = 288 = 0x120
        appendHex(pad64("120"))
        // stablecoinDecs array offset = 288 + 32 = 320 = 0x140
        appendHex(pad64("140"))
        // usePrecompile
        appendHex(String(repeating: "0", count: 63) + (usePrecompile ? "1" : "0"))
        // salt = 0
        appendHex(String(repeating: "0", count: 64))
        // stablecoins array: length = 0
        appendHex(String(repeating: "0", count: 64))
        // stablecoinDecs array: length = 0
        appendHex(String(repeating: "0", count: 64))

        return initCode
    }

    // MARK: - Factory Selectors

    /// getAddress(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)
    /// Computed from keccak256 of the function signature — must match compiled factory.
    static let getAddressSelector: String = {
        let sig = "getAddress(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)"
        let hash = UserOpHash.keccak256(sig.data(using: .utf8)!)
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }()

    /// createAccount(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)
    static let createAccountSelector: String = {
        let sig = "createAccount(uint256,uint256,address,uint256,uint256,address[],uint8[],bool,bytes32)"
        let hash = UserOpHash.keccak256(sig.data(using: .utf8)!)
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }()
}
