import Foundation

/// GET /audit-log — Recent decisions and tx hashes (redacted).
struct AuditLogHandler {
    let auditLogger: AuditLogger

    func handle(request: HTTPRequest) async -> HTTPResponse {
        let entries = await auditLogger.recentEntries(count: 50)

        let serializable = entries.map { entry -> [String: Any?] in
            [
                "timestamp": entry.timestamp,
                "action": entry.action,
                "target": entry.target,
                "value": entry.value,
                "decision": entry.decision,
                "reason": entry.reason,
                "txHash": entry.txHash,
            ]
        }

        return .json(200, ["entries": serializable])
    }
}
