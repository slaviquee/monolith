import Foundation

/// Pimlico bundler JSON-RPC client with exponential backoff on 429s.
actor BundlerClient {
    private let bundlerURL: URL
    private let session: URLSession
    private let maxRetries = 5
    private let baseDelay: TimeInterval = 1.0

    init(bundlerURL: String) {
        self.bundlerURL = URL(string: bundlerURL)!
        self.session = URLSession(configuration: .default)
    }

    /// Send a signed UserOperation to the bundler.
    func sendUserOperation(userOp: [String: Any], entryPoint: String) async throws -> String {
        let result = try await rpcCallWithRetry(
            method: "eth_sendUserOperation",
            params: [userOp, entryPoint]
        )
        guard let hash = result as? String else {
            throw BundlerError.unexpectedResponse
        }
        return hash
    }

    /// Estimate gas for a UserOperation.
    func estimateUserOperationGas(
        userOp: [String: Any], entryPoint: String
    ) async throws -> GasEstimate {
        let result = try await rpcCallWithRetry(
            method: "eth_estimateUserOperationGas",
            params: [userOp, entryPoint]
        )
        guard let dict = result as? [String: Any] else {
            throw BundlerError.unexpectedResponse
        }

        return GasEstimate(
            preVerificationGas: parseHex(dict["preVerificationGas"] as? String ?? "0x0"),
            verificationGasLimit: parseHex(dict["verificationGasLimit"] as? String ?? "0x0"),
            callGasLimit: parseHex(dict["callGasLimit"] as? String ?? "0x0")
        )
    }

    /// Check supported entry points.
    func supportedEntryPoints() async throws -> [String] {
        let result = try await rpcCallWithRetry(
            method: "eth_supportedEntryPoints",
            params: [Any]()
        )
        guard let entryPoints = result as? [String] else {
            throw BundlerError.unexpectedResponse
        }
        return entryPoints
    }

    // MARK: - Private

    private func rpcCallWithRetry(method: String, params: [Any]) async throws -> Any {
        var lastError: Error = BundlerError.maxRetriesExceeded

        for attempt in 0..<maxRetries {
            do {
                return try await rpcCall(method: method, params: params)
            } catch BundlerError.rateLimited {
                let delay = baseDelay * pow(2.0, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = BundlerError.rateLimited
            } catch {
                throw error
            }
        }

        throw lastError
    }

    private func rpcCall(method: String, params: [Any]) async throws -> Any {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]

        var request = URLRequest(url: bundlerURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BundlerError.httpError(0)
        }

        if httpResponse.statusCode == 429 {
            throw BundlerError.rateLimited
        }

        guard httpResponse.statusCode == 200 else {
            throw BundlerError.httpError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BundlerError.invalidJSON
        }

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown bundler error"
            let code = error["code"] as? Int ?? 0
            throw BundlerError.rpcError(code: code, message: message)
        }

        guard let result = json["result"] else {
            throw BundlerError.noResult
        }

        return result
    }

    private func parseHex(_ hex: String) -> UInt64 {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(cleaned, radix: 16) ?? 0
    }

    struct GasEstimate {
        let preVerificationGas: UInt64
        let verificationGasLimit: UInt64
        let callGasLimit: UInt64
    }

    enum BundlerError: Error {
        case httpError(Int)
        case rateLimited
        case invalidJSON
        case rpcError(code: Int, message: String)
        case noResult
        case unexpectedResponse
        case maxRetriesExceeded
    }
}
