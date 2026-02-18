import Foundation

/// Actor wrapping the companion app's XPC callback proxy.
/// Provides async wrappers for daemon → companion calls with 30s timeout.
/// Throws `CompanionError.unreachable` if no companion is connected (fail closed).
actor CompanionProxy {
    private var connection: NSXPCConnection?

    private static let timeoutSeconds: TimeInterval = 30

    /// Store the companion's XPC connection (called when companion connects via XPC).
    nonisolated func setConnection(_ connection: NSXPCConnection) {
        Task { await _setConnection(connection) }
    }

    /// Clear the stored connection (called on connection interruption/invalidation).
    nonisolated func clearProxy() {
        Task { await _clearConnection() }
    }

    /// Whether a companion is currently connected.
    var isConnected: Bool {
        connection != nil
    }

    // MARK: - Async wrappers

    /// Request admin approval via the companion (Touch ID + confirmation dialog).
    /// - Parameter summary: Human-readable description of the action.
    /// - Returns: `true` if user approved, `false` if denied.
    /// - Throws: `CompanionError.unreachable` if companion is not connected,
    ///           `CompanionError.timeout` if no response within 30s,
    ///           `CompanionError.xpcError` if the XPC connection fails.
    func requestAdminApproval(summary: String) async throws -> Bool {
        return try await withXPCTimeout { proxy, completion in
            proxy.requestAdminApproval(summary: summary) { approved in
                completion(.success(approved))
            }
        }
    }

    /// Post an approval notification to the companion.
    /// Returns `true` if the companion accepted and stored the approval in its UI.
    /// - Throws: `CompanionError.unreachable` if companion is not connected,
    ///           `CompanionError.timeout` if no response within 30s,
    ///           `CompanionError.xpcError` if the XPC connection fails.
    func postApprovalNotification(
        code: String,
        summary: String,
        hashPrefix: String,
        expiresIn: Int
    ) async throws -> Bool {
        return try await withXPCTimeout { proxy, completion in
            proxy.postApprovalNotification(
                code: code,
                summary: summary,
                hashPrefix: hashPrefix,
                expiresIn: expiresIn
            ) { stored in
                completion(.success(stored))
            }
        }
    }

    // MARK: - Private

    private func _setConnection(_ connection: NSXPCConnection) {
        self.connection = connection
    }

    private func _clearConnection() {
        self.connection = nil
    }

    /// Race an XPC call against a 30-second timeout.
    /// Uses `remoteObjectProxyWithErrorHandler` so XPC failures (companion crash,
    /// connection death) are caught and forwarded as `CompanionError.xpcError`.
    private func withXPCTimeout<T>(
        operation: @escaping (CompanionCallbackProtocol, @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard let connection = connection else {
            throw CompanionError.unreachable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(with result: Result<T, Error>) {
                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(with: result)
                }
            }

            // Obtain proxy with error handler for XPC failures
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resumeOnce(with: .failure(CompanionError.xpcError(error)))
            } as! CompanionCallbackProtocol

            // Start timeout watchdog
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                resumeOnce(with: .failure(CompanionError.timeout))
            }

            // Execute the XPC call
            operation(proxy) { result in
                timeoutTask.cancel()
                resumeOnce(with: result)
            }
        }
    }
}

// MARK: - CompanionError

enum CompanionError: Error, CustomStringConvertible {
    case unreachable
    case timeout
    case xpcError(Error)

    var description: String {
        switch self {
        case .unreachable:
            return "Companion app required for approvals — please start ClawVault.app"
        case .timeout:
            return "Companion app did not respond within 30 seconds"
        case .xpcError(let error):
            return "XPC communication error: \(error.localizedDescription)"
        }
    }
}
