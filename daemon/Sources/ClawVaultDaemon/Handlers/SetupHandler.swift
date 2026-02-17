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

        // Accept optional factoryAddress in the setup request
        if let factory = json["factoryAddress"] as? String, !factory.isEmpty {
            do {
                try configStore.update { cfg in
                    cfg.factoryAddress = factory
                }
            } catch {
                return .error(500, "Failed to persist factory address: \(error.localizedDescription)")
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

        // Run precompile probe against the target chain (not the currently configured one)
        guard let targetChainConfig = ChainConfig.forChain(chainIdValue) else {
            return .error(400, "Unsupported chain: \(chainIdValue)")
        }
        let probeClient = ChainClient(rpcURL: targetChainConfig.rpcURL)
        let precompileAvailable = await PrecompileProbe.probe(chainClient: probeClient)

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
        let initCode = buildInitCode(
            factoryAddress: config.factoryAddress,
            signerXHex: signerXHex,
            signerYHex: signerYHex,
            recoveryAddress: recoveryAddr,
            dailyCap: deployProfile.dailyEthCap,
            dailyStablecoinCap: deployProfile.dailyStablecoinCap,
            chainId: config.homeChainId,
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
        calldata += stableCapToUint256Hex(profile.dailyStablecoinCap)

        // Filter stablecoins for the target chain (sorted for deterministic encoding)
        let stables = StablecoinRegistry.defaultEntries
            .filter { $0.chainId == chainId }
            .sorted(by: { $0.address < $1.address })
        let stableCount = stables.count

        // stablecoins array offset (dynamic type) = 9 * 32 = 288 = 0x120
        calldata += String(repeating: "0", count: 61) + "120"
        // stablecoinDecs array offset = 0x120 + 32 (length word) + stableCount * 32
        let decsOffset = 0x120 + 32 + stableCount * 32
        let decsOffsetHex = String(decsOffset, radix: 16)
        calldata += String(repeating: "0", count: 64 - decsOffsetHex.count) + decsOffsetHex
        // usePrecompile (bool)
        calldata += String(repeating: "0", count: 63) + (precompileAvailable ? "1" : "0")
        // salt (bytes32 = 0)
        calldata += String(repeating: "0", count: 64)
        // stablecoins array: length
        let countHex = String(stableCount, radix: 16)
        calldata += String(repeating: "0", count: 64 - countHex.count) + countHex
        // stablecoins array: entries (address padded to 32 bytes)
        for entry in stables {
            let addrClean = entry.address.replacingOccurrences(of: "0x", with: "").lowercased()
            calldata += String(repeating: "0", count: 24) + addrClean
        }
        // stablecoinDecs array: length
        calldata += String(repeating: "0", count: 64 - countHex.count) + countHex
        // stablecoinDecs array: entries (uint8 padded to 32 bytes)
        for entry in stables {
            let decHex = String(entry.decimals, radix: 16)
            calldata += String(repeating: "0", count: 64 - decHex.count) + decHex
        }

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
        dailyStablecoinCap: UInt64, // raw 6-decimal value
        chainId: UInt64,
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

        // Filter stablecoins for the target chain (sorted for deterministic encoding)
        let stables = StablecoinRegistry.defaultEntries
            .filter { $0.chainId == chainId }
            .sorted(by: { $0.address < $1.address })
        let stableCount = stables.count

        // signerX
        appendHex(pad64(signerXClean))
        // signerY
        appendHex(pad64(signerYClean))
        // recoveryAddress
        appendHex(String(repeating: "0", count: 24) + recoveryClean)
        // dailyCap
        appendHex(pad64(String(dailyCap, radix: 16)))
        // dailyStablecoinCap (normalized to 18 decimals via wide multiply)
        appendHex(stableCapToUint256Hex(dailyStablecoinCap))
        // stablecoins array offset = 9 * 32 = 288 = 0x120
        appendHex(pad64("120"))
        // stablecoinDecs array offset = 0x120 + 32 (length word) + stableCount * 32
        let decsOffset = 0x120 + 32 + stableCount * 32
        appendHex(pad64(String(decsOffset, radix: 16)))
        // usePrecompile
        appendHex(String(repeating: "0", count: 63) + (usePrecompile ? "1" : "0"))
        // salt = 0
        appendHex(String(repeating: "0", count: 64))
        // stablecoins array: length
        let countHex = pad64(String(stableCount, radix: 16))
        appendHex(countHex)
        // stablecoins array: entries (address padded to 32 bytes)
        for entry in stables {
            let addrClean = entry.address.replacingOccurrences(of: "0x", with: "").lowercased()
            appendHex(String(repeating: "0", count: 24) + addrClean)
        }
        // stablecoinDecs array: length
        appendHex(countHex)
        // stablecoinDecs array: entries (uint8 padded to 32 bytes)
        for entry in stables {
            appendHex(pad64(String(entry.decimals, radix: 16)))
        }

        return initCode
    }

    /// Multiply a 6-decimal stablecoin cap by 10^12 to get 18-decimal,
    /// returning a zero-padded 64-char hex string for uint256 ABI encoding.
    /// Uses `multipliedFullWidth` to avoid UInt64 overflow.
    private func stableCapToUint256Hex(_ cap6Dec: UInt64) -> String {
        let scale: UInt64 = 1_000_000_000_000 // 10^12
        let (high, low) = cap6Dec.multipliedFullWidth(by: scale)
        if high == 0 {
            let hex = String(low, radix: 16)
            return String(repeating: "0", count: 64 - hex.count) + hex
        }
        // Combine: result = high * 2^64 + low. Encode as big-endian hex.
        let highHex = String(high, radix: 16)
        let lowHex = String(low, radix: 16)
        let lowPadded = String(repeating: "0", count: 16 - lowHex.count) + lowHex
        let combined = highHex + lowPadded
        return String(repeating: "0", count: 64 - combined.count) + combined
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
