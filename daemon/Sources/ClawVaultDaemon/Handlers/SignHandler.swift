import Foundation

/// Simple in-memory rate limiter for /sign requests.
private final class SignRateLimiter: @unchecked Sendable {
    private var timestamps: [Date] = []
    private let lock = NSLock()
    private let maxRequestsPerMinute = 30

    /// Returns true if the request is allowed, false if rate-limited.
    func checkAndRecord() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        timestamps.removeAll { $0 < oneMinuteAgo }

        if timestamps.count >= maxRequestsPerMinute {
            return false
        }
        timestamps.append(now)
        return true
    }
}

/// POST /sign — Sign an intent (policy-checked, gas-preflighted).
struct SignHandler {
    let services: ServiceContainer
    let seManager: SecureEnclaveManager
    let approvalManager: ApprovalManager
    let auditLogger: AuditLogger
    let configStore: ConfigStore

    /// D12: Rate limiter — 30 requests per minute
    private static let rateLimiter = SignRateLimiter()

    func handle(request: HTTPRequest) async -> HTTPResponse {
        // D12: Rate limit check
        guard SignHandler.rateLimiter.checkAndRecord() else {
            return .error(429, "Rate limited: max 30 sign requests per minute")
        }

        let config = configStore.read()

        // Parse intent
        guard let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let target = json["target"] as? String,
            let calldataHex = json["calldata"] as? String,
            let valueStr = json["value"] as? String
        else {
            return .error(400, "Missing required fields: target, calldata, value")
        }

        let calldata = SignatureUtils.fromHex(calldataHex) ?? Data()
        // Overflow detection: reject if value string exceeds UInt64 range
        guard let value = UInt64(valueStr) else {
            return .error(400, "Value overflows UInt64 (~18.4 ETH max, MVP limitation): \(valueStr)")
        }

        // D14: Warn on forbidden intent fields
        let forbiddenFields = ["nonce", "signature", "paymasterAndData", "gasLimit", "maxFeePerGas"]
        let presentForbidden = forbiddenFields.filter { json[$0] != nil }
        if !presentForbidden.isEmpty {
            await auditLogger.log(
                action: "sign",
                target: target,
                decision: "warning",
                reason: "Forbidden fields present in intent (ignored): \(presentForbidden.joined(separator: ", "))"
            )
        }

        // Parse optional chainHint (§4.1) — daemon MAY override based on policy
        let chainHint = (json["chainHint"] as? String).flatMap { UInt64($0) }

        // Daemon MUST ignore any extra fields (nonce, gas, fees, signatures)
        let chainId = config.homeChainId

        // Log if chainHint differs from homeChainId
        if let hint = chainHint, hint != chainId {
            await auditLogger.log(
                action: "sign",
                target: target,
                decision: "info",
                reason: "chainHint \(hint) differs from homeChain \(chainId); using homeChain"
            )
        }
        guard let walletAddress = config.walletAddress else {
            return .error(503, "Wallet not deployed yet")
        }

        // Check if frozen
        if config.frozen {
            return .error(409, "Wallet is frozen")
        }

        // Policy evaluation
        let decision = await services.policyEngine.evaluate(
            target: target,
            calldata: calldata,
            value: value,
            chainId: chainId
        )

        switch decision {
        case .deny(let reason):
            await auditLogger.log(
                action: "sign",
                target: target,
                value: valueStr,
                decision: "denied",
                reason: reason
            )
            return .error(403, reason)

        case .requireApproval(let reason):
            // D2: Check if the request includes an approval code from a previous approval
            if let approvalCode = json["approvalCode"] as? String {
                // Compute the intent hash for the CURRENT request to bind approval to intent
                let expectedHash = await approvalManager.computeApprovalHash(
                    chainId: chainId,
                    walletAddress: walletAddress,
                    target: target,
                    value: value,
                    calldata: calldata
                )
                let verifyResult = await approvalManager.verify(code: approvalCode, expectedHash: expectedHash)
                switch verifyResult {
                case .approved:
                    // Approval code is valid — proceed with signing (fall through to .allow)
                    await auditLogger.log(
                        action: "sign",
                        target: target,
                        value: valueStr,
                        decision: "approved_via_code",
                        reason: reason
                    )
                    break
                case .invalid(let msg):
                    await approvalManager.recordFailure(code: approvalCode)
                    return .error(403, "Invalid approval code: \(msg)")
                case .expired:
                    await approvalManager.recordFailure(code: approvalCode)
                    return .error(403, "Approval code expired")
                case .revoked(let msg):
                    await approvalManager.recordFailure(code: approvalCode)
                    return .error(403, "Approval code revoked: \(msg)")
                case .rateLimited(let msg):
                    return .error(429, msg)
                }
            } else {
                // No approval code — create a new approval request
                let decoded = CalldataDecoder.decode(
                    calldata: calldata,
                    target: target,
                    value: value,
                    chainId: chainId,
                    stablecoinRegistry: services.stablecoinRegistry,
                    protocolRegistry: services.protocolRegistry
                )

                let (code, approvalHash) = await approvalManager.createApproval(
                    chainId: chainId,
                    walletAddress: walletAddress,
                    target: target,
                    value: value,
                    calldata: calldata,
                    summary: decoded.summary
                )

                let hashPrefix = SignatureUtils.toHex(approvalHash).prefix(18)

                // Send notification
                await NotificationSender.sendApprovalNotification(
                    code: code,
                    summary: decoded.summary,
                    approvalHashPrefix: String(hashPrefix)
                )

                await auditLogger.log(
                    action: "sign",
                    target: target,
                    value: valueStr,
                    decision: "approval_required",
                    reason: reason
                )

                return .json(202, [
                    "status": "approval_required",
                    "reason": reason,
                    "summary": decoded.summary,
                    "approvalHashPrefix": String(hashPrefix),
                    "expiresIn": 180,
                ])
            }

        case .allow:
            break
        }

        // Build, sign, and submit UserOp
        do {
            var userOp = try await services.userOpBuilder.build(
                sender: walletAddress,
                target: target,
                value: value,
                calldata: calldata
            )

            // Gas preflight — extract actual estimates from the built UserOp
            let actualGas = UserOperation.unpackGasLimits(userOp.accountGasLimits)
            let actualFees = UserOperation.unpackGasFees(userOp.gasFees)
            let actualPreVerGas = UserOperation.unpackUint256AsUInt64(userOp.preVerificationGas)
            let gasEstimate = BundlerClient.GasEstimate(
                preVerificationGas: actualPreVerGas,
                verificationGasLimit: actualGas.verificationGasLimit,
                callGasLimit: actualGas.callGasLimit
            )
            let preflight = try await GasPreflight.check(
                walletAddress: walletAddress,
                gasEstimate: gasEstimate,
                maxFeePerGas: actualFees.maxFeePerGas,
                chainClient: services.chainClient
            )

            if !preflight.sufficient {
                return .error(402, preflight.message ?? "Insufficient gas")
            }

            // Compute userOpHash and sign
            let hash = await services.userOpBuilder.computeHash(userOp: userOp)
            let rawSignature = try await seManager.sign(hash)
            userOp.signature = SignatureUtils.normalizeSignature(rawSignature)

            // Submit to bundler
            let txHash = try await services.bundlerClient.sendUserOperation(
                userOp: userOp.toDict(),
                entryPoint: config.entryPointAddress
            )

            // Record spending — decode stablecoin amount from calldata
            var stablecoinAmount: UInt64 = 0
            if calldata.count >= 68 {
                let selectorHex = calldata.prefix(4).map { String(format: "%02x", $0) }.joined()
                if selectorHex == "a9059cbb" {
                    if services.stablecoinRegistry.isStablecoin(chainId: chainId, address: target) {
                        stablecoinAmount = CalldataDecoder.dataToUInt64(Data(calldata[36..<68]))
                    }
                }
            }
            await services.policyEngine.recordTransaction(ethAmount: value, stablecoinAmount: stablecoinAmount)

            await auditLogger.log(
                action: "sign",
                target: target,
                value: valueStr,
                decision: "approved",
                txHash: txHash
            )

            return .json(200, [
                "status": "submitted",
                "userOpHash": txHash,
                "chainId": chainId,
            ])
        } catch {
            await auditLogger.log(
                action: "sign",
                target: target,
                value: valueStr,
                decision: "error",
                reason: error.localizedDescription
            )
            return .error(500, "Transaction failed: \(error.localizedDescription)")
        }
    }
}
