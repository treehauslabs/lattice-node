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
        batchSize: UInt64 = 10_000
    ) {
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.identity = identity
        self.childContextProvider = childContextProvider ?? { childContexts }
        self.batchSize = batchSize
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
                let targetDifficulty = previousBlock.nextDifficulty
                let batchSize = self.batchSize
                let workerCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)

                while mining && !Task.isCancelled {
                    let currentTip = await chainState.getMainChainTip()
                    if currentTip != previousBlockHash { break }

                    let foundNonce = await mineParallel(
                        prefixBytes: prefixBytes,
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
        prefixBytes: ContiguousArray<UInt8>,
        targetDifficulty: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        let end = startNonce &+ count
        var nonce = startNonce
        let prefixLen = prefixBytes.count

        // Working buffer: prefix + max 20 digits for UInt64
        var buffer = prefixBytes
        buffer.reserveCapacity(prefixLen + 20)

        // Scratch space for nonce→ASCII conversion (digits in reverse)
        var digitBuf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

        while nonce < end {
            // Check cancellation every 1024 nonces (cheap bitwise check)
            if nonce & 0x3FF == 0 && Task.isCancelled { return nil }

            // Reset buffer to prefix length
            buffer.removeSubrange(prefixLen...)

            // Convert nonce to ASCII digits without String allocation
            var n = nonce
            var digitCount = 0
            if n == 0 {
                buffer.append(0x30) // '0'
            } else {
                withUnsafeMutablePointer(to: &digitBuf) { ptr in
                    let digits = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
                    while n > 0 {
                        digits[digitCount] = UInt8(0x30 &+ (n % 10))
                        n /= 10
                        digitCount &+= 1
                    }
                    // Append digits in reverse order
                    var i = digitCount &- 1
                    while i >= 0 {
                        buffer.append(digits[i])
                        i &-= 1
                    }
                }
            }

            // SHA-256 → UInt256 without intermediate Data allocations
            let hash: UInt256 = buffer.withUnsafeBufferPointer { ptr in
                var hasher = SHA256()
                hasher.update(bufferPointer: UnsafeRawBufferPointer(ptr))
                let digest = hasher.finalize()
                return digest.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: UInt64.self)
                    return UInt256([
                        UInt64(bigEndian: p[0]),
                        UInt64(bigEndian: p[1]),
                        UInt64(bigEndian: p[2]),
                        UInt64(bigEndian: p[3])
                    ])
                }
            }

            if targetDifficulty >= hash {
                return nonce
            }
            nonce &+= 1
        }
        return nil
    }

    private func mineParallel(
        prefixBytes: ContiguousArray<UInt8>,
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
                    self.mineBatch(
                        prefixBytes: prefixBytes,
                        targetDifficulty: targetDifficulty,
                        startNonce: startNonce,
                        count: rangePerWorker
                    )
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
        var blocks: [String: Block] = [:]
        var pendingRemovals: [(mempool: NodeMempool, txCIDs: Set<String>)] = []

        for ctx in contexts {
            do {
                let childTipHash = await ctx.chainState.getMainChainTip()
                let childTipData = try await ctx.fetcher.fetch(rawCid: childTipHash)
                guard let childTip = Block(data: childTipData) else { continue }

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
                blocks[ctx.directory] = childBlock
                let cids = Set(childTxs.map { $0.body.rawCID })
                if !cids.isEmpty {
                    pendingRemovals.append((mempool: ctx.mempool, txCIDs: cids))
                }
            } catch {
                continue
            }
        }
        return ChildBlockResult(blocks: blocks, pendingChildTxRemovals: pendingRemovals)
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
