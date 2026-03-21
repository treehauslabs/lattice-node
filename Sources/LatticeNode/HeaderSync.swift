import Lattice
import Foundation
import cashew
import UInt256

public struct BlockHeaderSummary: Codable, Sendable {
    public let blockHash: String
    public let previousBlockHash: String?
    public let index: UInt64
    public let timestamp: Int64
    public let difficulty: String
    public let homesteadCID: String
    public let frontierCID: String
    public let transactionsCID: String

    public init(block: Block) {
        self.blockHash = HeaderImpl<Block>(node: block).rawCID
        self.previousBlockHash = block.previousBlock?.rawCID
        self.index = block.index
        self.timestamp = block.timestamp
        self.difficulty = block.difficulty.toPrefixedHexString()
        self.homesteadCID = block.homestead.rawCID
        self.frontierCID = block.frontier.rawCID
        self.transactionsCID = block.transactions.rawCID
    }
}

public actor HeaderChain {
    private var headers: [UInt64: BlockHeaderSummary]
    private var tipIndex: UInt64

    public init() {
        self.headers = [:]
        self.tipIndex = 0
    }

    public func tip() -> BlockHeaderSummary? {
        headers[tipIndex]
    }

    public func header(at index: UInt64) -> BlockHeaderSummary? {
        headers[index]
    }

    public func height() -> UInt64 {
        tipIndex
    }

    public func addHeader(_ header: BlockHeaderSummary) -> Bool {
        if header.index == 0 {
            headers[0] = header
            return true
        }

        guard let parent = headers[header.index - 1] else { return false }
        guard parent.blockHash == header.previousBlockHash else { return false }
        guard header.timestamp > parent.timestamp else { return false }

        headers[header.index] = header
        if header.index > tipIndex {
            tipIndex = header.index
        }
        return true
    }

    public func verify(from startIndex: UInt64, to endIndex: UInt64) -> Bool {
        guard startIndex <= endIndex else { return false }
        guard headers[startIndex] != nil else { return false }

        for i in (startIndex + 1)...endIndex {
            guard let current = headers[i] else { return false }
            guard let previous = headers[i - 1] else { return false }
            guard current.previousBlockHash == previous.blockHash else { return false }
            guard current.timestamp > previous.timestamp else { return false }
            guard current.index == i else { return false }
        }
        return true
    }

    public func headerRange(from: UInt64, count: Int) -> [BlockHeaderSummary] {
        var result: [BlockHeaderSummary] = []
        for i in from..<(from + UInt64(count)) {
            guard let h = headers[i] else { break }
            result.append(h)
        }
        return result
    }

    public func clear() {
        headers.removeAll()
        tipIndex = 0
    }
}
