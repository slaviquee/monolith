import Foundation

/// Protocol allowlist: (chainId, contractAddress, allowedSelectors)
/// Only interactions matching a known contract + known selector are autopilot-eligible.
struct ProtocolRegistry {
    struct ProtocolEntry: Hashable {
        let chainId: UInt64
        let address: String // lowercase hex
        let name: String
    }

    struct AllowedAction: Hashable {
        let protocol_: ProtocolEntry
        let selector: String // 4-byte hex e.g. "0x3593564c"
    }

    private var allowedActions: Set<AllowedAction>

    // Well-known selectors
    static let uniswapExecute = "0x3593564c" // execute(bytes,bytes[],uint256)
    static let aaveDeposit = "0xe8eda9df"    // deposit(address,uint256,address,uint16)
    static let aaveWithdraw = "0x69328dec"   // withdraw(address,uint256,address)
    static let lidoSubmit = "0xa1903eab"     // submit(address) — ETH-in staking
    static let rocketDeposit = "0xd0e30db0"  // deposit() — ETH-in staking
    static let aerodromeSwap = "0x3593564c"  // execute(bytes,bytes[],uint256)

    // Well-known addresses
    static let uniswapRouterL1 = "0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad"
    static let uniswapRouterBase = "0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad"
    static let aavePoolL1 = "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2"
    static let aavePoolBase = "0xa238dd80c259a72e81d7e4664a9801593f98d1c5"
    static let lidoL1 = "0xae7ab96520de3a18e5e111b5eaab095312d7fe84"
    static let rocketPoolL1 = "0xdd9683b1e0b85f28ae19d0043cb1e07e9b7521c5"
    static let aerodromeBase = "0xcf77a3ba9a5ca399b7c97c74d54e5b1beb874e43"

    init(profile: String) {
        allowedActions = Self.actionsForProfile(profile)
    }

    static func actionsForProfile(_ profile: String) -> Set<AllowedAction> {
        var actions = Set<AllowedAction>()

        // Both profiles: Uniswap + Aave on both chains
        let uniL1 = ProtocolEntry(chainId: 1, address: uniswapRouterL1, name: "Uniswap")
        let uniBase = ProtocolEntry(chainId: 8453, address: uniswapRouterBase, name: "Uniswap")
        let aaveL1 = ProtocolEntry(chainId: 1, address: aavePoolL1, name: "Aave")
        let aaveBase = ProtocolEntry(chainId: 8453, address: aavePoolBase, name: "Aave")

        actions.insert(AllowedAction(protocol_: uniL1, selector: uniswapExecute))
        actions.insert(AllowedAction(protocol_: uniBase, selector: uniswapExecute))
        actions.insert(AllowedAction(protocol_: aaveL1, selector: aaveDeposit))
        actions.insert(AllowedAction(protocol_: aaveL1, selector: aaveWithdraw))
        actions.insert(AllowedAction(protocol_: aaveBase, selector: aaveDeposit))
        actions.insert(AllowedAction(protocol_: aaveBase, selector: aaveWithdraw))

        if profile == "autonomous" {
            // L1: + Lido + Rocket Pool (ETH-in only)
            let lido = ProtocolEntry(chainId: 1, address: lidoL1, name: "Lido")
            let rocket = ProtocolEntry(chainId: 1, address: rocketPoolL1, name: "Rocket Pool")
            actions.insert(AllowedAction(protocol_: lido, selector: lidoSubmit))
            actions.insert(AllowedAction(protocol_: rocket, selector: rocketDeposit))

            // Base: + Aerodrome
            let aero = ProtocolEntry(chainId: 8453, address: aerodromeBase, name: "Aerodrome")
            actions.insert(AllowedAction(protocol_: aero, selector: aerodromeSwap))
        }

        return actions
    }

    func isAllowed(chainId: UInt64, target: String, selector: String) -> Bool {
        let targetLower = target.lowercased()
        return allowedActions.contains { action in
            action.protocol_.chainId == chainId
                && action.protocol_.address == targetLower
                && action.selector == selector.lowercased()
        }
    }

    func protocolName(chainId: UInt64, address: String) -> String? {
        let addrLower = address.lowercased()
        return allowedActions.first { $0.protocol_.chainId == chainId && $0.protocol_.address == addrLower }?
            .protocol_.name
    }
}
