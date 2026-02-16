import Foundation

/// P-256 signature utilities: low-S normalization, raw r||s extraction.
enum SignatureUtils {
    /// P-256 curve order n
    static let p256N: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
        0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51,
    ]

    /// P-256 curve order n/2
    static let p256NDiv2: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xDE, 0x73, 0x7D, 0x56, 0xD3, 0x8B, 0xCF, 0x42,
        0x79, 0xDC, 0xE5, 0x61, 0x7E, 0x31, 0x92, 0xA8,
    ]

    /// Extract raw r||s (64 bytes) from CryptoKit P256 signature and apply low-S normalization.
    /// CryptoKit rawRepresentation is already r (32 bytes) || s (32 bytes).
    static func normalizeSignature(_ rawSig: Data) -> Data {
        guard rawSig.count == 64 else { return rawSig }

        let r = Array(rawSig.prefix(32))
        var s = Array(rawSig.suffix(32))

        // Low-S normalization: if s > n/2, replace s with n - s
        if compareUInt256(s, p256NDiv2) > 0 {
            s = subtractUInt256(p256N, s)
        }

        return Data(r) + Data(s)
    }

    /// Compare two 32-byte big-endian unsigned integers.
    /// Returns: positive if a > b, 0 if equal, negative if a < b.
    static func compareUInt256(_ a: [UInt8], _ b: [UInt8]) -> Int {
        for i in 0..<32 {
            if a[i] > b[i] { return 1 }
            if a[i] < b[i] { return -1 }
        }
        return 0
    }

    /// Subtract two 32-byte big-endian unsigned integers: a - b.
    /// Assumes a >= b.
    static func subtractUInt256(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow: Int = 0

        for i in stride(from: 31, through: 0, by: -1) {
            let diff = Int(a[i]) - Int(b[i]) - borrow
            if diff < 0 {
                result[i] = UInt8((diff + 256) & 0xFF)
                borrow = 1
            } else {
                result[i] = UInt8(diff & 0xFF)
                borrow = 0
            }
        }

        return result
    }

    /// Convert a 32-byte Data to hex string with 0x prefix.
    static func toHex(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    /// Convert hex string (with or without 0x prefix) to Data.
    static func fromHex(_ hex: String) -> Data? {
        var hexStr = hex
        if hexStr.hasPrefix("0x") || hexStr.hasPrefix("0X") {
            hexStr = String(hexStr.dropFirst(2))
        }
        guard hexStr.count % 2 == 0 else { return nil }

        var data = Data()
        var index = hexStr.startIndex
        while index < hexStr.endIndex {
            let nextIndex = hexStr.index(index, offsetBy: 2)
            guard let byte = UInt8(hexStr[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
