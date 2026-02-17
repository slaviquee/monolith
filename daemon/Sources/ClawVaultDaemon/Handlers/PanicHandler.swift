import Foundation

/// POST /panic — Emergency freeze (no Touch ID — speed over ceremony).
struct PanicHandler {
    let services: ServiceContainer
    let auditLogger: AuditLogger
    let seManager: SecureEnclaveManager?
    let configStore: ConfigStore

    func handle(request: HTTPRequest) async -> HTTPResponse {
        // Freeze locally immediately
        await services.policyEngine.freeze()

        // Persist frozen=true to DaemonConfig on disk via ConfigStore
        do {
            try configStore.update { $0.frozen = true }
        } catch {
            // Log but don't fail — local freeze is the priority
            await auditLogger.log(
                action: "panic",
                decision: "warning",
                reason: "Failed to persist frozen state: \(error.localizedDescription)"
            )
        }

        await auditLogger.log(
            action: "panic",
            decision: "frozen",
            reason: "Emergency freeze via /panic"
        )

        // Submit on-chain freeze() call via UserOp in a background task
        // Don't block the /panic response — local freeze is the priority
        let config = configStore.read()
        if let walletAddress = config.walletAddress,
           let seManager = seManager
        {
            let entryPoint = config.entryPointAddress
            let logger = auditLogger
            let svc = services
            Task.detached {
                do {
                    // freeze() selector = 0x62a5af3b
                    let freezeCalldata = Data([0x62, 0xa5, 0xaf, 0x3b])

                    var userOp = try await svc.userOpBuilder.build(
                        sender: walletAddress,
                        target: walletAddress,
                        value: 0,
                        calldata: freezeCalldata
                    )

                    let hash = await svc.userOpBuilder.computeHash(userOp: userOp)
                    let rawSignature = try await seManager.sign(hash)
                    userOp.signature = SignatureUtils.normalizeSignature(rawSignature)

                    let txHash = try await svc.bundlerClient.sendUserOperation(
                        userOp: userOp.toDict(),
                        entryPoint: entryPoint
                    )

                    await logger.log(
                        action: "panic",
                        decision: "on_chain_freeze_submitted",
                        txHash: txHash
                    )
                } catch {
                    // On-chain freeze failed — log but local freeze is still in effect
                    await logger.log(
                        action: "panic",
                        decision: "on_chain_freeze_failed",
                        reason: "On-chain freeze() submission failed: \(error.localizedDescription)"
                    )
                }
            }
        }

        return .json(200, [
            "status": "frozen",
            "message": "Wallet frozen immediately. Unfreeze requires Touch ID + 10min delay.",
        ])
    }
}
