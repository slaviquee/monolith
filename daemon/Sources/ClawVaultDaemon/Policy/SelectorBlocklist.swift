import Foundation

/// Blocked function selectors that MUST require explicit user approval regardless of context.
/// These are token approval-related selectors that enable drain attacks.
enum SelectorBlocklist {
    /// All blocked 4-byte function selectors.
    static let blocked: Set<String> = [
        "095ea7b3", // approve(address,uint256)
        "39509351", // increaseAllowance(address,uint256)
        "a457c2d7", // decreaseAllowance(address,uint256)
        "a22cb465", // setApprovalForAll(address,bool)
        "d505accf", // permit(address,address,uint256,uint256,uint8,bytes32,bytes32) — EIP-2612
        "8fcbaf0c", // permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32) — DAI
        "2b67b570", // Permit2 approve
        "2a2d80d1", // Permit2 permit
        "30f28b7a", // Permit2 permitTransferFrom
        "edd9444b", // Permit2 permitBatchTransferFrom
    ]

    /// Check if a 4-byte selector (hex, no 0x prefix) is blocked.
    static func isBlocked(_ selector: String) -> Bool {
        blocked.contains(selector.lowercased())
    }

    /// Check if calldata starts with a blocked selector.
    static func isCalldataBlocked(_ calldata: Data) -> Bool {
        guard calldata.count >= 4 else { return false }
        let selector = calldata.prefix(4).map { String(format: "%02x", $0) }.joined()
        return isBlocked(selector)
    }
}
