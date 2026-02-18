import Foundation
import XCTest

@testable import ClawVaultDaemon

final class UserOpHashTests: XCTestCase {
    func testKeccak256Empty() {
        let hex = SignatureUtils.toHex(Keccak256.hash(Data()))
        XCTAssertEqual(hex, "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    func testKeccak256Hello() {
        let hex = SignatureUtils.toHex(Keccak256.hash("hello".data(using: .utf8)!))
        XCTAssertEqual(hex, "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }

    func testPadAddress() {
        let padded = UserOpHash.padAddress("0xCAFE")
        XCTAssertEqual(padded.count, 32)
        XCTAssertEqual(padded[30], 0xCA)
        XCTAssertEqual(padded[31], 0xFE)
    }

    func testPadUint256() {
        let padded = UserOpHash.padUint256(UInt64(256))
        XCTAssertEqual(padded.count, 32)
        XCTAssertEqual(padded[30], 0x01)
        XCTAssertEqual(padded[31], 0x00)
    }

    func testComputeHashLength() {
        let hash = UserOpHash.compute(
            sender: "0x1234567890abcdef1234567890abcdef12345678",
            nonce: Data(count: 32), initCode: Data(),
            callData: Data([0xb6, 0x1d, 0x27, 0xf6]),
            accountGasLimits: Data(count: 32), preVerificationGas: Data(count: 32),
            gasFees: Data(count: 32), paymasterAndData: Data(),
            entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 1
        )
        XCTAssertEqual(hash.count, 32)
    }

    func testDeterministic() {
        let compute = {
            UserOpHash.compute(
                sender: "0xABCD", nonce: Data(count: 32), initCode: Data(),
                callData: Data([0x01]), accountGasLimits: Data(count: 32),
                preVerificationGas: Data(count: 32), gasFees: Data(count: 32),
                paymasterAndData: Data(),
                entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032", chainId: 8453
            )
        }
        XCTAssertEqual(compute(), compute())
    }

    func testDifferentChainId() {
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
        XCTAssertNotEqual(h1, h2)
    }

    func testDifferentEntryPoint() {
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
            entryPoint: "0x000000000000000000000000000000000000DEAD", chainId: 1
        )
        XCTAssertNotEqual(h1, h2)
    }

    // MARK: - Hash Structure Verification (non-EIP-712, matches deployed EntryPoint v0.7)

    func testHashMatchesManualComputation() {
        let sender = "0x1234567890abcdef1234567890abcdef12345678"
        let entryPoint = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
        let chainId: UInt64 = 1

        let hash = UserOpHash.compute(
            sender: sender,
            nonce: Data(count: 32), initCode: Data(),
            callData: Data([0xb6, 0x1d, 0x27, 0xf6]),
            accountGasLimits: Data(count: 32), preVerificationGas: Data(count: 32),
            gasFees: Data(count: 32), paymasterAndData: Data(),
            entryPoint: entryPoint, chainId: chainId
        )

        // Manual: innerHash = keccak256(abi.encode(sender, nonce, keccak256(initCode), keccak256(callData),
        //   accountGasLimits, preVerificationGas, gasFees, keccak256(paymasterAndData)))
        let innerHash = Keccak256.hash(
            UserOpHash.padAddress(sender)
            + UserOpHash.padUint256(Data(count: 32))
            + Keccak256.hash(Data())
            + Keccak256.hash(Data([0xb6, 0x1d, 0x27, 0xf6]))
            + UserOpHash.padBytes32(Data(count: 32))
            + UserOpHash.padUint256(Data(count: 32))
            + UserOpHash.padBytes32(Data(count: 32))
            + Keccak256.hash(Data())
        )
        // userOpHash = keccak256(abi.encode(innerHash, entryPoint, chainId))
        let expectedHash = Keccak256.hash(
            innerHash
            + UserOpHash.padAddress(entryPoint)
            + UserOpHash.padUint256(chainId)
        )
        XCTAssertEqual(hash, expectedHash)
    }
}
