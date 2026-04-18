import Lattice
import Foundation
import cashew
import Crypto
import UInt256

public actor MinerLoop {
    private let chainState: ChainState
    private let mempool: NodeMempool
    private let fetcher: Fetcher
    private let spec: ChainSpec
    private let identity: MinerIdentity?
    private let childContextProvider: (@Sendable () async -> [ChildMiningContext])?
    private let batchSize: UInt64
    private let tipCache: TipCache?
    private var mining: Bool
    private var currentTask: Task<Void, Never>?
    private var nonceOffset: UInt64 = 0
    public weak var delegate: MinerDelegate?

    public init(
        chainState: ChainState,
        mempool: NodeMempool,
        fetcher: Fetcher,
        spec: ChainSpec,
        identity: MinerIdentity? = nil,
        childContexts: [ChildMiningContext] = [],
        childContextProvider: (@Sendable () async -> [ChildMiningContext])? = nil,
        batchSize: UInt64 = 10_000,
        tipCache: TipCache? = nil
    ) {
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.identity = identity
        self.childContextProvider = childContextProvider ?? { childContexts }
        self.batchSize = batchSize
        self.tipCache = tipCache
        self.mining = false
    }

    public var isMining: Bool { mining }

    public func start() {
        guard !mining else { return }
        mining = true
        NodeLogger("miner").info("Starting miner on \(spec.directory) (batchSize=\(batchSize))")
        currentTask = Task { [weak self] in
            await self?.mineLoop()
        }
    }

    public func stop() {
        mining = false
        currentTask?.cancel()
        currentTask = nil
    }

    private func mineLoop() async {
        let log = NodeLogger("miner")
        log.info("\(spec.directory): mineLoop entered, starting mining iterations")
        while mining && !Task.isCancelled {
            do {
                let previousBlock = try await resolveCurrentTip()
                guard let previousBlock = previousBlock else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                let previousBlockHash = VolumeImpl<Block>(node: previousBlock).rawCID
                let blockTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
                log.info("\(spec.directory): mining on tip \(String(previousBlockHash.prefix(16)))… at index \(previousBlock.index), building block \(previousBlock.index + 1)")

                let maxTxCount = Int(spec.maxNumberOfTransactionsPerBlock) - 1 // reserve slot for coinbase
                async let txAsync = mempool.selectTransactions(maxCount: max(0, maxTxCount))
                let currentChildContexts = await childContextProvider?() ?? []

                var transactions = await txAsync

                // Build child blocks in parallel, coinbase sequentially (depends on transactions)
                async let childResultAsync = buildChildBlocks(
                    contexts: currentChildContexts,
                    nexusBlock: previousBlock, timestamp: blockTimestamp
                )
                do {
                    if let coinbase = try await buildCoinbaseTransaction(
                        previousBlock: previousBlock,
                        mempoolTransactions: transactions
                    ) {
                        // Coinbase goes AFTER user txs so its nonce doesn't
                        // collide with miner-signed mempool transactions.
                        transactions.append(coinbase)
                    }
                } catch {
                    NodeLogger("miner").warn("Coinbase build failed: \(error)")
                }
                let childResult = await childResultAsync
                let blockDifficulty = max(previousBlock.nextDifficulty, ChainSpec.minimumDifficulty)
                let nextBlockIndex = previousBlock.index + 1
                let computedNextDifficulty: UInt256
                if spec.isEpochBoundary(blockIndex: nextBlockIndex) {
                    let ancestorTimestamps = await Self.collectAncestorTimestamps(
                        from: previousBlock, count: spec.difficultyAdjustmentWindow, fetcher: fetcher
                    )
                    let windowTimestamps = [blockTimestamp] + ancestorTimestamps
                    computedNextDifficulty = spec.calculateWindowedDifficulty(
                        previousDifficulty: blockDifficulty,
                        ancestorTimestamps: windowTimestamps
                    )
                } else {
                    computedNextDifficulty = blockDifficulty
                }
                // Use a composite fetcher so nexus block building can resolve
                // CIDs that live in child CAS stores (e.g. during receipt
                // deletion when processing child withdrawals).
                let blockFetcher: Fetcher
                if !currentChildContexts.isEmpty {
                    blockFetcher = CompositeFetcher(
                        primary: fetcher,
                        fallbacks: currentChildContexts.map { $0.fetcher }
                    )
                } else {
                    blockFetcher = fetcher
                }
                let template: Block
                do {
                    template = try await BlockBuilder.buildBlock(
                        previous: previousBlock,
                        transactions: transactions,
                        childBlocks: childResult.blocks,
                        timestamp: blockTimestamp,
                        difficulty: blockDifficulty,
                        nextDifficulty: computedNextDifficulty,
                        nonce: 0,
                        fetcher: blockFetcher
                    )
                } catch StateErrors.nonceGap {
                    log.warn("\(spec.directory): nonceGap building block \(nextBlockIndex), falling back to empty block")
                    let staleCIDs = Set(transactions.map { $0.body.rawCID })
                    if !staleCIDs.isEmpty { await mempool.removeAll(txCIDs: staleCIDs) }
                    transactions = []
                    template = try await BlockBuilder.buildBlock(
                        previous: previousBlock,
                        transactions: [],
                        childBlocks: childResult.blocks,
                        timestamp: blockTimestamp,
                        difficulty: blockDifficulty,
                        nextDifficulty: computedNextDifficulty,
                        nonce: 0,
                        fetcher: blockFetcher
                    )
                }

                let prefixBytes = difficultyHashPrefixBytes(template)
                // Precompute SHA256 midstate for the fixed prefix — each nonce attempt
                // clones this state and hashes only the 1-20 nonce digits instead of
                // re-processing ~400-500 prefix bytes (~6-7 SHA256 blocks saved per nonce)
                let midstate: SHA256 = prefixBytes.withUnsafeBufferPointer { ptr in
                    var h = SHA256()
                    h.update(bufferPointer: UnsafeRawBufferPointer(ptr))
                    return h
                }
                let targetDifficulty = max(previousBlock.nextDifficulty, ChainSpec.minimumDifficulty)
                let batchSize = self.batchSize
                let workerCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
                log.info("\(spec.directory): nonce search started for block \(previousBlock.index + 1) (difficulty=\(String(targetDifficulty.toHexString().prefix(16)))… workers=\(workerCount) batch=\(batchSize))")

                while mining && !Task.isCancelled {
                    // Lock-free tip check avoids actor hop into ChainState per batch
                    let currentTip: String
                    if let cached = tipCache?.tip {
                        currentTip = cached
                    } else {
                        currentTip = await chainState.getMainChainTip()
                    }
                    if currentTip != previousBlockHash { break }

                    let foundNonce = await mineParallel(
                        midstate: midstate,
                        targetDifficulty: targetDifficulty,
                        totalBatchSize: batchSize,
                        workerCount: workerCount,
                        nonceOffset: nonceOffset
                    )

                    if let foundNonce {
                        let mined = withNonce(template, startNonce: foundNonce)

                        let confirmedCIDs = Set(transactions.map { $0.body.rawCID })
                        let pendingRemovals = MinedBlockPendingRemovals(
                            nexusTxCIDs: confirmedCIDs,
                            childTxRemovals: childResult.pendingChildTxRemovals.map {
                                (directory: "", mempool: $0.mempool, txCIDs: $0.txCIDs)
                            }
                        )

                        let hash = VolumeImpl<Block>(node: mined).rawCID
                        log.info("\(spec.directory): found valid nonce \(foundNonce) for block \(mined.index), submitting \(String(hash.prefix(16)))…")
                        await delegate?.minerDidProduceBlock(mined, hash: hash, pendingRemovals: pendingRemovals)
                        break
                    }

                    nonceOffset &+= batchSize
                    await Task.yield()
                }
            } catch {
                let log = NodeLogger("miner")
                let tip = await chainState.getMainChainTip()
                log.error("mineLoop failed: \(error) (tip=\(String(tip.prefix(16)))…)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func difficultyHashPrefixBytes(_ block: Block) -> ContiguousArray<UInt8> {
        let sep: UInt8 = 0x00
        var bytes = ContiguousArray<UInt8>()
        bytes.reserveCapacity(512)
        if let previousBlockCID = block.previousBlock?.rawCID {
            bytes.append(contentsOf: previousBlockCID.utf8)
        }
        bytes.append(sep)
        bytes.append(contentsOf: block.transactions.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.difficulty.toHexString().utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.nextDifficulty.toHexString().utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.spec.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.parentHomestead.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.homestead.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.frontier.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: block.childBlocks.rawCID.utf8)
        bytes.append(sep)
        bytes.append(contentsOf: String(block.index).utf8)
        bytes.append(sep)
        bytes.append(contentsOf: String(block.timestamp).utf8)
        bytes.append(sep)
        return bytes
    }

    nonisolated private func mineBatch(
        midstate: SHA256,
        targetDifficulty: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        mineBatchFree(midstate: midstate, targetDifficulty: targetDifficulty, startNonce: startNonce, count: count)
    }

    nonisolated private func mineParallel(
        midstate: SHA256,
        targetDifficulty: UInt256,
        totalBatchSize: UInt64,
        workerCount: Int,
        nonceOffset: UInt64
    ) async -> UInt64? {
        let rangePerWorker = totalBatchSize / UInt64(workerCount)

        // Wrap in Sendable box to satisfy strict concurrency
        let box = SendableMineArgs(midstate: midstate, targetDifficulty: targetDifficulty, rangePerWorker: rangePerWorker)

        return await withTaskGroup(of: UInt64?.self) { group in
            for i in 0..<workerCount {
                let startNonce = nonceOffset &+ UInt64(i) &* rangePerWorker
                group.addTask {
                    mineBatchFree(midstate: box.midstate, targetDifficulty: box.targetDifficulty, startNonce: startNonce, count: box.rangePerWorker)
                }
            }
            for await result in group {
                if let nonce = result {
                    group.cancelAll()
                    return nonce
                }
            }
            return nil
        }
    }

    // MARK: - Coinbase Transaction

    /// Resolve the miner's latest transaction nonce from the previous block's state.
    /// Returns nil when the state can't be read or no nonce exists yet.
    private func resolveLatestMinerNonce(previousBlock: Block) async -> UInt64? {
        guard let identity = identity else { return nil }
        // Step 1: resolve frontier to get LatticeState
        guard let frontierNode = try? await previousBlock.frontier.resolve(fetcher: fetcher).node else { return nil }
        // Step 2: resolve nonce key in the transaction state
        let nonceKey = "_nonce_" + identity.address
        let txState = frontierNode.transactionState
        guard let resolvedTx = try? await txState.resolve(
            paths: [[nonceKey]: .targeted],
            fetcher: fetcher
        ) else { return nil }
        guard let txNode = resolvedTx.node,
              let nonceStr: String = try? txNode.get(key: nonceKey),
              let nonce = UInt64(nonceStr) else { return nil }
        return nonce
    }

    private func buildCoinbaseTransaction(
        previousBlock: Block,
        mempoolTransactions: [Transaction]
    ) async throws -> Transaction? {
        guard let identity = identity else { return nil }

        let reward = spec.rewardAtBlock(previousBlock.index + 1)
        var totalFees: UInt64 = 0
        for tx in mempoolTransactions {
            guard let fee = tx.body.node?.fee else { continue }
            let (newTotal, overflow) = totalFees.addingReportingOverflow(fee)
            if overflow { return nil }
            totalFees = newTotal
        }
        let (payout, payoutOverflow) = reward.addingReportingOverflow(totalFees)
        if payoutOverflow { return nil }
        guard payout > 0 && payout <= UInt64(Int64.max) else { return nil }

        // Coinbase nonce must follow the miner's latest nonce in the state
        // PLUS any miner-signed mempool txs that precede the coinbase in the block.
        let latestNonce = await resolveLatestMinerNonce(previousBlock: previousBlock)
        let minerTxsInBlock = mempoolTransactions.filter { tx in
            tx.body.node?.signers.contains(identity.address) == true
        }.count
        let coinbaseNonce: UInt64
        if let latest = latestNonce {
            coinbaseNonce = latest + 1 + UInt64(minerTxsInBlock)
        } else {
            // Genesis or first block — no prior nonce
            coinbaseNonce = (previousBlock.index == 0 ? 0 : previousBlock.index) + UInt64(minerTxsInBlock)
        }

        let accountAction = AccountAction(
            owner: identity.address,
            delta: Int64(payout)
        )

        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [identity.address],
            fee: 0,
            nonce: coinbaseNonce,
            chainPath: [spec.directory]
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)

        guard let signature = CryptoUtils.sign(
            message: bodyHeader.rawCID,
            privateKeyHex: identity.privateKeyHex
        ) else { return nil }

        return Transaction(
            signatures: [identity.publicKeyHex: signature],
            body: bodyHeader
        )
    }

    // MARK: - Child Block Building (Merged Mining)

    private struct ChildBlockResult {
        let blocks: [String: Block]
        let pendingChildTxRemovals: [(mempool: NodeMempool, txCIDs: Set<String>)]
    }

    private func buildChildBlocks(contexts: [ChildMiningContext], nexusBlock: Block, timestamp: Int64) async -> ChildBlockResult {
        guard !contexts.isEmpty else {
            return ChildBlockResult(blocks: [:], pendingChildTxRemovals: [])
        }

        // Build all child blocks in parallel — they're independent
        return await withTaskGroup(of: (String, Block, NodeMempool, Set<String>)?.self) { group in
            for ctx in contexts {
                group.addTask {
                    do {
                        let childTipHash = await ctx.chainState.getMainChainTip()
                        let childTipData = try await ctx.fetcher.fetch(rawCid: childTipHash)
                        guard let childTipRaw = Block(data: childTipData) else { return nil }
                        // Resolve properties inherited by the new child block so they
                        // get stored in the nexus CAS via storeRecursively. Without
                        // this, CID-only references from the child CAS are skipped and
                        // nexus-side child block validation can't resolve them.
                        let childTip = childTipRaw.set(properties: [
                            "spec": try await childTipRaw.spec.resolve(fetcher: ctx.fetcher),
                            "frontier": try await childTipRaw.frontier.resolve(fetcher: ctx.fetcher),
                        ])

                        let childTxs = await ctx.mempool.selectTransactions(
                            maxCount: max(0, Int(ctx.spec.maxNumberOfTransactionsPerBlock) - 1)
                        )

                        let childDifficulty = max(childTip.nextDifficulty, ChainSpec.minimumDifficulty)
                        let childAncestorTs = await Self.collectAncestorTimestamps(
                            from: childTip, count: ctx.spec.difficultyAdjustmentWindow, fetcher: ctx.fetcher
                        )
                        let childWindowTs = [timestamp] + childAncestorTs
                        let childNextDifficulty = ctx.spec.calculateWindowedDifficulty(
                            previousDifficulty: childDifficulty,
                            ancestorTimestamps: childWindowTs
                        )

                        // The child block's parentHomestead must match the
                        // CURRENT nexus block's homestead (= previous nexus
                        // block's frontier). BlockBuilder uses
                        // parentChainBlock.homestead, so adjust accordingly.
                        let parentForChild = nexusBlock.set(properties: [
                            "homestead": nexusBlock.frontier
                        ])
                        let childBlock = try await BlockBuilder.buildBlock(
                            previous: childTip,
                            transactions: childTxs,
                            parentChainBlock: parentForChild,
                            timestamp: timestamp,
                            difficulty: childDifficulty,
                            nextDifficulty: childNextDifficulty,
                            nonce: 0,
                            fetcher: ctx.fetcher
                        )
                        let cids = Set(childTxs.map { $0.body.rawCID })
                        return (ctx.directory, childBlock, ctx.mempool, cids)
                    } catch {
                        NodeLogger("child-block-builder").error("Failed to build child block for \(ctx.directory): \(error)")
                        return nil
                    }
                }
            }

            var blocks: [String: Block] = [:]
            var pendingRemovals: [(mempool: NodeMempool, txCIDs: Set<String>)] = []
            for await result in group {
                guard let (dir, block, mempool, cids) = result else { continue }
                blocks[dir] = block
                if !cids.isEmpty {
                    pendingRemovals.append((mempool: mempool, txCIDs: cids))
                }
            }
            return ChildBlockResult(blocks: blocks, pendingChildTxRemovals: pendingRemovals)
        }
    }

    // MARK: - Helpers

    private static func collectAncestorTimestamps(from block: Block, count: UInt64, fetcher: Fetcher) async -> [Int64] {
        var timestamps: [Int64] = [block.timestamp]
        var current = block
        for _ in 1..<count {
            guard let prev = try? await current.previousBlock?.resolve(fetcher: fetcher).node else { break }
            timestamps.append(prev.timestamp)
            current = prev
        }
        return timestamps
    }

    private func resolveCurrentTip() async throws -> Block? {
        let tipHash = await chainState.getMainChainTip()
        let tipData = try await fetcher.fetch(rawCid: tipHash)
        guard let block = Block(data: tipData) else {
            NodeLogger("miner").warn("Tip block decode failed for \(String(tipHash.prefix(16)))… (\(tipData.count) bytes)")
            return nil
        }
        return block
    }

    private func withNonce(_ block: Block, startNonce: UInt64) -> Block {
        Block(
            version: block.version,
            previousBlock: block.previousBlock,
            transactions: block.transactions,
            difficulty: block.difficulty,
            nextDifficulty: block.nextDifficulty,
            spec: block.spec,
            parentHomestead: block.parentHomestead,
            homestead: block.homestead,
            frontier: block.frontier,
            childBlocks: block.childBlocks,
            index: block.index,
            timestamp: block.timestamp,
            nonce: startNonce
        )
    }
}

// Sendable wrapper for mining arguments that cross task boundaries.
private struct SendableMineArgs: @unchecked Sendable {
    let midstate: SHA256
    let targetDifficulty: UInt256
    let rangePerWorker: UInt64
}

// Free function for parallel mining — outside the actor so addTask closures don't capture self.
private func mineBatchFree(
    midstate: SHA256,
    targetDifficulty: UInt256,
    startNonce: UInt64,
    count: UInt64
) -> UInt64? {
    let end = startNonce &+ count
    var nonce = startNonce

    var nonceBuf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    while nonce < end {
        if nonce & 0x3FF == 0 && Task.isCancelled { return nil }

        var nonceLen = 0
        if nonce == 0 {
            nonceBuf.0 = 0x30
            nonceLen = 1
        } else {
            var n = nonce
            var digitCount = 0
            withUnsafeMutablePointer(to: &nonceBuf) { ptr in
                let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                while n > 0 {
                    buf[digitCount] = UInt8(0x30 &+ (n % 10))
                    n /= 10
                    digitCount &+= 1
                }
                var lo = 0; var hi = digitCount &- 1
                while lo < hi {
                    let tmp = buf[lo]; buf[lo] = buf[hi]; buf[hi] = tmp
                    lo &+= 1; hi &-= 1
                }
            }
            nonceLen = digitCount
        }

        var hasher = midstate
        withUnsafePointer(to: &nonceBuf) { ptr in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: UnsafeRawPointer(ptr), count: nonceLen
            ))
        }
        let digest = hasher.finalize()
        let hash: UInt256 = digest.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            return UInt256([
                UInt64(bigEndian: p[0]),
                UInt64(bigEndian: p[1]),
                UInt64(bigEndian: p[2]),
                UInt64(bigEndian: p[3])
            ])
        }

        if targetDifficulty >= hash { return nonce }
        nonce &+= 1
    }
    return nil
}
