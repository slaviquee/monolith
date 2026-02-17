import Foundation

/// Identifies stablecoins by (chainId, contractAddress) — never by symbol.
struct StablecoinRegistry {
    struct Entry: Hashable {
        let chainId: UInt64
        let address: String // lowercase hex with 0x prefix
        let decimals: UInt8

        // Equality/hashing based on (chainId, address) only — decimals is metadata.
        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.chainId == rhs.chainId && lhs.address == rhs.address
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(chainId)
            hasher.combine(address)
        }
    }

    private var entries: Set<Entry>

    static let defaultEntries: Set<Entry> = [
        // USDC on Ethereum L1
        Entry(chainId: 1, address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", decimals: 6),
        // USDC on Base
        Entry(chainId: 8453, address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", decimals: 6),
    ]

    init(entries: Set<Entry>? = nil) {
        self.entries = entries ?? Self.defaultEntries
    }

    func isStablecoin(chainId: UInt64, address: String) -> Bool {
        entries.contains(Entry(chainId: chainId, address: address.lowercased(), decimals: 0))
    }

    mutating func add(chainId: UInt64, address: String, decimals: UInt8) {
        entries.insert(Entry(chainId: chainId, address: address.lowercased(), decimals: decimals))
    }

    mutating func remove(chainId: UInt64, address: String) {
        entries.remove(Entry(chainId: chainId, address: address.lowercased(), decimals: 0))
    }
}
