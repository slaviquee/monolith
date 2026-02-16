import Foundation
import Testing

@testable import ClawVaultDaemon

@Suite("CalldataDecoder")
struct CalldataDecoderTests {
    let stableRegistry = StablecoinRegistry()
    let protocolRegistry = ProtocolRegistry(profile: "balanced")

    @Test func decodeNativeTransfer() {
        let decoded = CalldataDecoder.decode(
            calldata: Data(), target: "0xCAFE0000000000000000000000000000CAFECAFE",
            value: 50_000_000_000_000_000, chainId: 1,
            stablecoinRegistry: stableRegistry, protocolRegistry: protocolRegistry
        )
        #expect(decoded.action == "Transfer")
        #expect(decoded.summary.contains("ETH"))
        #expect(decoded.isKnown)
    }

    @Test func decodeUnknown() {
        let calldata = Data([0xDE, 0xAD, 0xBE, 0xEF]) + Data(count: 32)
        let decoded = CalldataDecoder.decode(
            calldata: calldata, target: "0x1234567890abcdef1234567890abcdef12345678",
            value: 0, chainId: 1,
            stablecoinRegistry: stableRegistry, protocolRegistry: protocolRegistry
        )
        #expect(decoded.action == "Unknown")
        #expect(!decoded.isKnown)
        #expect(decoded.summary.contains("deadbeef"))
    }

    @Test func shortenAddress() {
        #expect(CalldataDecoder.shortenAddress("0x1234567890abcdef1234567890abcdef12345678") == "0x1234…5678")
    }

    @Test func formatWei() {
        #expect(CalldataDecoder.formatWei(50_000_000_000_000_000) == "0.0500")
    }

    @Test func formatUSDC() {
        #expect(CalldataDecoder.formatUSDC(100_000_000) == "100.00")
    }
}
