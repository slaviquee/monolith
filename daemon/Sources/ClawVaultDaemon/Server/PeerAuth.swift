import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Peer UID verification for Unix domain socket connections.
enum PeerAuth {
    enum AuthError: Error {
        case uidMismatch(expected: uid_t, got: uid_t)
        case credentialFetchFailed(Int32)
    }

    /// Verify that the peer's UID matches our own UID.
    static func verifyPeer(socket fd: Int32) throws {
        let myUID = getuid()

        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)

        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len)
        guard result == 0 else {
            throw AuthError.credentialFetchFailed(errno)
        }

        guard cred.cr_uid == myUID else {
            throw AuthError.uidMismatch(expected: myUID, got: cred.cr_uid)
        }
    }
}
