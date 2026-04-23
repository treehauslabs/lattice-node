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
    /// Full nexus-to-this-chain path, e.g. `["Nexus"]` when mining the nexus.
    /// Required for coinbase `chainPath`, which `validateChainPaths` compares
    /// against the full expected path — `spec.directory` alone is only the
    /// last segment and isn't valid on anything below the nexus.
    private let chainPath: [String]
    private let identity: MinerIdentity?
    private let childContextProvider: (@Sendable () async -> [ChildMiningContext])?
    private let batchSize: UInt64
    private let tipCache: TipCache?
    private var mining: Bool
    private var currentTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastBlockAt: ContinuousClock.Instant = .now
    private var isSubmitting: Bool = false
    private var submitStartedAt: ContinuousClock.Instant = .now
    private var nonceOffset: UInt64 = 0
    // Cache of the last-mined block with its frontier LatticeState still
    // resolved in memory. When the next iteration's tip matches this CID, we
    // reuse the cached block instead of re-fetching + re-resolving the entire
    // frontier, which is O(state_size). Without this cache, every iteration
    // re-resolves the full state (minutes per iteration on large chains) and
    // any other actor touching the same ChainNetwork/CAS (e.g. a dashboard
    // RPC) competes for the same actor time and stalls mining visibly.
    private var cachedTipBlock: Block?
    private var cachedTipCID: String?
    private var cachedChildTips: [String: (cid: String, block: Block)] = [:]
    public weak var delegate: MinerDelegate?

    // Stall watchdog guards against nonce-search hangs only; it must not
    // interrupt the miner while it's awaiting minerDidProduceBlock. Slow
    // block submits (large child merkle subtree writes under swap pressure)
    // can legitimately take several minutes, and force-respawning mineLoop
    // during that window spawns concurrent iterations that each retain a
    // resolved frontier/child state, amplifying memory pressure.
    private static let stallThreshold: Duration = .seconds(300)
    private static let watchdogInterval: Duration = .seconds(30)

    public init(
        chainState: ChainState,
        mempool: NodeMempool,
        fetcher: Fetcher,
        spec: ChainSpec,
        chainPath: [String],
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
        self.chainPath = chainPath
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
        lastBlockAt = .now
        NodeLogger("miner").info("Starting miner on \(spec.directory) (batchSize=\(batchSize))")
        spawnMineTask()
        watchdogTask = Task { [weak self] in
            await self?.watchdogLoop()
        }
    }

    public func stop() async {
        mining = false
        let task = currentTask
        let watchdog = watchdogTask
        currentTask = nil
        watchdogTask = nil
        task?.cancel()
        watchdog?.cancel()
        // Await the mine task so any in-flight block submission fully commits
        // to chain + store before stop() returns. Without this, callers that
        // submit transactions right after stop() can race an applying block
        // and read a stale nonce from StateStore, triggering nonceGap when
        // the tx is later included.
        await task?.value
        await watchdog?.value
        cachedTipBlock = nil
        cachedTipCID = nil
        cachedChildTips.removeAll()
    }

    private func spawnMineTask() {
        currentTask = Task { [weak self] in
            await self?.runMineLoopWithRespawn()
        }
    }

    private func runMineLoopWithRespawn() async {
        while mining && !Task.isCancelled {
            await mineLoop()
            if mining && !Task.isCancelled {
                NodeLogger("miner").warn("\(spec.directory): mineLoop exited unexpectedly; respawning in 1s")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func watchdogLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.watchdogInterval)
            guard mining, !Task.isCancelled else { return }
            // Skip restart if the miner is inside block submission. Canceling
            // the task doesn't cancel the in-flight actor await — it only
            // lets a NEW mineLoop start, which then does its own resolves
            // and retains memory concurrently with the stalled submit.
            if isSubmitting {
                let submitElapsed = Int((ContinuousClock.now - submitStartedAt) / .seconds(1))
                NodeLogger("miner").info("\(spec.directory): watchdog tick — submit in flight for \(submitElapsed)s, skipping restart")
                continue
            }
            let elapsed = ContinuousClock.now - lastBlockAt
            if elapsed > Self.stallThreshold {
                let secs = Int(elapsed / .seconds(1))
                NodeLogger("miner").warn("\(spec.directory): stall watchdog — no block produced in \(secs)s and not submitting, force-restarting mineLoop")
                currentTask?.cancel()
                lastBlockAt = .now
                spawnMineTask()
            }
        }
    }

    private func beginSubmit() {
        isSubmitting = true
        submitStartedAt = .now
    }

    private func endSubmit() {
        isSubmitting = false
    }

    private func recordBlockProduced() {
        lastBlockAt = .now
    }

    private func mineLoop() async {
        let log = NodeLogger("miner")
        log.info("\(spec.directory): mineLoop entered, starting mining iterations")
        while mining && !Task.isCancelled {
            do {
                let tIter = ContinuousClock.now
                let tResolveTip = ContinuousClock.now
                let previousBlock = try await resolveCurrentTip()
                guard let previousBlock = previousBlock else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }
                let dResolveTip = ContinuousClock.now - tResolveTip

                let previousBlockHash = VolumeImpl<Block>(node: previousBlock).rawCID
                let blockTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
                log.info("\(spec.directory): mining on tip \(String(previousBlockHash.prefix(16)))… at index \(previousBlock.index), building block \(previousBlock.index + 1)")

                let tSelectTxs = ContinuousClock.now
                let maxTxCount = Int(spec.maxNumberOfTransactionsPerBlock) - 1 // reserve slot for coinbase
                async let txAsync = mempool.selectTransactions(maxCount: max(0, maxTxCount))
                let currentChildContexts = await childContextProvider?() ?? []

                var transactions = await txAsync
                let dSelectTxs = ContinuousClock.now - tSelectTxs

                // Build child blocks in parallel, coinbase sequentially (depends on transactions)
                let tBuildChildren = ContinuousClock.now
                async let childResultAsync = buildChildBlocks(
                    contexts: currentChildContexts,
                    nexusBlock: previousBlock, timestamp: blockTimestamp
                )
                let tCoinbase = ContinuousClock.now
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
                let dCoinbase = ContinuousClock.now - tCoinbase
                let childResult = await childResultAsync
                let dBuildChildren = ContinuousClock.now - tBuildChildren
                let tDifficulty = ContinuousClock.now
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
                let dDifficulty = ContinuousClock.now - tDifficulty
                // Use a composite fetcher so nexus block building can resolve
                // CIDs that live in child CAS stores (e.g. during receipt
                // deletion when processing child withdrawals).
                let blockFetcher: Fetcher
                if !currentChildContexts.isEmpty {
                    blockFetcher = CompositeFetcher(
                        primary: fetcher,
                        fallbacks: Self.flattenFetchers(currentChildContexts)
                    )
                } else {
                    blockFetcher = fetcher
                }
                let tBuildTemplate = ContinuousClock.now
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
                let dBuildTemplate = ContinuousClock.now - tBuildTemplate

                let tMidstate = ContinuousClock.now
                let prefixBytes = difficultyHashPrefixBytes(template)
                // Precompute SHA256 midstate for the fixed prefix — each nonce attempt
                // clones this state and hashes only the 1-20 nonce digits instead of
                // re-processing ~400-500 prefix bytes (~6-7 SHA256 blocks saved per nonce)
                let midstate: SHA256 = prefixBytes.withUnsafeBufferPointer { ptr in
                    var h = SHA256()
                    h.update(bufferPointer: UnsafeRawBufferPointer(ptr))
                    return h
                }
                let dMidstate = ContinuousClock.now - tMidstate
                // Merged-mining target: search with the EASIEST target across
                // the entire registered chain tree (nexus + all descendants).
                // The first nonce that satisfies this max target might only
                // pass a child/grandchild's PoW — the lattice acceptance path
                // handles that by validating difficulty per level.
                let targetDifficulty = max(
                    max(previousBlock.nextDifficulty, ChainSpec.minimumDifficulty),
                    childResult.maxSubtreeDifficulty
                )
                let batchSize = self.batchSize
                let workerCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
                log.info("\(spec.directory): nonce search started for block \(previousBlock.index + 1) (difficulty=\(String(targetDifficulty.toHexString().prefix(16)))… workers=\(workerCount) batch=\(batchSize))")

                let dPrepIter = ContinuousClock.now - tIter
                print("[TIMING] mineIter \(spec.directory) #\(nextBlockIndex) txs=\(transactions.count) children=\(childResult.blocks.count) prep=\(dPrepIter) resolveTip=\(dResolveTip) selectTxs=\(dSelectTxs) buildChildren=\(dBuildChildren) coinbase=\(dCoinbase) difficulty=\(dDifficulty) buildTemplate=\(dBuildTemplate) midstate=\(dMidstate)")

                let tPoW = ContinuousClock.now
                var batchCount = 0
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
                    batchCount += 1

                    if let foundNonce {
                        let dPoW = ContinuousClock.now - tPoW
                        let tSubmit = ContinuousClock.now
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
                        beginSubmit()
                        await delegate?.minerDidProduceBlock(mined, hash: hash, pendingRemovals: pendingRemovals)
                        endSubmit()
                        recordBlockProduced()
                        // Cache the fully-resolved mined block (frontier.node is
                        // populated from BlockBuilder) so the next iteration's
                        // resolveCurrentTip returns it directly and BlockBuilder
                        // can skip the homestead resolve. Child blocks cached
                        // analogously for their respective chains.
                        cachedTipBlock = mined
                        cachedTipCID = hash
                        for (dir, childBlock) in childResult.allBlocksByDirectory {
                            let childCID = VolumeImpl<Block>(node: childBlock).rawCID
                            cachedChildTips[dir] = (cid: childCID, block: childBlock)
                        }
                        let dSubmit = ContinuousClock.now - tSubmit
                        let dIterTotal = ContinuousClock.now - tIter
                        let hashesAttempted = UInt64(batchCount) * batchSize
                        print("[TIMING] mineFound \(spec.directory) #\(mined.index) total=\(dIterTotal) prep=\(dPrepIter) pow=\(dPoW) submit=\(dSubmit) batches=\(batchCount) hashes=\(hashesAttempted)")
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
    private static func resolveLatestMinerNonce(
        previousBlock: Block,
        identity: MinerIdentity,
        fetcher: Fetcher
    ) async -> UInt64? {
        guard let frontierNode = try? await previousBlock.frontier.resolve(fetcher: fetcher).node else { return nil }
        let nonceKey = AccountStateHeader.nonceTrackingKey(identity.address)
        guard let resolvedAccounts = try? await frontierNode.accountState.resolve(
            paths: [[nonceKey]: .targeted],
            fetcher: fetcher
        ) else { return nil }
        guard let accountsNode = resolvedAccounts.node,
              let nonce: UInt64 = try? accountsNode.get(key: nonceKey) else { return nil }
        return nonce
    }

    /// Build a coinbase transaction that credits `identity.address` by
    /// `reward + fees` for `previousBlock.index + 1` on `spec`. Callers append
    /// this to the block's transaction list so the miner collects the block
    /// reward; child chains use the same helper with their own spec/fetcher.
    /// `chainPath` must equal the full nexus-to-chain path expected by
    /// `validateChainPaths`, e.g. `["Nexus","FastTest"]` for a FastTest coinbase.
    static func buildCoinbaseTransaction(
        spec: ChainSpec,
        identity: MinerIdentity,
        chainPath: [String],
        previousBlock: Block,
        mempoolTransactions: [Transaction],
        fetcher: Fetcher
    ) async throws -> Transaction? {
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
        let latestNonce = await resolveLatestMinerNonce(
            previousBlock: previousBlock, identity: identity, fetcher: fetcher
        )
        let minerTxsInBlock = mempoolTransactions.filter { tx in
            tx.body.node?.signers.contains(identity.address) == true
        }.count
        // TransactionState.proveAndUpdateState requires the first-ever nonce for
        // a signer to be 0, regardless of the current block index. Using
        // previousBlock.index here meant a fresh miner joining a non-genesis
        // chain always hit nonceGap and the block fell back to empty (no reward).
        let coinbaseNonce: UInt64
        if let latest = latestNonce {
            coinbaseNonce = latest + 1 + UInt64(minerTxsInBlock)
        } else {
            coinbaseNonce = UInt64(minerTxsInBlock)
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
            chainPath: chainPath
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

    private func buildCoinbaseTransaction(
        previousBlock: Block,
        mempoolTransactions: [Transaction]
    ) async throws -> Transaction? {
        guard let identity = identity else { return nil }
        return try await Self.buildCoinbaseTransaction(
            spec: spec,
            identity: identity,
            chainPath: chainPath,
            previousBlock: previousBlock,
            mempoolTransactions: mempoolTransactions,
            fetcher: fetcher
        )
    }

    // MARK: - Child Block Building (Merged Mining)

    private struct ChildBlockResult {
        /// Direct children of the nexus, keyed by directory. Grandchildren
        /// live inside each direct child's own `childBlocks`.
        let blocks: [String: Block]
        let pendingChildTxRemovals: [(mempool: NodeMempool, txCIDs: Set<String>)]
        /// The easiest (largest) target difficulty across every built block
        /// in the subtree. Callers combine this with the nexus target so the
        /// nonce search stops on whichever level's PoW passes first.
        let maxSubtreeDifficulty: UInt256
        /// Every built block across the entire subtree, keyed by directory
        /// (directory names are globally unique). Used to populate tip caches.
        let allBlocksByDirectory: [String: Block]
    }

    private struct BuiltSubtree {
        let directory: String
        let block: Block
        let difficulty: UInt256
        let removals: [(mempool: NodeMempool, txCIDs: Set<String>)]
        let maxSubtreeDifficulty: UInt256
        let allBlocksByDirectory: [String: Block]
    }

    private func buildChildBlocks(contexts: [ChildMiningContext], nexusBlock: Block, timestamp: Int64) async -> ChildBlockResult {
        guard !contexts.isEmpty else {
            return ChildBlockResult(
                blocks: [:],
                pendingChildTxRemovals: [],
                maxSubtreeDifficulty: UInt256.zero,
                allBlocksByDirectory: [:]
            )
        }

        let cachedSnapshot = cachedChildTips
        let minerIdentity = identity

        // Top-level: convert the nexus tip into the "new nexus block" representation
        // so its homestead (= tip.frontier) matches what validation will see for the
        // block currently being built. Grandchildren+ recurse with the already-built
        // provisional child block, which is already the "new block" — no further
        // transformation needed there.
        let nexusAsNewBlock = nexusBlock.set(properties: [
            "homestead": nexusBlock.frontier
        ])

        let subtrees = await withTaskGroup(of: BuiltSubtree?.self, returning: [BuiltSubtree].self) { group in
            for ctx in contexts {
                group.addTask {
                    await Self.buildSubtree(
                        ctx: ctx,
                        parentBlock: nexusAsNewBlock,
                        timestamp: timestamp,
                        cachedTips: cachedSnapshot,
                        identity: minerIdentity
                    )
                }
            }
            var results: [BuiltSubtree] = []
            for await r in group {
                if let r = r { results.append(r) }
            }
            return results
        }

        var blocks: [String: Block] = [:]
        var removals: [(mempool: NodeMempool, txCIDs: Set<String>)] = []
        var maxDifficulty: UInt256 = .zero
        var allBlocks: [String: Block] = [:]
        for subtree in subtrees {
            blocks[subtree.directory] = subtree.block
            removals.append(contentsOf: subtree.removals)
            if subtree.maxSubtreeDifficulty > maxDifficulty {
                maxDifficulty = subtree.maxSubtreeDifficulty
            }
            allBlocks.merge(subtree.allBlocksByDirectory) { _, new in new }
        }
        return ChildBlockResult(
            blocks: blocks,
            pendingChildTxRemovals: removals,
            maxSubtreeDifficulty: maxDifficulty,
            allBlocksByDirectory: allBlocks
        )
    }

    /// Recursively build a child block including its grandchildren. Each
    /// level is built against its own chain's tip and anchored to its
    /// parent chain block via `parentChainBlock`. Returns `nil` if this
    /// subtree's block cannot be built; siblings are unaffected.
    private static func buildSubtree(
        ctx: ChildMiningContext,
        parentBlock: Block,
        timestamp: Int64,
        cachedTips: [String: (cid: String, block: Block)],
        identity: MinerIdentity?
    ) async -> BuiltSubtree? {
        do {
            let childTipHash = await ctx.chainState.getMainChainTip()
            let childTip: Block
            if let cached = cachedTips[ctx.directory], cached.cid == childTipHash {
                childTip = cached.block
            } else {
                let childTipData = try await ctx.fetcher.fetch(rawCid: childTipHash)
                guard let childTipRaw = Block(data: childTipData) else { return nil }
                childTip = childTipRaw.set(properties: [
                    "spec": try await childTipRaw.spec.resolve(fetcher: ctx.fetcher),
                    "frontier": try await childTipRaw.frontier.resolve(fetcher: ctx.fetcher),
                ])
            }

            // Reserve one slot for the coinbase in the per-block tx cap.
            var childTxs = await ctx.mempool.selectTransactions(
                maxCount: max(0, Int(ctx.spec.maxNumberOfTransactionsPerBlock) - 1)
            )

            if let identity = identity {
                do {
                    if let coinbase = try await buildCoinbaseTransaction(
                        spec: ctx.spec,
                        identity: identity,
                        chainPath: ctx.chainPath,
                        previousBlock: childTip,
                        mempoolTransactions: childTxs,
                        fetcher: ctx.fetcher
                    ) {
                        childTxs.append(coinbase)
                    }
                } catch {
                    NodeLogger("miner").warn("Child coinbase build failed for \(ctx.directory): \(error)")
                }
            }

            let childDifficulty = max(childTip.nextDifficulty, ChainSpec.minimumDifficulty)
            let childNextBlockIndex = childTip.index + 1
            let childNextDifficulty: UInt256
            if ctx.spec.isEpochBoundary(blockIndex: childNextBlockIndex) {
                let ancestorTs = await collectAncestorTimestamps(
                    from: childTip, count: ctx.spec.difficultyAdjustmentWindow, fetcher: ctx.fetcher
                )
                childNextDifficulty = ctx.spec.calculateWindowedDifficulty(
                    previousDifficulty: childDifficulty,
                    ancestorTimestamps: [timestamp] + ancestorTs
                )
            } else {
                childNextDifficulty = childDifficulty
            }

            // `parentBlock` is already the representation that validation will see
            // for the block being built at the parent level: at the top level,
            // buildChildBlocks transforms nexusTip so its homestead equals the
            // new nexus block's homestead; for grandchildren+ `parentBlock` is
            // the freshly-built provisional child block, which carries the
            // correct homestead by construction. So use it directly.
            let parentForChild = parentBlock

            // Two-pass: build this child without grandchildren first to
            // determine its frontier, then rebuild with grandchildren
            // embedded (grandchildren's `parentHomestead` comes from this
            // child's homestead, which BlockBuilder derives from its own
            // `parentChainBlock.homestead`).
            var grandchildBlocks: [String: Block] = [:]
            var descendantRemovals: [(mempool: NodeMempool, txCIDs: Set<String>)] = []
            var maxDescendantDifficulty: UInt256 = .zero
            var descendantAllBlocks: [String: Block] = [:]
            let provisional: Block
            do {
                provisional = try await BlockBuilder.buildBlock(
                    previous: childTip,
                    transactions: childTxs,
                    parentChainBlock: parentForChild,
                    timestamp: timestamp,
                    difficulty: childDifficulty,
                    nextDifficulty: childNextDifficulty,
                    nonce: 0,
                    fetcher: ctx.fetcher
                )
            } catch StateErrors.nonceGap {
                // Mirror the nexus-level fallback: a stale miner-signed tx in
                // the child mempool would otherwise stall this whole subtree
                // forever, since selectTransactions keeps handing it back and
                // BlockBuilder keeps rejecting it. Evict everything we just
                // selected and retry with only the coinbase. Without this,
                // merged mining of the affected child chain halts.
                NodeLogger("child-block-builder").warn("\(ctx.directory): nonceGap building child block, evicting \(childTxs.count) stale tx(s)")
                let staleCIDs = Set(childTxs.map { $0.body.rawCID })
                if !staleCIDs.isEmpty { await ctx.mempool.removeAll(txCIDs: staleCIDs) }
                childTxs = []
                if let identity = identity {
                    if let coinbase = try? await buildCoinbaseTransaction(
                        spec: ctx.spec, identity: identity, chainPath: ctx.chainPath,
                        previousBlock: childTip, mempoolTransactions: [], fetcher: ctx.fetcher
                    ) {
                        childTxs.append(coinbase)
                    }
                }
                provisional = try await BlockBuilder.buildBlock(
                    previous: childTip,
                    transactions: childTxs,
                    parentChainBlock: parentForChild,
                    timestamp: timestamp,
                    difficulty: childDifficulty,
                    nextDifficulty: childNextDifficulty,
                    nonce: 0,
                    fetcher: ctx.fetcher
                )
            }

            if !ctx.children.isEmpty {
                let grandSubtrees = await withTaskGroup(of: BuiltSubtree?.self, returning: [BuiltSubtree].self) { group in
                    for grandctx in ctx.children {
                        group.addTask {
                            await buildSubtree(
                                ctx: grandctx,
                                parentBlock: provisional,
                                timestamp: timestamp,
                                cachedTips: cachedTips,
                                identity: identity
                            )
                        }
                    }
                    var results: [BuiltSubtree] = []
                    for await r in group {
                        if let r = r { results.append(r) }
                    }
                    return results
                }
                for grand in grandSubtrees {
                    grandchildBlocks[grand.directory] = grand.block
                    descendantRemovals.append(contentsOf: grand.removals)
                    if grand.maxSubtreeDifficulty > maxDescendantDifficulty {
                        maxDescendantDifficulty = grand.maxSubtreeDifficulty
                    }
                    descendantAllBlocks.merge(grand.allBlocksByDirectory) { _, new in new }
                }
            }

            let childBlock: Block
            if grandchildBlocks.isEmpty {
                childBlock = provisional
            } else {
                childBlock = try await BlockBuilder.buildBlock(
                    previous: childTip,
                    transactions: childTxs,
                    childBlocks: grandchildBlocks,
                    parentChainBlock: parentForChild,
                    timestamp: timestamp,
                    difficulty: childDifficulty,
                    nextDifficulty: childNextDifficulty,
                    nonce: 0,
                    fetcher: ctx.fetcher
                )
            }

            let cids = Set(childTxs.map { $0.body.rawCID })
            var allRemovals = descendantRemovals
            if !cids.isEmpty {
                allRemovals.append((mempool: ctx.mempool, txCIDs: cids))
            }
            let subtreeMax = max(childDifficulty, maxDescendantDifficulty)
            var allBlocks = descendantAllBlocks
            allBlocks[ctx.directory] = childBlock
            return BuiltSubtree(
                directory: ctx.directory,
                block: childBlock,
                difficulty: childDifficulty,
                removals: allRemovals,
                maxSubtreeDifficulty: subtreeMax,
                allBlocksByDirectory: allBlocks
            )
        } catch {
            NodeLogger("child-block-builder").error("Failed to build subtree for \(ctx.directory): \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func flattenFetchers(_ contexts: [ChildMiningContext]) -> [Fetcher] {
        var out: [Fetcher] = []
        for ctx in contexts {
            out.append(ctx.fetcher)
            out.append(contentsOf: flattenFetchers(ctx.children))
        }
        return out
    }

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
        if let cachedCID = cachedTipCID, let cachedBlock = cachedTipBlock, cachedCID == tipHash {
            return cachedBlock
        }
        // Tip changed (reorg or gossip advance) — drop stale cache
        cachedTipBlock = nil
        cachedTipCID = nil
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
