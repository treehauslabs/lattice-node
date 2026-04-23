import Foundation

public struct StateChangeset: Sendable {
    public let height: UInt64
    public let blockHash: String
    public let timestamp: Int64
    public let difficulty: String
    public let stateRoot: String

    public init(
        height: UInt64,
        blockHash: String,
        timestamp: Int64,
        difficulty: String,
        stateRoot: String
    ) {
        self.height = height
        self.blockHash = blockHash
        self.timestamp = timestamp
        self.difficulty = difficulty
        self.stateRoot = stateRoot
    }
}
