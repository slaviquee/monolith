import Foundation

/// Identifies stablecoins by (chainId, contractAddress) — never by symbol.
struct StablecoinRegistry {
    struct Entry: Hashable {
        let chainId: UInt64
        let address: String // lowercase hex with 0x prefix
    }

    private var entries: Set<Entry>

    static let defaultEntries: Set<Entry> = [
        // USDC on Ethereum L1
        Entry(chainId: 1, address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
        // USDC on Base
        Entry(chainId: 8453, address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"),
    ]

    init(entries: Set<Entry>? = nil) {
        self.entries = entries ?? Self.defaultEntries
    }

    func isStablecoin(chainId: UInt64, address: String) -> Bool {
        entries.contains(Entry(chainId: chainId, address: address.lowercased()))
    }

    mutating func add(chainId: UInt64, address: String) {
        entries.insert(Entry(chainId: chainId, address: address.lowercased()))
    }

    mutating func remove(chainId: UInt64, address: String) {
        entries.remove(Entry(chainId: chainId, address: address.lowercased()))
    }
}
