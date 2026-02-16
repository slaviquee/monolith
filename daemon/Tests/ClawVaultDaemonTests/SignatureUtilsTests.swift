import Foundation
import Testing

@testable import ClawVaultDaemon

@Suite("SignatureUtils")
struct SignatureUtilsTests {
    @Test func hexRoundtrip() {
        let original = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hex = SignatureUtils.toHex(original)
        #expect(hex == "0xdeadbeef")
        #expect(SignatureUtils.fromHex(hex) == original)
    }

    @Test func fromHexPrefix() {
        let a = SignatureUtils.fromHex("0xabcd")
        let b = SignatureUtils.fromHex("abcd")
        #expect(a == b)
        #expect(a == Data([0xAB, 0xCD]))
    }

    @Test func lowSAlreadyNormalized() {
        var sig = Data(count: 64)
        sig[63] = 1; sig[31] = 1
        #expect(SignatureUtils.normalizeSignature(sig) == sig)
    }

    @Test func highSNormalized() {
        var sig = Data(count: 64)
        sig[31] = 1
        let nDiv2 = SignatureUtils.p256NDiv2
        for i in 0..<32 { sig[32 + i] = nDiv2[i] }
        sig[63] &+= 1
        let normalized = SignatureUtils.normalizeSignature(sig)
        let normalizedS = Array(normalized[32..<64])
        #expect(SignatureUtils.compareUInt256(normalizedS, nDiv2) <= 0)
    }

    @Test func compareOrdering() {
        var a = [UInt8](repeating: 0, count: 32)
        var b = [UInt8](repeating: 0, count: 32)
        a[31] = 1; b[31] = 2
        #expect(SignatureUtils.compareUInt256(a, b) < 0)
        a[31] = 2
        #expect(SignatureUtils.compareUInt256(a, b) == 0)
        a[31] = 3
        #expect(SignatureUtils.compareUInt256(a, b) > 0)
    }

    @Test func subtraction() {
        var a = [UInt8](repeating: 0, count: 32)
        var b = [UInt8](repeating: 0, count: 32)
        a[31] = 10; b[31] = 3
        #expect(SignatureUtils.subtractUInt256(a, b)[31] == 7)
    }

    @Test func normalizeWrongLength() {
        let short = Data([1, 2, 3])
        #expect(SignatureUtils.normalizeSignature(short) == short)
    }
}
