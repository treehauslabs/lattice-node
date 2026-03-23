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

    // MARK: - Full Sync
    //
    // Walk backwards from peer tip to genesis, fetching every block,
    // validating proof-of-work, and storing block data locally.
    // Then build ChainState metadata from the collected chain.
    // This is complete but slow — O(n) sequential fetches for n blocks.

    private static func workForDifficulty(_ difficulty: UInt256) -> UInt256 {
        guard difficulty > UInt256.zero else { return UInt256.zero }
        return UInt256.max / difficulty
    }

    public func syncFull(
        peerTipCID: String,
        localCumulativeWork: UInt256 = UInt256.zero,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        var collected: [(hash: String, index: UInt64, prevHash: String?)] = []
        var currentCID = peerTipCID
        var targetHeight: UInt64 = 0
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
            }

            let diffHash = block.getDifficultyHash()
            guard block.validateBlockDifficulty(nexusHash: diffHash) else {
                throw SyncError.invalidPoW(block.index)
            }

            cumulativeWork = cumulativeWork &+ Self.workForDifficulty(block.difficulty)

            await storeFn(currentCID, data)
            collected.append((
                hash: currentCID,
                index: block.index,
                prevHash: block.previousBlock?.rawCID
            ))

            if collected.count % 500 == 0 {
                await progress?(UInt64(collected.count), targetHeight + 1)
            }

            guard let prevCID = block.previousBlock?.rawCID else {
                guard currentCID == genesisBlockHash else {
                    throw SyncError.genesisMismatch
                }
                break
            }
            currentCID = prevCID
        }

        if cancelled { throw SyncError.cancelled }
        guard !collected.isEmpty else { throw SyncError.emptyChain }

        if cumulativeWork < localCumulativeWork {
            throw SyncError.insufficientWork
        }

        collected.reverse()
        await progress?(targetHeight + 1, targetHeight + 1)

        return buildResult(from: collected, cumulativeWork: cumulativeWork)
    }

    // MARK: - Snapshot Sync
    //
    // Walk backwards from peer tip for `depth` blocks only.
    // Validates PoW on downloaded blocks and verifies the tip
    // block's frontier state root by re-deriving it from the
    // homestead + transactions. Much faster than full sync — the
    // node can start operating quickly, fetching historical state
    // lazily from peers as needed.

    public func syncSnapshot(
        peerTipCID: String,
        depth: UInt64? = nil,
        localCumulativeWork: UInt256 = UInt256.zero,
        progress: (@Sendable (UInt64, UInt64) async -> Void)? = nil
    ) async throws -> SyncResult {
        let effectiveDepth = depth ?? retentionDepth
        var collected: [(hash: String, index: UInt64, prevHash: String?)] = []
        var currentCID = peerTipCID
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
            collected.append((
                hash: currentCID,
                index: block.index,
                prevHash: block.previousBlock?.rawCID
            ))

            if collected.count % 100 == 0 {
                let target = min(effectiveDepth, targetHeight + 1)
                await progress?(UInt64(collected.count), target)
            }

            if UInt64(collected.count) >= effectiveDepth {
                break
            }

            guard let prevCID = block.previousBlock?.rawCID else {
                break
            }
            currentCID = prevCID
        }

        if cancelled { throw SyncError.cancelled }
        guard !collected.isEmpty else { throw SyncError.emptyChain }

        if cumulativeWork < localCumulativeWork {
            throw SyncError.insufficientWork
        }

        if let tip = tipBlock {
            let valid = (try? await tip.validateFrontierState(transactionBodies: [], fetcher: fetcher)) ?? false
            if !valid {
                let fullValid = try await verifyTipFrontier(tip)
                if !fullValid {
                    throw SyncError.invalidStateRoot(tip.index)
                }
            }
        }

        collected.reverse()

        return buildResult(from: collected, cumulativeWork: cumulativeWork)
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
