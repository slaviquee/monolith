import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// POST /allowlist — Modify allowlist (requires Touch ID).
struct AllowlistHandler {
    let policyEngine: PolicyEngine
    let seManager: SecureEnclaveManager
    let auditLogger: AuditLogger

    func handle(request: HTTPRequest) async -> HTTPResponse {
        // 1. Parse the JSON body
        guard let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let action = json["action"] as? String,
            let address = json["address"] as? String
        else {
            return .error(400, "Missing required fields: action (add/remove), address")
        }

        guard action == "add" || action == "remove" else {
            return .error(400, "action must be 'add' or 'remove'")
        }

        // Build a human-readable summary
        let changeSummary = action == "add"
            ? "Add \(address) to allowlist"
            : "Remove \(address) from allowlist"

        // 2. Show native macOS confirmation dialog
        // NOTE: NSAlert requires a real macOS GUI environment.
        // On headless/CI builds this will be skipped. In production the dialog MUST appear.
        #if canImport(AppKit)
            let confirmed = await MainActor.run { () -> Bool in
                let alert = NSAlert()
                alert.messageText = "ClawVault Allowlist Update"
                alert.informativeText = changeSummary
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Approve")
                alert.addButton(withTitle: "Deny")
                return alert.runModal() == .alertFirstButtonReturn
            }

            if !confirmed {
                await auditLogger.log(
                    action: "allowlist_update",
                    target: address,
                    decision: "denied",
                    reason: "User denied confirmation dialog"
                )
                return .error(403, "Allowlist update denied by user")
            }
        #endif

        // 3. Require Touch ID via adminSign()
        let challengeData = (changeSummary + ":\(Date().timeIntervalSince1970)").data(using: .utf8) ?? Data()
        do {
            _ = try await seManager.adminSign(challengeData)
        } catch {
            await auditLogger.log(
                action: "allowlist_update",
                target: address,
                decision: "denied",
                reason: "Touch ID verification failed: \(error.localizedDescription)"
            )
            return .error(403, "Touch ID verification failed")
        }

        // 4. Apply changes to policy engine
        if action == "add" {
            await policyEngine.addToAllowlist(address)
        } else {
            await policyEngine.removeFromAllowlist(address)
        }

        await auditLogger.log(
            action: "allowlist_update",
            target: address,
            decision: "approved",
            reason: changeSummary
        )

        return .json(200, [
            "status": "updated",
            "action": action,
            "address": address,
        ])
    }
}
