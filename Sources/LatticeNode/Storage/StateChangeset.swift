import Foundation

public struct AccountState: Codable, Sendable {
    public let balance: UInt64
    public let nonce: UInt64

    public init(balance: UInt64, nonce: UInt64) {
        self.balance = balance
        self.nonce = nonce
    }
}

public struct StateChangeset: Sendable {
    public let height: UInt64
    public let blockHash: String
    public let accountUpdates: [(address: String, balance: UInt64, nonce: UInt64)]
    public let generalUpdates: [(key: String, value: Data)]
    public let timestamp: Int64
    public let difficulty: String
    public let stateRoot: String

    public init(
        height: UInt64,
        blockHash: String,
        accountUpdates: [(address: String, balance: UInt64, nonce: UInt64)],
        generalUpdates: [(key: String, value: Data)] = [],
        timestamp: Int64,
        difficulty: String,
        stateRoot: String
    ) {
        self.height = height
        self.blockHash = blockHash
        self.accountUpdates = accountUpdates
        self.generalUpdates = generalUpdates
        self.timestamp = timestamp
        self.difficulty = difficulty
        self.stateRoot = stateRoot
    }
}
