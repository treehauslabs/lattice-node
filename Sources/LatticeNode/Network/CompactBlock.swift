import Foundation
import Lattice

public struct CompactBlockHeader: Sendable {
    public let blockCID: String
    public let index: UInt64
    public let timestamp: Int64
    public let previousBlockCID: String?
    public let difficulty: String
    public let transactionCount: Int
}

public struct CompactBlock: Sendable {
    public let header: CompactBlockHeader
    public let shortTxIDs: [UInt64]
    public let prefilledTxs: [(index: Int, cid: String, data: Data)]

    public static func from(
        blockCID: String,
        block: Block,
        sipKey: UInt64,
        prefilledIndices: Set<Int> = [0]
    ) -> CompactBlock {
        let txCIDs = block.transactionCIDs()
        var shortIDs: [UInt64] = []
        var prefilled: [(index: Int, cid: String, data: Data)] = []

        for (i, cid) in txCIDs.enumerated() {
            if prefilledIndices.contains(i) {
                prefilled.append((index: i, cid: cid, data: Data()))
            }
            shortIDs.append(shortTxID(cid: cid, key: sipKey))
        }

        let header = CompactBlockHeader(
            blockCID: blockCID,
            index: block.index,
            timestamp: block.timestamp,
            previousBlockCID: block.previousBlock?.rawCID,
            difficulty: block.difficulty.toHexString(),
            transactionCount: txCIDs.count
        )

        return CompactBlock(
            header: header,
            shortTxIDs: shortIDs,
            prefilledTxs: prefilled
        )
    }

    public struct ReconstructionResult: Sendable {
        public let missingShortIDs: [UInt64]
        public let matchedCIDs: [String?]
        public let isComplete: Bool

        public var missingCount: Int { missingShortIDs.count }
    }

    public static func reconstruct(
        compact: CompactBlock,
        mempoolCIDs: [String],
        sipKey: UInt64
    ) -> ReconstructionResult {
        var cidByShortID: [UInt64: String] = [:]
        for cid in mempoolCIDs {
            let sid = shortTxID(cid: cid, key: sipKey)
            cidByShortID[sid] = cid
        }

        let prefilledByIndex = Dictionary(
            uniqueKeysWithValues: compact.prefilledTxs.map { ($0.index, $0.cid) }
        )

        var matchedCIDs: [String?] = Array(repeating: nil, count: compact.shortTxIDs.count)
        var missing: [UInt64] = []

        for (i, shortID) in compact.shortTxIDs.enumerated() {
            if let prefilledCID = prefilledByIndex[i] {
                matchedCIDs[i] = prefilledCID
            } else if let matched = cidByShortID[shortID] {
                matchedCIDs[i] = matched
            } else {
                missing.append(shortID)
            }
        }

        return ReconstructionResult(
            missingShortIDs: missing,
            matchedCIDs: matchedCIDs,
            isComplete: missing.isEmpty
        )
    }

    public static func shortTxID(cid: String, key: UInt64) -> UInt64 {
        var hash: UInt64 = key
        for byte in cid.utf8 {
            hash = hash &* 0x100000001b3
            hash ^= UInt64(byte)
        }
        return hash & 0xFFFF_FFFF_FFFF
    }
}

extension Block {
    func transactionCIDs() -> [String] {
        guard let txDict = self.transactions.node else { return [] }
        return (try? Array(txDict.allKeys())) ?? []
    }
}
