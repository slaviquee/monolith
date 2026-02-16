import Foundation
import Testing

@testable import ClawVaultDaemon

@Suite("UserOpHash")
struct UserOpHashTests {
    @Test func keccak256Empty() {
        let hex = SignatureUtils.toHex(Keccak256.hash(Data()))
        #expect(hex == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    @Test func keccak256Hello() {
        let hex = SignatureUtils.toHex(Keccak256.hash("hello".data(using: .utf8)!))
        #expect(hex == "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

    @Test func padAddress() {
        let padded = UserOpHash.padAddress("0xCAFE")
        #expect(padded.count == 32)
        #expect(padded[30] == 0xCA)
        #expect(padded[31] == 0xFE)
    }

    @Test func padUint256() {
        let padded = UserOpHash.padUint256(UInt64(256))
        #expect(padded.count == 32)
        #expect(padded[30] == 0x01)
        #expect(padded[31] == 0x00)
    }

    @Test func computeHashLength() {
        let hash = UserOpHash.compute(
            sender: "0x1234567890abcdef1234567890abcdef12345678",
            nonce: Data(count: 32), initCode: Data(),
            callData: Data([0xb6, 0x1d, 0x27, 0xf6]),
            accountGasLimits: Data(count: 32), preVerificationGas: Data(count: 32),
            gasFees: Data(count: 32), paymasterAndData: Data(),
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 1
        )
        #expect(hash.count == 32)
    }

    @Test func deterministic() {
        let compute = {
            UserOpHash.compute(
                sender: "0xABCD", nonce: Data(count: 32), initCode: Data(),
                callData: Data([0x01]), accountGasLimits: Data(count: 32),
                preVerificationGas: Data(count: 32), gasFees: Data(count: 32),
                paymasterAndData: Data(),
                entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 8453
            )
        }
        #expect(compute() == compute())
    }

    @Test func differentChainId() {
        let h1 = UserOpHash.compute(
            sender: "0xABCD", nonce: Data(count: 32), initCode: Data(),
            callData: Data([0x01]), accountGasLimits: Data(count: 32),
            preVerificationGas: Data(count: 32), gasFees: Data(count: 32),
            paymasterAndData: Data(),
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 1
        )
        let h2 = UserOpHash.compute(
            sender: "0xABCD", nonce: Data(count: 32), initCode: Data(),
            callData: Data([0x01]), accountGasLimits: Data(count: 32),
            preVerificationGas: Data(count: 32), gasFees: Data(count: 32),
            paymasterAndData: Data(),
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 8453
        )
        #expect(h1 != h2)
    }
}
