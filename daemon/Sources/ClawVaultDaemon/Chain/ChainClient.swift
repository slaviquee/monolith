import Foundation

/// JSON-RPC client for chain nodes (eth_getBalance, eth_call, etc.).
actor ChainClient {
    private let rpcURL: URL
    private let session: URLSession

    init(rpcURL: String) {
        self.rpcURL = URL(string: rpcURL)!
        self.session = URLSession(configuration: .default)
    }

    /// Get the ETH balance of an address.
    func getBalance(address: String) async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_getBalance", params: [address, "latest"])
        guard let hexStr = result as? String else { throw ChainError.unexpectedResponse }
        return parseHexUInt64(hexStr)
    }

    /// Get the transaction count (nonce) for an address.
    func getTransactionCount(address: String) async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_getTransactionCount", params: [address, "latest"])
        guard let hexStr = result as? String else { throw ChainError.unexpectedResponse }
        return parseHexUInt64(hexStr)
    }

    /// Perform eth_call.
    func ethCall(to: String, data: String, value: String? = nil) async throws -> String {
        var params: [String: Any] = ["to": to, "data": data]
        if let value = value {
            params["value"] = value
        }
        let result = try await rpcCall(method: "eth_call", params: [params, "latest"])
        guard let hexStr = result as? String else { throw ChainError.unexpectedResponse }
        return hexStr
    }

    /// Get current gas price in wei.
    func getGasPrice() async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_gasPrice", params: [Any]())
        guard let hexStr = result as? String else { throw ChainError.unexpectedResponse }
        return parseHexUInt64(hexStr)
    }

    /// Get current chain ID.
    func chainId() async throws -> UInt64 {
        let result = try await rpcCall(method: "eth_chainId", params: [Any]())
        guard let hexStr = result as? String else { throw ChainError.unexpectedResponse }
        return parseHexUInt64(hexStr)
    }

    // MARK: - Uniswap QuoterV2

    /// QuoterV2 addresses per chain.
    static let quoterV2Addresses: [UInt64: String] = [
        1: "0x61fFE014bA17989E743c5F6cB21bF9697530B21e",
        8453: "0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a",
    ]

    /// Query Uniswap V3 QuoterV2.quoteExactInputSingle for expected output.
    /// Selector: 0xc6a5026a for quoteExactInputSingle((address,address,uint256,uint24,uint160))
    func quoteExactInputSingle(
        chainId: UInt64,
        tokenIn: String,
        tokenOut: String,
        amountIn: UInt64,
        fee: UInt32
    ) async throws -> UInt64 {
        guard let quoter = Self.quoterV2Addresses[chainId] else {
            throw ChainError.rpcError("No QuoterV2 address for chain \(chainId)")
        }

        // Encode: selector + struct fields
        // quoteExactInputSingle((address,address,uint256,uint24,uint160))
        // selector = 0xc6a5026a
        var calldata = "0xc6a5026a"

        // tokenIn (padded to 32 bytes)
        let tokenInClean = tokenIn.hasPrefix("0x") ? String(tokenIn.dropFirst(2)) : tokenIn
        calldata += String(repeating: "0", count: 24) + tokenInClean.lowercased()

        // tokenOut (padded to 32 bytes)
        let tokenOutClean = tokenOut.hasPrefix("0x") ? String(tokenOut.dropFirst(2)) : tokenOut
        calldata += String(repeating: "0", count: 24) + tokenOutClean.lowercased()

        // amountIn (uint256) — pad hex to exactly 64 chars
        let amountInHex = String(amountIn, radix: 16)
        calldata += String(repeating: "0", count: 64 - amountInHex.count) + amountInHex

        // fee (uint24 padded to 32 bytes) — pad hex to exactly 64 chars
        let feeHex = String(fee, radix: 16)
        calldata += String(repeating: "0", count: 64 - feeHex.count) + feeHex

        // sqrtPriceLimitX96 = 0 (no limit)
        calldata += String(repeating: "0", count: 64)

        let result = try await ethCall(to: quoter, data: calldata)

        // First 32 bytes of return data = amountOut
        guard let resultData = SignatureUtils.fromHex(result), resultData.count >= 32 else {
            throw ChainError.rpcError("Invalid QuoterV2 response")
        }

        // Read amountOut from first 32 bytes (big-endian uint256 → UInt64)
        // Overflow detection: if high bytes (0-24) are non-zero, return UInt64.max
        // so spending limit checks always trigger (safe default)
        let highBytes = resultData[0..<24]
        if highBytes.contains(where: { $0 != 0 }) {
            return UInt64.max
        }
        var amountOut: UInt64 = 0
        for i in 24..<32 {
            amountOut = (amountOut << 8) | UInt64(resultData[i])
        }
        return amountOut
    }

    // MARK: - Private

    private func rpcCall(method: String, params: [Any]) async throws -> Any {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw ChainError.httpError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChainError.invalidJSON
        }

        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown RPC error"
            throw ChainError.rpcError(message)
        }

        guard let result = json["result"] else {
            throw ChainError.noResult
        }

        return result
    }

    private func parseHexUInt64(_ hex: String) -> UInt64 {
        let cleaned = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return UInt64(cleaned, radix: 16) ?? 0
    }

    enum ChainError: Error {
        case httpError
        case invalidJSON
        case rpcError(String)
        case noResult
        case unexpectedResponse
    }
}
