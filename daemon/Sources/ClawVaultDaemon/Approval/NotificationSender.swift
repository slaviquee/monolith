import Foundation
import UserNotifications

/// Sends macOS system notifications for approval requests (MVP).
/// Telegram/Signal delivery is deferred.
enum NotificationSender {
    /// Whether notifications are available (requires a proper app bundle).
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Send an approval notification via macOS system notification.
    static func sendApprovalNotification(
        code: String,
        summary: String,
        approvalHashPrefix: String,
        expiresIn: TimeInterval = 180
    ) async {
        guard isAvailable else {
            // No app bundle — fall back to osascript dialog so the code is still delivered
            print("[NotificationSender] No app bundle — showing approval code via osascript")
            let safeMsg = "\(summary)\nCode: \(code)\nHash: \(approvalHashPrefix)\nExpires in \(Int(expiresIn))s"
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
                display dialog "\(safeMsg)" \
                    with title "ClawVault Approval Required" \
                    buttons {"OK"} \
                    default button "OK" \
                    with icon caution
                """
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "ClawVault Approval Required"
        content.body = "\(summary)\nCode: \(code)\nHash: \(approvalHashPrefix)\nExpires in \(Int(expiresIn))s"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "clawvault-approval-\(code)",
            content: content,
            trigger: nil  // deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Log but don't fail — notification delivery is best-effort
            print("[NotificationSender] Failed to deliver notification: \(error)")
        }
    }

    /// Request notification permission.
    static func requestPermission() async {
        guard isAvailable else { return }
        do {
            try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[NotificationSender] Notification permission denied: \(error)")
        }
    }
}
