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

    /// Convert to JSON-RPC compatible dictionary.
    func toDict() -> [String: Any] {
        [
            "sender": sender,
            "nonce": SignatureUtils.toHex(nonce),
            "initCode": SignatureUtils.toHex(initCode),
            "callData": SignatureUtils.toHex(callData),
            "accountGasLimits": SignatureUtils.toHex(accountGasLimits),
            "preVerificationGas": SignatureUtils.toHex(preVerificationGas),
            "gasFees": SignatureUtils.toHex(gasFees),
            "paymasterAndData": SignatureUtils.toHex(paymasterAndData),
            "signature": SignatureUtils.toHex(signature),
        ]
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
