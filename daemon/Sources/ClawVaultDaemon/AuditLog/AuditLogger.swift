import Foundation

/// Append-only audit log with redaction rules.
/// NEVER records: approval codes, SE key references, or forging material.
/// DOES record: timestamps, intent summaries, policy decisions, tx hashes.
actor AuditLogger {
    struct Entry: Codable {
        let timestamp: String
        let action: String
        let target: String?
        let value: String?
        let decision: String
        let reason: String?
        let txHash: String?
    }

    private let logPath: URL
    private var entries: [Entry] = []
    private let maxEntries = 1000

    init() {
        logPath = DaemonConfig.configDir.appendingPathComponent("audit.log")
    }

    /// D9: Sanitize strings by removing 8-digit sequences (potential approval codes).
    /// Approval codes are 8-digit numbers that MUST NEVER appear in audit logs.
    private func sanitize(_ input: String?) -> String? {
        guard let str = input else { return nil }
        // Replace any 8-digit numeric sequence with "[REDACTED]"
        let pattern = "\\b\\d{8}\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return str }
        let range = NSRange(str.startIndex..., in: str)
        return regex.stringByReplacingMatches(in: str, range: range, withTemplate: "[REDACTED]")
    }

    /// Log a policy decision.
    func log(
        action: String,
        target: String? = nil,
        value: String? = nil,
        decision: String,
        reason: String? = nil,
        txHash: String? = nil
    ) {
        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            action: sanitize(action) ?? action,
            target: sanitize(target.map { CalldataDecoder.shortenAddress($0) }),
            value: sanitize(value),
            decision: sanitize(decision) ?? decision,
            reason: sanitize(reason),
            txHash: sanitize(txHash)
        )

        entries.append(entry)

        // Trim old entries
        if entries.count > maxEntries {
            entries = Array(entries.suffix(maxEntries))
        }

        // Persist to disk
        persistEntry(entry)
    }

    /// Get recent log entries.
    func recentEntries(count: Int = 50) -> [Entry] {
        Array(entries.suffix(count))
    }

    private func persistEntry(_ entry: Entry) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(entry)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"

            if FileManager.default.fileExists(atPath: logPath.path) {
                let handle = try FileHandle(forWritingTo: logPath)
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try line.write(to: logPath, atomically: true, encoding: .utf8)
            }
        } catch {
            // Silent fail — audit logging should not crash the daemon
        }
    }
}
