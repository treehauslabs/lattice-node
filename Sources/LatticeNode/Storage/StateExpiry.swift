import Foundation

public actor StateExpiry {
    private let store: StateStore
    private let expiryBlocks: UInt64

    public init(store: StateStore, expiryBlocks: UInt64 = 1_000_000) {
        self.store = store
        self.expiryBlocks = expiryBlocks
    }

    public struct ExpiredAccount: Sendable {
        public let address: String
        public let balance: UInt64
        public let nonce: UInt64
        public let lastActiveHeight: UInt64
    }

    public func findExpiredAccounts(currentHeight: UInt64) async -> [ExpiredAccount] {
        guard currentHeight > expiryBlocks else { return [] }
        let cutoff = currentHeight - expiryBlocks

        guard let rows = try? await store.queryAccountsBelowHeight(cutoff) else {
            return []
        }
        return rows
    }

    public func expireAccounts(_ accounts: [ExpiredAccount], atHeight: UInt64) async {
        for account in accounts {
            await store.expireAccount(address: account.address, atHeight: atHeight)
        }
    }

    public func reviveAccount(address: String, proof: Data, atHeight: UInt64) async -> Bool {
        return await store.reviveAccount(address: address, proof: proof, atHeight: atHeight)
    }
}
