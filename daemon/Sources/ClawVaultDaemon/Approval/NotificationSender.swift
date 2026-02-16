import Foundation
import UserNotifications

/// Sends macOS system notifications for approval requests (MVP).
/// Telegram/Signal delivery is deferred.
enum NotificationSender {
    /// Send an approval notification via macOS system notification.
    static func sendApprovalNotification(
        code: String,
        summary: String,
        approvalHashPrefix: String,
        expiresIn: TimeInterval = 180
    ) async {
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
        do {
            try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[NotificationSender] Notification permission denied: \(error)")
        }
    }
}
