import Foundation

/// XPC listener for the daemon, registered as a Mach service.
/// Accepts connections from the verified companion app and implements DaemonXPCProtocol.
final class DaemonXPCService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    static let machServiceName = "com.clawvault.daemon"
    #if !DEBUG
    static let companionBundleID = "com.clawvault.companion"
    static let companionTeamID: String = {
        let teamID = TeamConfig.teamID
        precondition(teamID != "REPLACE_ME", "Team ID not configured — see shared/TeamConfig.swift")
        return teamID
    }()
    #endif

    private let listener: NSXPCListener
    private let approvalManager: ApprovalManager
    let companionProxy: CompanionProxy

    init(approvalManager: ApprovalManager) {
        self.listener = NSXPCListener(machServiceName: Self.machServiceName)
        self.approvalManager = approvalManager
        self.companionProxy = CompanionProxy()
        super.init()
        self.listener.delegate = self
    }

    /// Start listening for XPC connections from the companion app.
    func start() {
        listener.resume()
        print("[XPC] Daemon Mach service listener started: \(Self.machServiceName)")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Validate the connecting process
        guard validateConnection(connection) else {
            print("[XPC] Rejected connection from unverified process (pid: \(connection.processIdentifier))")
            connection.invalidate()
            return false
        }

        // Set up the daemon's exported interface (companion → daemon calls)
        let daemonInterface = NSXPCInterface(with: DaemonXPCProtocol.self)
        // Allow PendingApprovalInfo in the reply of listPendingApprovals
        let allowedClasses = NSSet(array: [NSArray.self, PendingApprovalInfo.self]) as! Set<AnyHashable>
        daemonInterface.setClasses(
            allowedClasses,
            for: #selector(DaemonXPCProtocol.listPendingApprovals(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        connection.exportedInterface = daemonInterface
        connection.exportedObject = DaemonXPCHandler(approvalManager: approvalManager)

        // Set up the companion's callback interface (daemon → companion calls)
        connection.remoteObjectInterface = NSXPCInterface(with: CompanionCallbackProtocol.self)

        // Store the companion proxy for daemon → companion callbacks
        connection.interruptionHandler = { [weak self] in
            print("[XPC] Companion connection interrupted")
            self?.companionProxy.clearProxy()
        }
        connection.invalidationHandler = { [weak self] in
            print("[XPC] Companion connection invalidated")
            self?.companionProxy.clearProxy()
        }

        connection.resume()

        // Store the connection for callback use (CompanionProxy obtains proxy per-call
        // via remoteObjectProxyWithErrorHandler for proper error handling)
        companionProxy.setConnection(connection)
        print("[XPC] Companion connected (pid: \(connection.processIdentifier))")

        return true
    }

    // MARK: - Connection Validation

    private func validateConnection(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
        // Debug builds: accept ad-hoc signed binaries only if dev-mode flag exists
        let devModeFlag = DaemonConfig.configDir.appendingPathComponent("dev-mode").path
        if FileManager.default.fileExists(atPath: devModeFlag) {
            print("[XPC] DEBUG: Accepting connection in dev-mode (pid: \(connection.processIdentifier))")
            return true
        }
        print("[XPC] DEBUG: dev-mode flag not found at \(devModeFlag) — rejecting ad-hoc connection")
        return false
        #else
        // Release builds: verify code-signing identity via audit token
        return verifyCodeSigningIdentity(connection)
        #endif
    }

    #if !DEBUG
    private func verifyCodeSigningIdentity(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        // Get SecCode for the connecting process
        var code: SecCode?
        let pidAttr = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, pidAttr, [], &code) == errSecSuccess,
              let secCode = code
        else {
            print("[XPC] Failed to get SecCode for pid \(pid)")
            return false
        }

        // Validate against our requirements
        let requirement = "identifier \"\(Self.companionBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(Self.companionTeamID)\""
        var secRequirement: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess,
              let req = secRequirement
        else {
            print("[XPC] Failed to create security requirement")
            return false
        }

        let status = SecCodeCheckValidity(secCode, [], req)
        if status != errSecSuccess {
            print("[XPC] Code-signing validation failed for pid \(pid): \(status)")
            return false
        }

        return true
    }
    #endif
}

// MARK: - DaemonXPCHandler

/// Handles incoming XPC calls from the companion (implements DaemonXPCProtocol).
private final class DaemonXPCHandler: NSObject, DaemonXPCProtocol, @unchecked Sendable {
    private let approvalManager: ApprovalManager

    init(approvalManager: ApprovalManager) {
        self.approvalManager = approvalManager
    }

    func listPendingApprovals(reply: @escaping ([PendingApprovalInfo]) -> Void) {
        Task {
            let pending = await approvalManager.listPending()
            reply(pending)
        }
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}
