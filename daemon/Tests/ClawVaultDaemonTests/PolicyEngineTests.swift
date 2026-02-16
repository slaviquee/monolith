import Foundation
import Testing

@testable import ClawVaultDaemon

@Suite("PolicyEngine")
struct PolicyEngineTests {
    func makeEngine(profile: String = "balanced", frozen: Bool = false) -> PolicyEngine {
        PolicyEngine(
            profile: SecurityProfile.forName(profile) ?? .balanced,
            protocolRegistry: ProtocolRegistry(profile: "balanced"),
            stablecoinRegistry: StablecoinRegistry(),
            frozen: frozen
        )
    }

    @Test func frozenDeniesAll() async {
        let engine = makeEngine(frozen: true)
        let decision = await engine.evaluate(target: "0xCAFE", calldata: Data(), value: 1000, chainId: 8453)
        guard case .deny(let reason) = decision else { Issue.record("Expected deny"); return }
        #expect(reason.contains("frozen"))
    }

    @Test func blockedSelectorRequiresApproval() async {
        let engine = makeEngine()
        let calldata = Data([0x09, 0x5e, 0xa7, 0xb3]) + Data(count: 64)
        let decision = await engine.evaluate(target: "0xA0b86991", calldata: calldata, value: 0, chainId: 1)
        guard case .requireApproval(let reason) = decision else { Issue.record("Expected requireApproval"); return }
        #expect(reason.contains("Blocked selector"))
    }

    @Test func unknownCalldataRequiresApproval() async {
        let engine = makeEngine()
        let calldata = Data([0xDE, 0xAD, 0xBE, 0xEF]) + Data(count: 32)
        let decision = await engine.evaluate(target: "0x1234", calldata: calldata, value: 0, chainId: 8453)
        guard case .requireApproval(let reason) = decision else { Issue.record("Expected requireApproval"); return }
        #expect(reason.contains("Unknown"))
    }

    @Test func freezeUnfreeze() async {
        let engine = makeEngine()
        await engine.freeze()
        #expect(await engine.isFrozen)
        await engine.unfreeze()
        #expect(await !engine.isFrozen)
    }
}
