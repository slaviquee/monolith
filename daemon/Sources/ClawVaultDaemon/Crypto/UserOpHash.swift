import CryptoKit
import Foundation

/// Computes ERC-4337 v0.7 userOpHash using EIP-712 typed data hashing.
/// Matches EntryPoint.getUserOpHash(): toTypedDataHash(domainSeparator, structHash).
enum UserOpHash {
    // MARK: - EIP-712 Constants

    /// keccak256("PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)")
    static let packedUserOpTypehash: Data = keccak256(
        "PackedUserOperation(address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData)".data(using: .utf8)!
    )

    /// keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    static let eip712DomainTypehash: Data = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)".data(using: .utf8)!
    )

    /// keccak256("ERC4337")
    static let nameHash: Data = keccak256("ERC4337".data(using: .utf8)!)

    /// keccak256("1")
    static let versionHash: Data = keccak256("1".data(using: .utf8)!)

    /// Compute the standard userOpHash for a PackedUserOperation.
    /// This is what the EntryPoint passes to validateUserOp and what must be signed.
    /// Uses EIP-712: keccak256(0x19 || 0x01 || domainSeparator || structHash)
    static func compute(
        sender: String,
        nonce: Data,
        initCode: Data,
        callData: Data,
        accountGasLimits: Data,
        preVerificationGas: Data,
        gasFees: Data,
        paymasterAndData: Data,
        entryPoint: String,
        chainId: UInt64
    ) -> Data {
        // 1. structHash = keccak256(abi.encode(TYPEHASH, sender, nonce, hash(initCode), hash(callData),
        //    accountGasLimits, preVerGas, gasFees, hash(paymasterAndData)))
        let structHash = keccak256(abiEncode(
            packedUserOpTypehash,
            padAddress(sender),
            padUint256(nonce),
            keccak256(initCode),
            keccak256(callData),
            padBytes32(accountGasLimits),
            padUint256(preVerificationGas),
            padBytes32(gasFees),
            keccak256(paymasterAndData)
        ))

        // 2. domainSeparator = keccak256(abi.encode(EIP712Domain_TYPEHASH, nameHash, versionHash, chainId, entryPoint))
        let domainSeparator = keccak256(abiEncode(
            eip712DomainTypehash,
            nameHash,
            versionHash,
            padUint256(chainId),
            padAddress(entryPoint)
        ))

        // 3. final = keccak256(0x19 || 0x01 || domainSeparator || structHash)
        var message = Data([0x19, 0x01])
        message.append(domainSeparator)
        message.append(structHash)
        return keccak256(message)
    }

    // MARK: - Keccak256

    /// Compute Keccak-256 hash for Ethereum compatibility.
    /// IMPORTANT: We use a custom Keccak-256 implementation with original Keccak padding (0x01),
    /// NOT CryptoKit's SHA3-256 which uses FIPS-202 padding (0x06). These produce different outputs.
    /// Ethereum uses the pre-FIPS Keccak-256 variant throughout (addresses, tx hashes, userOpHash, etc.).
    static func keccak256(_ data: Data) -> Data {
        Keccak256.hash(data)
    }

    // MARK: - ABI Encoding Helpers

    static func abiEncodePacked(_ values: Data...) -> Data {
        values.reduce(Data()) { $0 + $1 }
    }

    static func abiEncode(_ values: Data...) -> Data {
        values.reduce(Data()) { $0 + $1 }
    }

    static func padAddress(_ address: String) -> Data {
        guard let bytes = SignatureUtils.fromHex(address) else { return Data(count: 32) }
        // Left-pad to 32 bytes
        var padded = Data(count: 32 - bytes.count)
        padded.append(bytes)
        return padded
    }

    static func padUint256(_ value: Data) -> Data {
        if value.count >= 32 { return value.prefix(32) }
        var padded = Data(count: 32 - value.count)
        padded.append(value)
        return padded
    }

    static func padUint256(_ value: UInt64) -> Data {
        var padded = Data(count: 24) // 32 - 8 = 24 bytes of zeros
        withUnsafeBytes(of: value.bigEndian) { padded.append(contentsOf: $0) }
        return padded
    }

    static func padBytes32(_ value: Data) -> Data {
        if value.count >= 32 { return value.prefix(32) }
        var result = value
        result.append(Data(count: 32 - value.count))
        return result
    }
}

/// Minimal Keccak-256 implementation for Ethereum compatibility.
/// CryptoKit's SHA-3 uses the FIPS 202 padding (0x06) not the original Keccak padding (0x01).
enum Keccak256 {
    private static let RC: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    private static let rotations: [[Int]] = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14],
    ]

    static func hash(_ data: Data) -> Data {
        let rate = 136 // (1600 - 256*2) / 8 = 136 bytes for Keccak-256
        var state = [UInt64](repeating: 0, count: 25)

        // Pad: append 0x01, zeros, then set last byte's high bit
        var padded = Array(data)
        padded.append(0x01) // Keccak padding (not FIPS 202's 0x06)
        while padded.count % rate != 0 {
            padded.append(0x00)
        }
        padded[padded.count - 1] |= 0x80

        // Absorb
        for blockStart in stride(from: 0, to: padded.count, by: rate) {
            for i in 0..<(rate / 8) {
                let offset = blockStart + i * 8
                var word: UInt64 = 0
                for j in 0..<8 {
                    word |= UInt64(padded[offset + j]) << (j * 8)
                }
                state[i] ^= word
            }
            keccakF(&state)
        }

        // Squeeze (only need 32 bytes for Keccak-256)
        var output = Data(count: 32)
        for i in 0..<4 {
            var word = state[i]
            for j in 0..<8 {
                output[i * 8 + j] = UInt8(word & 0xFF)
                word >>= 8
            }
        }
        return output
    }

    private static func keccakF(_ state: inout [UInt64]) {
        for round in 0..<24 {
            // θ step
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotl64(c[(x + 1) % 5], 1)
            }
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            // ρ and π steps
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl64(state[x + 5 * y], rotations[x][y])
                }
            }

            // χ step
            for x in 0..<5 {
                for y in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ (~b[(x + 1) % 5 + 5 * y] & b[(x + 2) % 5 + 5 * y])
                }
            }

            // ι step
            state[0] ^= RC[round]
        }
    }

    private static func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}
