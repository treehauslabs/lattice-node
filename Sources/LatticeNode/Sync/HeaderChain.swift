import Foundation
import Lattice
import cashew
import UInt256

public struct SyncBlockHeader: Sendable {
    public let cid: String
    public let index: UInt64
    public let previousBlockCID: String?
    public let difficulty: UInt256
    public let timestamp: Int64
}

public actor HeaderChain {
    private var headers: [SyncBlockHeader] = []
    private var cumulativeWork: UInt256 = .zero
    private let fetchTimeout: Duration

    public init(fetchTimeout: Duration = .seconds(30)) {
        self.fetchTimeout = fetchTimeout
    }

    public enum HeaderChainError: Error {
        case fetchFailed(String)
        case invalidPoW(String)
        case chainContinuityBroken(expected: String, got: String?)
        case insufficientWork
        case cancelled
    }

    public func downloadHeaders(
        peerTipCID: String,
        fetcher: Fetcher,
        genesisBlockHash: String,
        localWork: UInt256,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> [SyncBlockHeader] {
        headers = []
        cumulativeWork = .zero

        var currentCID = peerTipCID
        var targetHeight: UInt64?

        while !Task.isCancelled {
            let data: Data
            do {
                data = try await withTimeout(fetchTimeout, cid: currentCID, fetcher: fetcher)
            } catch {
                throw HeaderChainError.fetchFailed(currentCID)
            }

            guard let block = Block(data: data) else {
                throw HeaderChainError.fetchFailed(currentCID)
            }

            if targetHeight == nil {
                targetHeight = block.index
            }

            let diffHash = block.getDifficultyHash()
            guard block.validateBlockDifficulty(nexusHash: diffHash) else {
                throw HeaderChainError.invalidPoW(currentCID)
            }

            let work = Self.workForDifficulty(block.difficulty)
            cumulativeWork = cumulativeWork &+ work

            let header = SyncBlockHeader(
                cid: currentCID,
                index: block.index,
                previousBlockCID: block.previousBlock?.rawCID,
                difficulty: block.difficulty,
                timestamp: block.timestamp
            )
            headers.append(header)

            if let th = targetHeight {
                await progress?(th - block.index, th)
            }

            guard let prevCID = block.previousBlock?.rawCID else {
                break
            }

            if prevCID == genesisBlockHash || currentCID == genesisBlockHash {
                break
            }

            currentCID = prevCID
        }

        if Task.isCancelled {
            throw HeaderChainError.cancelled
        }

        if cumulativeWork < localWork {
            throw HeaderChainError.insufficientWork
        }

        headers.reverse()
        return headers
    }

    public var totalWork: UInt256 { cumulativeWork }
    public var headerCount: Int { headers.count }

    private static func workForDifficulty(_ difficulty: UInt256) -> UInt256 {
        guard difficulty > UInt256.zero else { return UInt256.zero }
        return UInt256.max / difficulty
    }

    private func withTimeout(_ duration: Duration, cid: String, fetcher: Fetcher) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await fetcher.fetch(rawCid: cid)
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw HeaderChainError.fetchFailed("timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
