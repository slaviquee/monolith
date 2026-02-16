import Foundation

/// Manages 8-digit approval codes for transactions requiring human approval.
actor ApprovalManager {
    struct PendingApproval {
        let code: String
        let approvalHash: Data
        let summary: String
        let createdAt: Date
        let expiresAt: Date
        var failedAttempts: Int
    }

    private var pending: [String: PendingApproval] = [:] // keyed by code
    private var globalFailedAttempts: [(Date, Int)] = []
    private let expirySeconds: TimeInterval = 180 // 3 minutes
    private let maxFailedPerApproval = 3
    private let maxGlobalFailedPerMinute = 5

    /// Create a new pending approval.
    /// Returns the 8-digit code and the approval hash.
    func createApproval(
        chainId: UInt64,
        walletAddress: String,
        target: String,
        value: UInt64,
        calldata: Data,
        summary: String
    ) -> (code: String, approvalHash: Data) {
        // Purge expired
        purgeExpired()

        // Generate 8-digit code (cryptographically random)
        let code = generateCode()

        // Compute ApprovalHash = keccak256(chainId, walletAddress, target, value, calldata, 0, expiry)
        let expiry = Date().addingTimeInterval(expirySeconds)
        let approvalHash = computeApprovalHash(
            chainId: chainId,
            walletAddress: walletAddress,
            target: target,
            value: value,
            calldata: calldata,
            expiry: expiry
        )

        let approval = PendingApproval(
            code: code,
            approvalHash: approvalHash,
            summary: summary,
            createdAt: Date(),
            expiresAt: expiry,
            failedAttempts: 0
        )

        pending[code] = approval

        return (code: code, approvalHash: approvalHash)
    }

    /// Verify an approval code.
    func verify(code: String) -> ApprovalResult {
        // Global rate limit check
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let recentGlobalFailures = globalFailedAttempts.filter { $0.0 >= oneMinuteAgo }.count
        if recentGlobalFailures >= maxGlobalFailedPerMinute {
            return .rateLimited("Too many failed attempts — try again in 1 minute")
        }

        // Purge expired
        purgeExpired()

        guard let approval = pending[code] else {
            recordGlobalFailure()
            return .invalid("Invalid or expired code")
        }

        if approval.failedAttempts >= maxFailedPerApproval {
            pending.removeValue(forKey: code)
            return .revoked("Approval revoked after too many failed attempts")
        }

        if now >= approval.expiresAt {
            pending.removeValue(forKey: code)
            return .expired
        }

        // Code matches — consume it (single-use)
        pending.removeValue(forKey: code)
        return .approved(approval.approvalHash, approval.summary)
    }

    /// Record a failed verification for a specific code.
    func recordFailure(code: String) {
        if var approval = pending[code] {
            approval.failedAttempts += 1
            if approval.failedAttempts >= maxFailedPerApproval {
                pending.removeValue(forKey: code)
            } else {
                pending[code] = approval
            }
        }
        recordGlobalFailure()
    }

    /// Get pending approval count.
    var pendingCount: Int {
        purgeExpired()
        return pending.count
    }

    // MARK: - Private

    private func generateCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        let code = value % 100_000_000
        return String(format: "%08d", code)
    }

    private func computeApprovalHash(
        chainId: UInt64,
        walletAddress: String,
        target: String,
        value: UInt64,
        calldata: Data,
        expiry: Date
    ) -> Data {
        var packed = Data()
        packed.append(UserOpHash.padUint256(chainId))
        packed.append(UserOpHash.padAddress(walletAddress))
        packed.append(UserOpHash.padAddress(target))
        packed.append(UserOpHash.padUint256(UInt64(value)))
        packed.append(UserOpHash.keccak256(calldata))
        packed.append(UserOpHash.padUint256(0)) // maxSpendCap placeholder
        packed.append(UserOpHash.padUint256(UInt64(expiry.timeIntervalSince1970)))
        return UserOpHash.keccak256(packed)
    }

    private func purgeExpired() {
        let now = Date()
        pending = pending.filter { $0.value.expiresAt > now }
    }

    private func recordGlobalFailure() {
        let now = Date()
        globalFailedAttempts.append((now, 1))
        // Keep only last minute
        let oneMinuteAgo = now.addingTimeInterval(-60)
        globalFailedAttempts.removeAll { $0.0 < oneMinuteAgo }
    }
}

enum ApprovalResult {
    case approved(Data, String) // approvalHash, summary
    case invalid(String)
    case expired
    case revoked(String)
    case rateLimited(String)
}
