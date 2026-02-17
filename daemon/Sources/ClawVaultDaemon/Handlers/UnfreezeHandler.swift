import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// POST /unfreeze — Unfreeze the wallet locally after on-chain unfreeze is confirmed.
/// Requires: config.frozen == true, on-chain wallet.frozen() == false, macOS dialog, Touch ID.
struct UnfreezeHandler {
    let services: ServiceContainer
    let seManager: SecureEnclaveManager
    let auditLogger: AuditLogger
    let configStore: ConfigStore

    func handle(request: HTTPRequest) async -> HTTPResponse {
        let config = configStore.read()

        // 1. Must be frozen locally
        guard config.frozen else {
            return .error(400, "Wallet is not frozen")
        }

        guard let walletAddress = config.walletAddress else {
            return .error(503, "Wallet not deployed yet")
        }

        // 2. Verify on-chain frozen() == false via eth_call
        // frozen() selector = 0x054f7d9c
        let frozenOnChain: Bool
        do {
            let result = try await services.chainClient.ethCall(to: walletAddress, data: "0x054f7d9c")
            // Result is a bool (32 bytes), last byte is 0 (false) or 1 (true)
            if let resultData = SignatureUtils.fromHex(result), resultData.count >= 32 {
                frozenOnChain = resultData[31] != 0
            } else {
                frozenOnChain = true // Assume frozen if we can't read
            }
        } catch {
            return .error(500, "Failed to check on-chain freeze status: \(error.localizedDescription)")
        }

        if frozenOnChain {
            return .json(409, [
                "status": "still_frozen_on_chain",
                "message": "Wallet is still frozen on-chain. The recovery address must call requestUnfreeze() and then finalizeUnfreeze() after the 10-minute delay.",
                "recoveryAddress": config.recoveryAddress ?? "unknown",
            ])
        }

        // 3. Show native macOS confirmation dialog
        #if canImport(AppKit)
            let confirmed = await MainActor.run { () -> Bool in
                let alert = NSAlert()
                alert.messageText = "ClawVault Unfreeze"
                alert.informativeText = "The wallet has been unfrozen on-chain. Confirm to unfreeze the daemon locally and resume signing."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Unfreeze")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn
            }

            if !confirmed {
                await auditLogger.log(
                    action: "unfreeze",
                    decision: "denied",
                    reason: "User denied confirmation dialog"
                )
                return .error(403, "Unfreeze denied by user")
            }
        #endif

        // 4. Require Touch ID via adminSign()
        let challengeData = "unfreeze:\(Date().timeIntervalSince1970)".data(using: .utf8) ?? Data()
        do {
            _ = try await seManager.adminSign(challengeData)
        } catch {
            await auditLogger.log(
                action: "unfreeze",
                decision: "denied",
                reason: "Touch ID verification failed: \(error.localizedDescription)"
            )
            return .error(403, "Touch ID verification failed")
        }

        // 5. Unfreeze locally
        await services.policyEngine.unfreeze()
        do {
            try configStore.update { $0.frozen = false }
        } catch {
            await auditLogger.log(
                action: "unfreeze",
                decision: "warning",
                reason: "Failed to persist unfrozen state: \(error.localizedDescription)"
            )
        }

        await auditLogger.log(
            action: "unfreeze",
            decision: "approved",
            reason: "Wallet unfrozen locally after on-chain confirmation + Touch ID"
        )

        return .json(200, [
            "status": "unfrozen",
            "message": "Wallet is unfrozen. Signing is now enabled.",
        ])
    }
}
