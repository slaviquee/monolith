import Foundation

/// ERC-4337 v0.7 PackedUserOperation.
struct UserOperation {
    var sender: String            // wallet address
    var nonce: Data               // uint256
    var initCode: Data            // factory + calldata (or empty)
    var callData: Data            // the method call
    var accountGasLimits: Data    // packed: uint128(verificationGasLimit) || uint128(callGasLimit)
    var preVerificationGas: Data  // uint256
    var gasFees: Data             // packed: uint128(maxPriorityFeePerGas) || uint128(maxFeePerGas)
    var paymasterAndData: Data    // always empty for ClawVault
    var signature: Data           // P-256 raw r||s (64 bytes)

    /// Convert to bundler JSON-RPC format (ERC-4337 v0.7 unpacked).
    func toDict() -> [String: Any] {
        let (verificationGasLimit, callGasLimit) = Self.unpackGasLimits(accountGasLimits)
        let (maxPriorityFeePerGas, maxFeePerGas) = Self.unpackGasFees(gasFees)
        let preVerGas = Self.unpackUint256AsUInt64(preVerificationGas)

        var dict: [String: Any] = [
            "sender": sender,
            "nonce": SignatureUtils.toHex(nonce),
            "callData": SignatureUtils.toHex(callData),
            "verificationGasLimit": "0x" + String(verificationGasLimit, radix: 16),
            "callGasLimit": "0x" + String(callGasLimit, radix: 16),
            "preVerificationGas": "0x" + String(preVerGas, radix: 16),
            "maxFeePerGas": "0x" + String(maxFeePerGas, radix: 16),
            "maxPriorityFeePerGas": "0x" + String(maxPriorityFeePerGas, radix: 16),
            "signature": SignatureUtils.toHex(signature),
        ]

        // v0.7: split initCode into factory + factoryData
        if !initCode.isEmpty {
            let factoryAddr = "0x" + initCode.prefix(20).map { String(format: "%02x", $0) }.joined()
            let factoryData = "0x" + initCode.dropFirst(20).map { String(format: "%02x", $0) }.joined()
            dict["factory"] = factoryAddr
            dict["factoryData"] = factoryData
        }

        // v0.7: split paymasterAndData (empty for ClawVault, but handle for completeness)
        if !paymasterAndData.isEmpty {
            let paymasterAddr = "0x" + paymasterAndData.prefix(20).map { String(format: "%02x", $0) }.joined()
            let pmData = "0x" + paymasterAndData.dropFirst(20).map { String(format: "%02x", $0) }.joined()
            dict["paymaster"] = paymasterAddr
            dict["paymasterData"] = pmData
        }

        return dict
    }

    /// Pack verificationGasLimit and callGasLimit into bytes32.
    static func packGasLimits(verificationGasLimit: UInt64, callGasLimit: UInt64) -> Data {
        // uint128(verificationGasLimit) || uint128(callGasLimit) = 32 bytes
        var packed = Data(count: 32)
        // verificationGasLimit in upper 16 bytes
        withUnsafeBytes(of: verificationGasLimit.bigEndian) { bytes in
            packed.replaceSubrange(8..<16, with: bytes)
        }
        // callGasLimit in lower 16 bytes
        withUnsafeBytes(of: callGasLimit.bigEndian) { bytes in
            packed.replaceSubrange(24..<32, with: bytes)
        }
        return packed
    }

    /// Pack maxPriorityFeePerGas and maxFeePerGas into bytes32.
    static func packGasFees(maxPriorityFeePerGas: UInt64, maxFeePerGas: UInt64) -> Data {
        var packed = Data(count: 32)
        withUnsafeBytes(of: maxPriorityFeePerGas.bigEndian) { bytes in
            packed.replaceSubrange(8..<16, with: bytes)
        }
        withUnsafeBytes(of: maxFeePerGas.bigEndian) { bytes in
            packed.replaceSubrange(24..<32, with: bytes)
        }
        return packed
    }

    /// Unpack verificationGasLimit and callGasLimit from packed bytes32.
    static func unpackGasLimits(_ data: Data) -> (verificationGasLimit: UInt64, callGasLimit: UInt64) {
        guard data.count >= 32 else { return (200_000, 200_000) }
        let verificationGasLimit = data[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let callGasLimit = data[24..<32].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return (verificationGasLimit, callGasLimit)
    }

    /// Unpack maxPriorityFeePerGas and maxFeePerGas from packed bytes32.
    static func unpackGasFees(_ data: Data) -> (maxPriorityFeePerGas: UInt64, maxFeePerGas: UInt64) {
        guard data.count >= 32 else { return (1_500_000_000, 30_000_000_000) }
        let maxPriorityFeePerGas = data[8..<16].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        let maxFeePerGas = data[24..<32].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
        return (maxPriorityFeePerGas, maxFeePerGas)
    }

    /// Extract UInt64 from a 32-byte big-endian uint256.
    static func unpackUint256AsUInt64(_ data: Data) -> UInt64 {
        guard data.count >= 32 else { return 50_000 }
        return data[24..<32].withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
    }
}
