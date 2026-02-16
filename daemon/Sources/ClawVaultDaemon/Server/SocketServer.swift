import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// Unix domain socket server for the daemon API.
/// Handles socket creation, directory hygiene, peer auth, and connection dispatch.
actor SocketServer {
    private let socketPath: String
    private let router: RequestRouter
    private var serverFD: Int32 = -1
    private var isRunning = false

    init(socketPath: String, router: RequestRouter) {
        self.socketPath = socketPath
        self.router = router
    }

    /// Start listening on the Unix socket.
    func start() throws {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // Create directory with 0700 permissions
        if !fm.fileExists(atPath: dirPath) {
            try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dirPath)

        // Check for stale socket via lstat (reject symlinks)
        if fm.fileExists(atPath: socketPath) {
            var statBuf = stat()
            guard lstat(socketPath, &statBuf) == 0 else {
                throw SocketError.statFailed
            }
            // Verify it's a socket, not a symlink
            if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                throw SocketError.symlinkDetected
            }
            // Remove stale socket
            try fm.removeItem(atPath: socketPath)
        }

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw SocketError.createFailed(errno)
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
                let pathPtr = sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { $0 }
                strncpy(pathPtr, ptr, 103)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                bind(serverFD, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw SocketError.bindFailed(errno)
        }

        // Set socket permissions to 0600
        chmod(socketPath, 0o600)

        // Listen
        guard listen(serverFD, 5) == 0 else {
            close(serverFD)
            throw SocketError.listenFailed(errno)
        }

        isRunning = true
    }

    /// Accept and handle connections in a loop.
    func acceptLoop() async {
        while isRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                if isRunning { continue }
                break
            }

            // Spawn a task to handle this connection
            let router = self.router
            Task.detached {
                await Self.handleConnection(fd: clientFD, router: router)
            }
        }
    }

    /// Stop the server.
    func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Private

    private static func handleConnection(fd: Int32, router: RequestRouter) async {
        defer { close(fd) }

        // D4: Read and parse the request BEFORE peer auth so /health can bypass auth
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = recv(fd, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])
        guard let request = HTTPRequest.parse(data) else {
            let response = HTTPResponse.error(400, "Invalid request")
            sendResponse(fd: fd, response: response)
            return
        }

        // D4: Allow /health through without peer auth
        let isHealthCheck = request.method == "GET" && request.path == "/health"

        if !isHealthCheck {
            // Verify peer UID for all non-health endpoints
            do {
                try PeerAuth.verifyPeer(socket: fd)
            } catch {
                let response = HTTPResponse.error(403, "Peer authentication failed")
                sendResponse(fd: fd, response: response)
                return
            }
        }

        // Route and respond
        let response = await router.route(request)
        sendResponse(fd: fd, response: response)
    }

    private static func sendResponse(fd: Int32, response: HTTPResponse) {
        let data = response.serialize()
        data.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, data.count, 0)
        }
    }

    enum SocketError: Error {
        case createFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case statFailed
        case symlinkDetected
    }
}
