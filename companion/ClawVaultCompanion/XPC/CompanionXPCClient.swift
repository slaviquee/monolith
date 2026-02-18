import Foundation
import LocalAuthentication
import UserNotifications

/// Manages the XPC connection to the daemon Mach service.
/// Exports CompanionCallbackProtocol so the daemon can call back for admin approval and notifications.
class CompanionXPCClient: NSObject, ObservableObject, @unchecked Sendable {
    private var connection: NSXPCConnection?
    private var daemonProxy: DaemonXPCProtocol?
    private let lock = NSLock()

    @Published var isConnected = false
    @Published var pendingApprovals: [PendingApproval] = []

    /// Active admin approval request (set by daemon callback, shown in SwiftUI sheet).
    @Published var activeApprovalRequest: AdminApprovalRequest?

    /// Connect to the daemon Mach service.
    func connect() {
        lock.lock()
        defer { lock.unlock() }

        let conn = NSXPCConnection(machServiceName: "com.clawvault.daemon")

        // Export our callback interface (daemon → companion)
        conn.exportedInterface = NSXPCInterface(with: CompanionCallbackProtocol.self)
        conn.exportedObject = self

        // Set up daemon's interface (companion → daemon)
        let daemonInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
        let allowedClasses = NSSet(array: [NSArray.self, PendingApprovalInfo.self]) as! Set<AnyHashable>
        daemonInterface.setClasses(
            allowedClasses,
            for: #selector(DaemonXPCProtocol.listPendingApprovals(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        conn.remoteObjectInterface = daemonInterface

        conn.interruptionHandler = { [weak self] in
            print("[Companion] XPC connection interrupted — will retry")
            DispatchQueue.main.async { self?.isConnected = false }
            // Retry connection after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connect()
            }
        }
        conn.invalidationHandler = { [weak self] in
            print("[Companion] XPC connection invalidated")
            DispatchQueue.main.async { self?.isConnected = false }
        }

        conn.resume()
        connection = conn

        // Get the daemon proxy
        if let proxy = conn.remoteObjectProxy as? DaemonXPCProtocol {
            daemonProxy = proxy
            // Ping to verify connection
            proxy.ping { [weak self] success in
                DispatchQueue.main.async {
                    self?.isConnected = success
                    if success {
                        print("[Companion] Connected to daemon")
                        self?.refreshPendingApprovals()
                    }
                }
            }
        }
    }

    /// Disconnect from the daemon.
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        connection?.invalidate()
        connection = nil
        daemonProxy = nil
    }

    /// Refresh the pending approvals list from the daemon.
    func refreshPendingApprovals() {
        daemonProxy?.listPendingApprovals { [weak self] infos in
            let approvals = infos.map { info in
                PendingApproval(
                    code: info.code,
                    summary: info.summary,
                    hashPrefix: info.hashPrefix,
                    expiresAt: info.expiresAt
                )
            }
            DispatchQueue.main.async {
                self?.pendingApprovals = approvals
            }
        }
    }
}

// MARK: - CompanionCallbackProtocol

extension CompanionXPCClient: CompanionCallbackProtocol {
    func requestAdminApproval(summary: String, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let context = LAContext()
            var authError: NSError?

            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
                print(
                    "[Companion] Touch ID unavailable for admin approval: \(authError?.localizedDescription ?? "unknown error")"
                )
                reply(false)
                return
            }

            let reason = "Approve ClawVault admin action: \(summary)"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if !success, let error {
                    print("[Companion] Admin approval denied/failed: \(error.localizedDescription)")
                }
                reply(success)
            }
        }
    }

    func postApprovalNotification(
        code: String,
        summary: String,
        hashPrefix: String,
        expiresIn: Int,
        reply: @escaping (Bool) -> Void
    ) {
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))

        // Store in local display list (always visible in menu bar regardless of notification settings)
        DispatchQueue.main.async { [weak self] in
            let approval = PendingApproval(
                code: code,
                summary: summary,
                hashPrefix: hashPrefix,
                expiresAt: expiresAt
            )
            self?.pendingApprovals.append(approval)
        }

        // Best-effort macOS notification
        let content = UNMutableNotificationContent()
        content.title = "ClawVault Approval Required"
        content.body = "\(summary)\nCode: \(code)\nHash: \(hashPrefix)\nExpires in \(expiresIn)s"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "clawvault-approval-\(code)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Companion] Notification delivery failed (best-effort): \(error)")
            }
            // Return true regardless — the approval is stored in the UI
            reply(true)
        }
    }
}
