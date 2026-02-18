import Foundation

/// Decodes known function selectors from calldata for policy evaluation and human-readable summaries.
struct CalldataDecoder {
    /// Known selectors and their human-readable names.
    static let knownSelectors: [String: String] = [
        "a9059cbb": "transfer(address,uint256)",
        "23b872dd": "transferFrom(address,address,uint256)",
        "095ea7b3": "approve(address,uint256)",
        "39509351": "increaseAllowance(address,uint256)",
        "a457c2d7": "decreaseAllowance(address,uint256)",
        "a22cb465": "setApprovalForAll(address,bool)",
        "3593564c": "execute(bytes,bytes[],uint256)",     // Uniswap Universal Router
        "e8eda9df": "deposit(address,uint256,address,uint16)", // Aave
        "69328dec": "withdraw(address,uint256,address)",   // Aave
        "a1903eab": "submit(address)",                     // Lido
        "d0e30db0": "deposit()",                           // WETH/Rocket Pool
    ]

    /// Decoded intent summary for display.
    struct DecodedIntent {
        let action: String       // e.g., "Transfer", "Swap", "Deposit"
        let summary: String      // Human-readable summary
        let selector: String     // 4-byte hex
        let isKnown: Bool
    }

    /// Decode calldata into a human-readable intent.
    static func decode(
        calldata: Data,
        target: String,
        value: UInt64,
        chainId: UInt64,
        stablecoinRegistry: StablecoinRegistry,
        protocolRegistry: ProtocolRegistry
    ) -> DecodedIntent {
        // Native ETH transfer (empty calldata)
        if calldata.isEmpty {
            let ethStr = formatWei(value)
            return DecodedIntent(
                action: "Transfer",
                summary: "Transfer \(ethStr) ETH to \(shortenAddress(target))",
                selector: "0x",
                isKnown: true
            )
        }

        guard calldata.count >= 4 else {
            return DecodedIntent(
                action: "Unknown",
                summary: "Unknown calldata (< 4 bytes) to \(shortenAddress(target))",
                selector: "0x",
                isKnown: false
            )
        }

        let selector = calldata.prefix(4).map { String(format: "%02x", $0) }.joined()
        let selectorName = knownSelectors[selector]

        // ERC-20 transfer
        if selector == "a9059cbb" && calldata.count >= 68 {
            let recipientBytes = calldata[16..<36] // skip 4 selector + 12 zero-padding
            let recipient = "0x" + recipientBytes.map { String(format: "%02x", $0) }.joined()
            let amountBytes = calldata[36..<68]
            let amount = dataToUInt64(Data(amountBytes))

            let isStable = stablecoinRegistry.isStablecoin(chainId: chainId, address: target)
            let tokenLabel = isStable ? "USDC" : "tokens"
            let amountStr = isStable ? formatUSDC(amount) : "\(amount)"

            return DecodedIntent(
                action: "Transfer",
                summary: "Transfer \(amountStr) \(tokenLabel) to \(shortenAddress(recipient))",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Uniswap execute
        if selector == "3593564c" {
            let protocolName = protocolRegistry.protocolName(chainId: chainId, address: target) ?? "DEX"
            let ethStr = value > 0 ? " (\(formatWei(value)) ETH)" : ""
            return DecodedIntent(
                action: "Swap",
                summary: "Swap via \(protocolName)\(ethStr) on \(shortenAddress(target))",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Aave deposit
        if selector == "e8eda9df" {
            let ethStr = value > 0 ? " \(formatWei(value)) ETH" : ""
            return DecodedIntent(
                action: "Deposit",
                summary: "Aave deposit\(ethStr) on \(shortenAddress(target))",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Aave withdraw
        if selector == "69328dec" {
            return DecodedIntent(
                action: "Withdraw",
                summary: "Aave withdraw from \(shortenAddress(target))",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Lido submit
        if selector == "a1903eab" && value > 0 {
            return DecodedIntent(
                action: "Stake",
                summary: "Stake \(formatWei(value)) ETH via Lido",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // WETH/Rocket Pool deposit
        if selector == "d0e30db0" && value > 0 {
            let protocolName = protocolRegistry.protocolName(chainId: chainId, address: target) ?? "Contract"
            return DecodedIntent(
                action: "Deposit",
                summary: "Deposit \(formatWei(value)) ETH to \(protocolName)",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Known selector but no specific decoder
        if let name = selectorName {
            return DecodedIntent(
                action: name.components(separatedBy: "(").first ?? "Call",
                summary: "\(name) on \(shortenAddress(target))",
                selector: "0x\(selector)",
                isKnown: true
            )
        }

        // Unknown
        return DecodedIntent(
            action: "Unknown",
            summary: "Unknown calldata: selector 0x\(selector) on \(shortenAddress(target))",
            selector: "0x\(selector)",
            isKnown: false
        )
    }

    // MARK: - Helpers

    static func shortenAddress(_ addr: String) -> String {
        guard addr.count >= 10 else { return addr }
        let start = addr.prefix(6)
        let end = addr.suffix(4)
        return "\(start)…\(end)"
    }

    static func formatWei(_ wei: UInt64) -> String {
        let eth = Double(wei) / 1e18
        if eth >= 0.01 {
            return String(format: "%.4f", eth)
        }
        return String(format: "%.8f", eth)
    }

    static func formatUSDC(_ amount: UInt64) -> String {
        let usdc = Double(amount) / 1e6
        return String(format: "%.2f", usdc)
    }

    static func dataToUInt64(_ data: Data) -> UInt64 {
        // Take the last 8 bytes (big-endian) for uint256 → UInt64 conversion.
        // Overflow detection: if any of the high bytes (0-24) are non-zero,
        // the value exceeds UInt64.max. Return UInt64.max as sentinel so
        // spending limit checks always trigger (safe default).
        let bytes = Array(data)
        if bytes.count > 8 {
            let highBytes = bytes[0..<(bytes.count - 8)]
            if highBytes.contains(where: { $0 != 0 }) {
                return UInt64.max
            }
        }
        var value: UInt64 = 0
        let start = max(0, bytes.count - 8)
        for i in start..<bytes.count {
            value = (value << 8) | UInt64(bytes[i])
        }
        return value
    }

    /// Decoded swap parameters from Uniswap Universal Router calldata.
    struct SwapParams {
        let amountIn: UInt64      // Input amount (wei)
        let amountOutMin: UInt64  // Minimum output amount
        let tokenIn: String       // Input token address (lowercase hex)
        let tokenOut: String      // Output token address (lowercase hex)
        let fee: UInt32           // Pool fee tier (e.g., 500, 3000)
        let isMultiHop: Bool      // true if path has more than 2 tokens
        let recipient: String     // Recipient address from V3_SWAP_EXACT_IN input
        let payerIsUser: Bool     // Whether the payer is the user (vs router)
        let commands: [UInt8]     // All command bytes in the execute() call
    }

    /// Uniswap Universal Router command bytes.
    private static let CMD_V3_SWAP_EXACT_IN: UInt8 = 0x00
    private static let CMD_V3_SWAP_EXACT_OUT: UInt8 = 0x01
    private static let CMD_WRAP_ETH: UInt8 = 0x0b

    /// Extract swap parameters from Uniswap Universal Router `execute(bytes,bytes[],uint256)` calldata.
    /// Returns nil if the calldata cannot be decoded (triggers safe default-deny).
    static func extractSwapParams(_ calldata: Data) -> SwapParams? {
        guard calldata.count >= 4 else { return nil }
        let selector = calldata.prefix(4).map { String(format: "%02x", $0) }.joined()
        guard selector == "3593564c" else { return nil }

        let params = Data(calldata.dropFirst(4))
        guard params.count >= 96 else { return nil }

        // Read ABI offsets (relative to start of params)
        let commandsOffset = readUInt256AsInt(params, offset: 0)
        let inputsOffset = readUInt256AsInt(params, offset: 32)

        // Read commands bytes
        guard commandsOffset + 32 <= params.count else { return nil }
        let commandsLen = readUInt256AsInt(params, offset: commandsOffset)
        guard commandsLen > 0, commandsOffset + 32 + commandsLen <= params.count else { return nil }
        let commands = Array(params[(commandsOffset + 32)..<(commandsOffset + 32 + commandsLen)])

        // Read inputs array count
        guard inputsOffset + 32 <= params.count else { return nil }
        let inputsCount = readUInt256AsInt(params, offset: inputsOffset)
        guard inputsCount == commands.count else { return nil }

        // Find the V3_SWAP_EXACT_IN command and decode its input
        for (i, cmd) in commands.enumerated() {
            guard cmd == CMD_V3_SWAP_EXACT_IN else { continue }

            // Read offset to this input's data (relative to inputsOffset)
            let offsetPos = inputsOffset + 32 + i * 32
            guard offsetPos + 32 <= params.count else { return nil }
            let inputRelOffset = readUInt256AsInt(params, offset: offsetPos)
            // Offsets within bytes[] are relative to the position after the length word
            let inputAbsOffset = inputsOffset + 32 + inputRelOffset

            // Read input length and data
            guard inputAbsOffset + 32 <= params.count else { return nil }
            let inputLen = readUInt256AsInt(params, offset: inputAbsOffset)
            let inputStart = inputAbsOffset + 32
            guard inputStart + inputLen <= params.count else { return nil }
            let inputData = Data(params[inputStart..<(inputStart + inputLen)])

            // Decode V3_SWAP_EXACT_IN: (address recipient, uint256 amountIn, uint256 amountOutMin, bytes path, bool payerIsUser)
            guard inputData.count >= 160 else { return nil } // 5 * 32 bytes minimum

            // Extract recipient address (first 32 bytes, address in lower 20 bytes)
            let recipientBytes = inputData[12..<32] // skip 12 zero-padding bytes
            let recipient = "0x" + recipientBytes.map { String(format: "%02x", $0) }.joined()

            let amountIn = readUInt256AsUInt64(inputData, offset: 32)
            let amountOutMin = readUInt256AsUInt64(inputData, offset: 64)
            let pathOffset = readUInt256AsInt(inputData, offset: 96)

            // Read path data
            guard pathOffset + 32 <= inputData.count else { return nil }
            let pathLen = readUInt256AsInt(inputData, offset: pathOffset)
            let pathStart = pathOffset + 32
            guard pathStart + pathLen <= inputData.count else { return nil }
            let pathData = Data(inputData[pathStart..<(pathStart + pathLen)])

            // V3 path: tokenIn (20) + fee (3) + tokenOut (20) = 43 bytes for single-hop
            guard pathData.count >= 43 else { return nil }
            let tokenIn = "0x" + pathData[0..<20].map { String(format: "%02x", $0) }.joined()
            let fee = UInt32(pathData[20]) << 16 | UInt32(pathData[21]) << 8 | UInt32(pathData[22])
            let tokenOut = "0x" + pathData[23..<43].map { String(format: "%02x", $0) }.joined()

            // Extract payerIsUser (offset 128 = 4th field, bool in last byte)
            let payerIsUser: Bool
            if inputData.count >= 160 {
                payerIsUser = inputData[159] != 0
            } else {
                payerIsUser = true // safe default
            }

            return SwapParams(
                amountIn: amountIn,
                amountOutMin: amountOutMin,
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                isMultiHop: pathData.count > 43,
                recipient: recipient,
                payerIsUser: payerIsUser,
                commands: commands
            )
        }

        return nil
    }

    /// Read a big-endian uint256 from Data and return as Int (for offsets/lengths).
    private static func readUInt256AsInt(_ data: Data, offset: Int) -> Int {
        guard offset + 32 <= data.count else { return 0 }
        // Read last 8 bytes as UInt64 (sufficient for offsets/lengths)
        let slice = data[(offset + 24)..<(offset + 32)]
        var value: UInt64 = 0
        for byte in slice { value = (value << 8) | UInt64(byte) }
        return Int(value)
    }

    /// Read a big-endian uint256 from Data and return as UInt64.
    /// Returns UInt64.max if value overflows (safe sentinel for spending checks).
    private static func readUInt256AsUInt64(_ data: Data, offset: Int) -> UInt64 {
        guard offset + 32 <= data.count else { return 0 }
        // Overflow detection: if any of the high bytes (offset..<offset+24) are non-zero
        let highSlice = data[offset..<(offset + 24)]
        if highSlice.contains(where: { $0 != 0 }) {
            return UInt64.max
        }
        let slice = data[(offset + 24)..<(offset + 32)]
        var value: UInt64 = 0
        for byte in slice { value = (value << 8) | UInt64(byte) }
        return value
    }
}
