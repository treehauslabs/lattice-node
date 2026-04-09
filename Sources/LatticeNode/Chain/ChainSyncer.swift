import Lattice
import Foundation
import cashew
import UInt256

public enum SyncStrategy: Sendable {
    case full
    case snapshot
    case headersFirst
}

public enum SyncError: Error, Sendable {
    case invalidBlock(UInt64)
    case invalidPoW(UInt64)
    case invalidStateRoot(UInt64)
    case genesisMismatch
    case cancelled
    case emptyChain
    case insufficientWork
}

public struct SyncResult: Sendable {
    public let persisted: PersistedChainState
    public let tipBlockHash: String
    public let tipBlockIndex: UInt64
    public let cumulativeWork: UInt256
}

public enum SyncFetchError: Error, Sendable {
    case timeout
}

public actor ChainSyncer {
    private let fetcher: Fetcher
    private let storeFn: @Sendable (String, Data) async -> Void
    private let genesisBlockHash: String
    private let retentionDepth: UInt64
    private let fetchTimeout: Duration
    private var cancelled = false

    public init(
        fetcher: Fetcher,
        store: @Sendable @escaping (String, Data) async -> Void,
        genesisBlockHash: String,
        retentionDepth: UInt64 = RECENT_BLOCK_DISTANCE,
        fetchTimeout: Duration = .seconds(30)
    ) {
        self.fetcher = fetcher
        self.storeFn = store
        self.genesisBlockHash = genesisBlockHash
        self.retentionDepth = retentionDepth
        self.fetchTimeout = fetchTimeout
    }

    private func fetchWithTimeout(rawCid: String) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.fetcher.fetch(rawCid: rawCid)
            }
            group.addTask {
                try await Task.sleep(for: self.fetchTimeout)
                throw SyncFetchError.timeout
            }
            guard let result = try await group.next() else {
                throw SyncFetchError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    public func cancel() {
        cancelled = true
    }

    private static func workForDifficulty(_ difficulty: UInt256) -> UInt256 {
        guard difficulty > UInt256.zero else { return UInt256.zero }
        return UInt256.max / difficulty
    }

    // MARK: - Shared Chain Walk

    private struct WalkResult {
        var collected: [(hash: String, index: UInt64, prevHash: String?)]
        var cumulativeWork: UInt256
        var tipBlock: Block?
    }

    /// Walk backwards from a CID, fetching and validating blocks.
    /// - `maxBlocks`: stop after this many blocks (nil = walk to genesis)
    /// - `progressInterval`: report progress every N blocks
    private func walkChain(
        from startCID: String,
        maxBlocks: UInt64?,
        progressInterval: Int,
        progress: (@Sendable (UInt64, UInt64) async -> Void)?
    ) async throws -> WalkResult {
        var collected: [(hash: String, index: UInt64, prevHash: String?)] = []
        var currentCID = startCID
        var targetHeight: UInt64 = 0
        var tipBlock: Block?
        var cumulativeWork = UInt256.zero

        while !cancelled {
            let data: Data
            do {
                data = try await fetchWithTimeout(rawCid: currentCID)
            } catch {
                throw SyncError.invalidBlock(UInt64(collected.count))
            }

            guard let block = Block(data: data) else {
                throw SyncError.invalidBlock(UInt64(collected.count))
            }

            if collected.isEmpty {
                targetHeight = block.index
                tipBlock = block
            }

            let diffHash = block.getDifficultyHash()
            guard block.validateBlockDifficulty(nexusHash: diffHash) else {
                throw SyncError.invalidPoW(block.index)
            }

            cumulativeWork = cumulativeWork &+ Self.workForDifficulty(block.difficulty)

            await storeFn(currentCID, data)
            collected.append((hash: currentCID, index: block.index, prevHash: block.previousBlock?.rawCID))

            if collected.count % progressInterval == 0 {
                let target = maxBlocks.map { min($0, targetHeight + 1) } ?? (targetHeight + 1)
                await progress?(UInt64(collected.count), target)
            }

            if let max = maxBlocks, UInt64(collected.count) >= max {
                break
            }

            guard let prevCID = block.previousBlock?.rawCID else {
                if maxBlocks == nil {
                    guard currentCID == genesisBlockHash else {
                        throw SyncError.genesisMismatch
                    }
                }
                break
            }
            currentCID = prevCID
        }

        return WalkResult(collected: collected, cumulativeWork: cumulativeWork, tipBlock: tipBlock)
    }

    // MARK: - Full Sync

    public func syncFull(
        peerTipCID: String,
        localCumulativeWork: UInt256 = UInt256.zero,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        let walk = try await walkChain(
            from: peerTipCID, maxBlocks: nil,
            progressInterval: 500, progress: progress
        )

        if cancelled { throw SyncError.cancelled }
        guard !walk.collected.isEmpty else { throw SyncError.emptyChain }
        if walk.cumulativeWork < localCumulativeWork { throw SyncError.insufficientWork }

        var collected = walk.collected
        collected.reverse()
        let targetHeight = collected.last?.index ?? 0
        await progress?(targetHeight + 1, targetHeight + 1)

        return buildResult(from: collected, cumulativeWork: walk.cumulativeWork)
    }

    // MARK: - Snapshot Sync

    public func syncSnapshot(
        peerTipCID: String,
        depth: UInt64? = nil,
        localCumulativeWork: UInt256 = UInt256.zero,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        let effectiveDepth = depth ?? retentionDepth
        let walk = try await walkChain(
            from: peerTipCID, maxBlocks: effectiveDepth,
            progressInterval: 100, progress: progress
        )

        if cancelled { throw SyncError.cancelled }
        guard !walk.collected.isEmpty else { throw SyncError.emptyChain }
        if walk.cumulativeWork < localCumulativeWork { throw SyncError.insufficientWork }

        if let tip = walk.tipBlock {
            let valid = (try? await tip.validateFrontierState(transactionBodies: [], fetcher: fetcher)) ?? false
            if !valid {
                let fullValid = try await verifyTipFrontier(tip)
                if !fullValid { throw SyncError.invalidStateRoot(tip.index) }
            }
        }

        var collected = walk.collected
        collected.reverse()
        return buildResult(from: collected, cumulativeWork: walk.cumulativeWork)
    }

    private func verifyTipFrontier(_ block: Block) async throws -> Bool {
        guard let transactionsNode = try? await block.transactions.resolveRecursive(fetcher: fetcher).node else {
            return false
        }
        guard let txKeysAndValues = try? transactionsNode.allKeysAndValues() else {
            return false
        }
        let bodies = txKeysAndValues.values.compactMap { $0.node?.body.node }
        return try await block.validateFrontierState(transactionBodies: bodies, fetcher: fetcher)
    }

    // MARK: - Build Result

    private func buildResult(
        from blocks: [(hash: String, index: UInt64, prevHash: String?)],
        cumulativeWork: UInt256 = UInt256.zero
    ) -> SyncResult {
        let tipIndex = blocks.last!.index
        let cutoff: UInt64 = tipIndex > retentionDepth
            ? tipIndex - retentionDepth
            : 0

        var persistedBlocks: [PersistedBlockMeta] = []
        var mainChainHashes: [String] = []

        var childMap: [String: [String]] = [:]
        for entry in blocks where entry.index >= cutoff {
            if let prevHash = entry.prevHash {
                childMap[prevHash, default: []].append(entry.hash)
            }
        }

        for entry in blocks where entry.index >= cutoff {
            persistedBlocks.append(PersistedBlockMeta(
                blockHash: entry.hash,
                previousBlockHash: entry.prevHash,
                blockIndex: entry.index,
                parentChainBlocks: [:],
                childBlockHashes: childMap[entry.hash] ?? []
            ))
            mainChainHashes.append(entry.hash)
        }

        let persisted = PersistedChainState(
            chainTip: blocks.last!.hash,
            tipFrontierCID: nil,
            tipHomesteadCID: nil,
            tipSpecCID: nil,
            tipDifficulty: nil,
            tipNextDifficulty: nil,
            tipIndex: nil,
            tipTimestamp: nil,
            mainChainHashes: mainChainHashes,
            blocks: persistedBlocks,
            parentChainMap: [:],
            missingBlockHashes: []
        )

        return SyncResult(
            persisted: persisted,
            tipBlockHash: blocks.last!.hash,
            tipBlockIndex: tipIndex,
            cumulativeWork: cumulativeWork
        )
    }
}
