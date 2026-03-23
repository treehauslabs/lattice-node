import Lattice
import Foundation
import cashew
import UInt256

public actor MinerLoop {
    private let chainState: ChainState
    private let mempool: Mempool
    private let fetcher: Fetcher
    private let spec: ChainSpec
    private let identity: MinerIdentity?
    private let childContexts: [ChildMiningContext]
    private let batchSize: UInt64
    private var mining: Bool
    private var currentTask: Task<Void, Never>?
    public weak var delegate: MinerDelegate?

    public init(
        chainState: ChainState,
        mempool: Mempool,
        fetcher: Fetcher,
        spec: ChainSpec,
        identity: MinerIdentity? = nil,
        childContexts: [ChildMiningContext] = [],
        batchSize: UInt64 = 10_000
    ) {
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.identity = identity
        self.childContexts = childContexts
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

                var transactions = await mempool.selectTransactions(
                    maxCount: max(0, Int(spec.maxNumberOfTransactionsPerBlock) - 1)
                )

                if let coinbase = try? await buildCoinbaseTransaction(
                    previousBlock: previousBlock,
                    mempoolTransactions: transactions
                ) {
                    transactions.insert(coinbase, at: 0)
                }

                let childResult = await buildChildBlocks(
                    nexusBlock: previousBlock
                )

                let blockTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
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

                let hashPrefix = difficultyHashPrefix(template)
                let targetDifficulty = previousBlock.nextDifficulty
                let batchSize = self.batchSize
                var nonce: UInt64 = 0

                while mining && !Task.isCancelled {
                    let currentTip = await chainState.getMainChainTip()
                    if currentTip != previousBlockHash { break }

                    if let foundNonce = mineBatch(
                        prefix: hashPrefix,
                        targetDifficulty: targetDifficulty,
                        startNonce: nonce,
                        count: batchSize
                    ) {
                        let mined = withNonce(template, startNonce: foundNonce)

                        let confirmedCIDs = Set(transactions.map { $0.body.rawCID })
                        await mempool.removeAll(txCIDs: confirmedCIDs)

                        for removal in childResult.pendingChildTxRemovals {
                            await removal.mempool.removeAll(txCIDs: removal.txCIDs)
                        }

                        let delegate = self.delegate
                        let hash = HeaderImpl<Block>(node: mined).rawCID
                        Task.detached { await delegate?.minerDidProduceBlock(mined, hash: hash) }
                        break
                    }

                    nonce &+= batchSize
                    await Task.yield()
                }
            } catch {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func difficultyHashPrefix(_ block: Block) -> String {
        var prefix = ""
        if let previousBlockCID = block.previousBlock?.rawCID {
            prefix += previousBlockCID
        }
        prefix += block.transactions.rawCID
        prefix += block.difficulty.toHexString()
        prefix += block.nextDifficulty.toHexString()
        prefix += block.spec.rawCID
        prefix += block.parentHomestead.rawCID
        prefix += block.homestead.rawCID
        prefix += block.frontier.rawCID
        prefix += block.childBlocks.rawCID
        prefix += String(block.index)
        prefix += String(block.timestamp)
        return prefix
    }

    private func mineBatch(
        prefix: String,
        targetDifficulty: UInt256,
        startNonce: UInt64,
        count: UInt64
    ) -> UInt64? {
        let end = startNonce &+ count
        var nonce = startNonce
        while nonce < end {
            let hash = UInt256.hash(prefix + String(nonce))
            if targetDifficulty >= hash {
                return nonce
            }
            nonce &+= 1
        }
        return nil
    }

    // MARK: - Coinbase Transaction

    private func buildCoinbaseTransaction(
        previousBlock: Block,
        mempoolTransactions: [Transaction]
    ) async throws -> Transaction? {
        guard let identity = identity else { return nil }

        let reward = spec.rewardAtBlock(previousBlock.index + 1)
        let totalFees = mempoolTransactions.compactMap { $0.body.node?.fee }.reduce(0, +)
        let payout = reward + totalFees
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
        let accountState = state.accountState
        guard let accountDict = accountState.node else {
            let resolvedAccount = try await accountState.resolve(fetcher: fetcher)
            guard let dict = resolvedAccount.node else { return 0 }
            guard let balanceStr = try? dict.get(key: address) else { return 0 }
            return UInt64(balanceStr) ?? 0
        }
        guard let balanceStr = try? accountDict.get(key: address) else { return 0 }
        return UInt64(balanceStr) ?? 0
    }

    // MARK: - Child Block Building (Merged Mining)

    private struct ChildBlockResult {
        let blocks: [String: Block]
        let pendingChildTxRemovals: [(mempool: Mempool, txCIDs: Set<String>)]
    }

    private func buildChildBlocks(nexusBlock: Block) async -> ChildBlockResult {
        var blocks: [String: Block] = [:]
        var pendingRemovals: [(mempool: Mempool, txCIDs: Set<String>)] = []
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        for ctx in childContexts {
            do {
                let childTipHash = await ctx.chainState.getMainChainTip()
                let childTipData = try await ctx.fetcher.fetch(rawCid: childTipHash)
                guard let childTip = Block(data: childTipData) else { continue }

                let childTxs = await ctx.mempool.selectTransactions(
                    maxCount: max(0, Int(ctx.spec.maxNumberOfTransactionsPerBlock) - 1)
                )

                let childBlock = try await BlockBuilder.buildBlock(
                    previous: childTip,
                    transactions: childTxs,
                    parentChainBlock: nexusBlock,
                    timestamp: timestamp,
                    difficulty: childTip.nextDifficulty,
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
