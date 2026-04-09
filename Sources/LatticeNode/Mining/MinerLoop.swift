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
        while mining && !Task.isCancelled {
            do {
                let previousBlock = try await resolveCurrentTip()
                guard let previousBlock = previousBlock else {
                    try await Task.sleep(for: .milliseconds(100))
                    continue
                }

                let previousBlockHash = HeaderImpl<Block>(node: previousBlock).rawCID

                let maxTxCount = max(0, Int(spec.maxNumberOfTransactionsPerBlock) - 1)
                var transactions = await mempool.selectTransactions(maxCount: maxTxCount)

                if let coinbase = try? await buildCoinbaseTransaction(
                    previousBlock: previousBlock,
                    mempoolTransactions: transactions
                ) {
                    transactions.insert(coinbase, at: 0)
                }

                let blockTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
                let currentChildContexts = await childContextProvider?() ?? []
                let childResult = await buildChildBlocks(
                    contexts: currentChildContexts,
                    nexusBlock: previousBlock, timestamp: blockTimestamp
                )
                let blockDifficulty = previousBlock.nextDifficulty
                let computedNextDifficulty = spec.calculateMinimumDifficulty(
                    previousDifficulty: blockDifficulty,
                    blockTimestamp: blockTimestamp,
                    previousTimestamp: previousBlock.timestamp
                )
                let template = try await BlockBuilder.buildBlock(
                    previous: previousBlock,
                    transactions: transactions,
                    childBlocks: childResult.blocks,
                    timestamp: blockTimestamp,
                    difficulty: blockDifficulty,
                    nextDifficulty: computedNextDifficulty,
                    nonce: 0,
                    fetcher: fetcher
                )

                let prefixBytes = difficultyHashPrefixBytes(template)
                // Precompute SHA256 midstate for the fixed prefix — each nonce attempt
                // clones this state and hashes only the 1-20 nonce digits instead of
                // re-processing ~400-500 prefix bytes (~6-7 SHA256 blocks saved per nonce)
                let midstate: SHA256 = prefixBytes.withUnsafeBufferPointer { ptr in
                    var h = SHA256()
                    h.update(bufferPointer: UnsafeRawBufferPointer(ptr))
                    return h
                }
                let targetDifficulty = previousBlock.nextDifficulty
                let batchSize = self.batchSize
                let workerCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)

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
                        workerCount: workerCount
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

                        let delegate = self.delegate
                        let hash = HeaderImpl<Block>(node: mined).rawCID
                        Task.detached { await delegate?.minerDidProduceBlock(mined, hash: hash, pendingRemovals: pendingRemovals) }
                        break
                    }

                    nonceOffset &+= batchSize
                    await Task.yield()
                }
            } catch {
                print("  [miner] error: \(error)")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func difficultyHashPrefixBytes(_ block: Block) -> ContiguousArray<UInt8> {
        var bytes = ContiguousArray<UInt8>()
        bytes.reserveCapacity(512)
        if let previousBlockCID = block.previousBlock?.rawCID {
            bytes.append(contentsOf: previousBlockCID.utf8)
        }
        bytes.append(contentsOf: block.transactions.rawCID.utf8)
        bytes.append(contentsOf: block.difficulty.toHexString().utf8)
        bytes.append(contentsOf: block.nextDifficulty.toHexString().utf8)
        bytes.append(contentsOf: block.spec.rawCID.utf8)
        bytes.append(contentsOf: block.parentHomestead.rawCID.utf8)
        bytes.append(contentsOf: block.homestead.rawCID.utf8)
        bytes.append(contentsOf: block.frontier.rawCID.utf8)
        bytes.append(contentsOf: block.childBlocks.rawCID.utf8)
        bytes.append(contentsOf: String(block.index).utf8)
        bytes.append(contentsOf: String(block.timestamp).utf8)
        return bytes
    }

    nonisolated private func mineBatch(
        midstate: SHA256,
        targetDifficulty: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        let end = startNonce &+ count
        var nonce = startNonce

        // Stack buffer for nonce→ASCII digits (max 20 for UInt64.max)
        var nonceBuf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

        while nonce < end {
            if nonce & 0x3FF == 0 && Task.isCancelled { return nil }

            // Convert nonce to forward-order ASCII digits on stack
            var nonceLen = 0
            if nonce == 0 {
                nonceBuf.0 = 0x30 // '0'
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
                    // Reverse in place
                    var lo = 0
                    var hi = digitCount &- 1
                    while lo < hi {
                        let tmp = buf[lo]
                        buf[lo] = buf[hi]
                        buf[hi] = tmp
                        lo &+= 1
                        hi &-= 1
                    }
                }
                nonceLen = digitCount
            }

            // Clone midstate (copies ~112 bytes of SHA256 internal state),
            // hash only the nonce suffix, finalize
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

            if targetDifficulty >= hash {
                return nonce
            }
            nonce &+= 1
        }
        return nil
    }

    private func mineParallel(
        midstate: SHA256,
        targetDifficulty: UInt256,
        totalBatchSize: UInt64,
        workerCount: Int
    ) async -> UInt64? {
        let rangePerWorker = totalBatchSize / UInt64(workerCount)
        let baseOffset = self.nonceOffset

        return await withTaskGroup(of: UInt64?.self) { group in
            for i in 0..<workerCount {
                let startNonce = baseOffset &+ UInt64(i) &* rangePerWorker
                group.addTask {
                    mineBatchFree(midstate: midstate, targetDifficulty: targetDifficulty, startNonce: startNonce, count: rangePerWorker)
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
        guard payout > 0 else { return nil }

        let currentBalance = try await lookupBalance(
            address: identity.address,
            frontier: previousBlock.frontier
        )

        guard currentBalance <= UInt64.max - payout else { return nil }

        let accountAction = AccountAction(
            owner: identity.address,
            oldBalance: currentBalance,
            newBalance: currentBalance + payout
        )

        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [identity.address],
            fee: 0,
            nonce: previousBlock.index + 1
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

    private func lookupBalance(address: String, frontier: LatticeStateHeader) async throws -> UInt64 {
        let resolved = try await frontier.resolve(fetcher: fetcher)
        guard let state = resolved.node else { return 0 }
        let accountResolved = try await state.accountState.resolve(paths: [[address]: .targeted], fetcher: fetcher)
        guard let accountDict = accountResolved.node else { return 0 }
        guard let balance = try? accountDict.get(key: address) else { return 0 }
        return balance
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
                        guard let childTip = Block(data: childTipData) else { return nil }

                        let childTxs = await ctx.mempool.selectTransactions(
                            maxCount: max(0, Int(ctx.spec.maxNumberOfTransactionsPerBlock) - 1)
                        )

                        let childDifficulty = childTip.nextDifficulty
                        let childNextDifficulty = ctx.spec.calculateMinimumDifficulty(
                            previousDifficulty: childDifficulty,
                            blockTimestamp: timestamp,
                            previousTimestamp: childTip.timestamp
                        )

                        let childBlock = try await BlockBuilder.buildBlock(
                            previous: childTip,
                            transactions: childTxs,
                            parentChainBlock: nexusBlock,
                            timestamp: timestamp,
                            difficulty: childDifficulty,
                            nextDifficulty: childNextDifficulty,
                            nonce: 0,
                            fetcher: ctx.fetcher
                        )
                        let cids = Set(childTxs.map { $0.body.rawCID })
                        return (ctx.directory, childBlock, ctx.mempool, cids)
                    } catch {
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

    private func resolveCurrentTip() async throws -> Block? {
        let tipHash = await chainState.getMainChainTip()
        let tipData = try await fetcher.fetch(rawCid: tipHash)
        return Block(data: tipData)
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
