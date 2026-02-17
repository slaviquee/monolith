import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// GET /policy — Return current policy configuration.
/// POST /policy/update — Modify policy (requires Touch ID).
struct PolicyHandler {
    let configStore: ConfigStore
    let services: ServiceContainer
    let seManager: SecureEnclaveManager
    let auditLogger: AuditLogger

    func handleGet(request: HTTPRequest) async -> HTTPResponse {
        let config = configStore.read()
        let baseProfile = SecurityProfile.forName(config.activeProfile) ?? .balanced
        let profile = baseProfile.withOverrides(
            perTxStablecoinCap: config.customPerTxStablecoinCap,
            dailyStablecoinCap: config.customDailyStablecoinCap,
            perTxEthCap: config.customPerTxEthCap,
            dailyEthCap: config.customDailyEthCap,
            maxTxPerHour: config.customMaxTxPerHour,
            maxSlippageBps: config.customMaxSlippageBps
        )

        return .json(200, [
            "profile": profile.name,
            "perTxStablecoinCap": profile.perTxStablecoinCap,
            "dailyStablecoinCap": profile.dailyStablecoinCap,
            "perTxEthCap": profile.perTxEthCap,
            "dailyEthCap": profile.dailyEthCap,
            "maxTxPerHour": profile.maxTxPerHour,
            "minCooldownSeconds": profile.minCooldownSeconds,
            "maxSlippageBps": profile.maxSlippageBps,
        ] as [String: Any])
    }

    func handleUpdate(request: HTTPRequest) async -> HTTPResponse {
        // 1. Parse the JSON body for policy changes
        guard let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return .error(400, "Missing or invalid JSON body")
        }

        // Extract the requested profile change (if any)
        let newProfile = json["profile"] as? String

        // Build a human-readable summary of the requested changes
        var changeSummary = "Policy update request:"
        if let profile = newProfile {
            changeSummary += "\n  - Switch profile to: \(profile)"
        }
        for (key, value) in json where key != "profile" {
            changeSummary += "\n  - \(key): \(value)"
        }

        // 2. Show native macOS confirmation dialog summarizing the change
        // NOTE: NSAlert and the confirmation dialog require a real macOS GUI environment.
        // On headless/CI builds this will be skipped. In production the dialog MUST appear.
        #if canImport(AppKit)
            let dialogSummary = changeSummary
            let confirmed = await MainActor.run { () -> Bool in
                let alert = NSAlert()
                alert.messageText = "ClawVault Policy Update"
                alert.informativeText = dialogSummary
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Approve")
                alert.addButton(withTitle: "Deny")
                return alert.runModal() == .alertFirstButtonReturn
            }

            if !confirmed {
                await auditLogger.log(
                    action: "policy_update",
                    decision: "denied",
                    reason: "User denied confirmation dialog"
                )
                return .error(403, "Policy update denied by user")
            }
        #endif

        // 3. Require Touch ID via adminSign()
        // The admin key has .userPresence which triggers Touch ID biometric prompt.
        let challengeData = (changeSummary + ":\(Date().timeIntervalSince1970)").data(using: .utf8) ?? Data()
        do {
            _ = try await seManager.adminSign(challengeData)
        } catch {
            await auditLogger.log(
                action: "policy_update",
                decision: "denied",
                reason: "Touch ID verification failed: \(error.localizedDescription)"
            )
            return .error(403, "Touch ID verification failed")
        }

        // 4. Apply policy changes — persist all supported fields via ConfigStore
        if let profileName = newProfile {
            guard SecurityProfile.forName(profileName) != nil else {
                return .error(400, "Unknown profile: \(profileName). Must be 'balanced' or 'autonomous'.")
            }
        }

        do {
            try configStore.update { updatedConfig in
                if let profileName = newProfile {
                    updatedConfig.activeProfile = profileName
                }
                if let v = json["perTxStablecoinCap"] as? UInt64 {
                    updatedConfig.customPerTxStablecoinCap = v
                }
                if let v = json["dailyStablecoinCap"] as? UInt64 {
                    updatedConfig.customDailyStablecoinCap = v
                }
                if let v = json["perTxEthCap"] as? UInt64 {
                    updatedConfig.customPerTxEthCap = v
                }
                if let v = json["dailyEthCap"] as? UInt64 {
                    updatedConfig.customDailyEthCap = v
                }
                if let v = json["maxTxPerHour"] as? Int {
                    updatedConfig.customMaxTxPerHour = v
                }
                if let v = json["maxSlippageBps"] as? Int {
                    updatedConfig.customMaxSlippageBps = v
                }
            }
        } catch {
            return .error(500, "Failed to persist config: \(error.localizedDescription)")
        }

        // Rebuild all chain-dependent services (PolicyEngine, ProtocolRegistry, etc.)
        let updatedConfig = configStore.read()
        services.reconfigure(config: updatedConfig)

        await auditLogger.log(
            action: "policy_update",
            decision: "approved",
            reason: changeSummary
        )

        return .json(200, [
            "status": "updated",
            "summary": changeSummary,
        ])
    }
}
