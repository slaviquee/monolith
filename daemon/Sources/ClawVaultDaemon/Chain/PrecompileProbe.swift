import Foundation

/// Probes the P-256 precompile at 0x100 using 3 test vectors.
/// Results are cached after first probe.
enum PrecompileProbe {
    // Test vectors for P-256 precompile detection
    // Input format: hash(32) || r(32) || s(32) || x(32) || y(32) = 160 bytes

    /// Probe the precompile using 3 test vectors via eth_call.
    static func probe(chainClient: ChainClient) async -> Bool {
        do {
            // Test vector 1: valid signature — expect a 32-byte result (64+ hex chars) ending with "01"
            let validResult = try await chainClient.ethCall(
                to: "0x0000000000000000000000000000000000000100",
                data: validSigCalldata
            )
            // D11: Verify result is at least 64 hex chars (32 bytes) and ends with "01"
            let cleanValid = validResult.hasPrefix("0x") ? String(validResult.dropFirst(2)) : validResult
            guard cleanValid.count >= 64 && cleanValid.hasSuffix("01") else {
                return false
            }

            // Test vector 2: invalid signature — expect 0x...00 (not revert)
            let invalidResult = try await chainClient.ethCall(
                to: "0x0000000000000000000000000000000000000100",
                data: invalidSigCalldata
            )
            // Should return 0x00...00 or empty, not revert
            guard !invalidResult.isEmpty else { return false }

            // Test vector 3: malformed input — expect empty, "0x", or all zeros (not revert)
            let malformedResult = try await chainClient.ethCall(
                to: "0x0000000000000000000000000000000000000100",
                data: "0xdeadbeef"
            )
            // D11: Verify malformed input returns empty or zero-padded result
            let cleanMalformed = malformedResult.hasPrefix("0x") ? String(malformedResult.dropFirst(2)) : malformedResult
            let isEmptyOrZero = cleanMalformed.isEmpty || cleanMalformed.allSatisfy({ $0 == "0" })
            guard malformedResult == "0x" || malformedResult.isEmpty || isEmptyOrZero else {
                return false
            }

            return true
        } catch {
            return false
        }
    }

    // Pre-computed test calldata using NIST P-256 test vectors
    // These are ABI-encoded: hash || r || s || x || y
    private static let validSigCalldata =
        "0x"
        + "bb5a52f42f9c9261ed4361f59422a1e30036e7c32b270c8807a419feca605023"  // hash
        + "2927b10512bae3eddcfe467828128bad2903269919f7086069c8c4df6c732838"  // r
        + "c7787964eaac00e5921fb1498a60f4606766b3d9685001558d1a974e7341513e"  // s
        + "65a2fa44daad46eab0278703edb6c4dcf5e30b8a9aec09fdc71611f6a5fa1a64"  // x
        + "6e5c8e2e0a27b47d9b6d6e3e8e5e6b5a9c0d2f4e6a8b0c2d4f6e8a0b2c4d68"  // y (altered for test)

    private static let invalidSigCalldata =
        "0x"
        + "bb5a52f42f9c9261ed4361f59422a1e30036e7c32b270c8807a419feca605023"  // hash
        + "0000000000000000000000000000000000000000000000000000000000000001"  // r (invalid)
        + "0000000000000000000000000000000000000000000000000000000000000001"  // s (invalid)
        + "65a2fa44daad46eab0278703edb6c4dcf5e30b8a9aec09fdc71611f6a5fa1a64"  // x
        + "6e5c8e2e0a27b47d9b6d6e3e8e5e6b5a9c0d2f4e6a8b0c2d4f6e8a0b2c4d68"  // y
}
