import Lattice
import cashew

public struct MinerIdentity: Sendable {
    public let publicKeyHex: String
    public let privateKeyHex: String
    public let address: String

    public init(publicKeyHex: String, privateKeyHex: String) {
        self.publicKeyHex = publicKeyHex
        self.privateKeyHex = privateKeyHex
        self.address = HeaderImpl<PublicKey>(node: PublicKey(key: publicKeyHex)).rawCID
    }
}

public struct ChildMiningContext: Sendable {
    public let directory: String
    /// Full chain path from nexus to this context, e.g. `["Nexus","FastTest"]`.
    /// Block validation checks each transaction's `chainPath` against this
    /// exact sequence, so the coinbase must carry the same path.
    public let chainPath: [String]
    public let chainState: ChainState
    public let mempool: NodeMempool
    public let fetcher: Fetcher
    public let spec: ChainSpec
    public let children: [ChildMiningContext]

    public init(
        directory: String,
        chainPath: [String],
        chainState: ChainState,
        mempool: NodeMempool,
        fetcher: Fetcher,
        spec: ChainSpec,
        children: [ChildMiningContext] = []
    ) {
        self.directory = directory
        self.chainPath = chainPath
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
        self.children = children
    }
}

public struct MinedBlockPendingRemovals: Sendable {
    public let nexusTxCIDs: Set<String>
    public let childTxRemovals: [(directory: String, mempool: NodeMempool, txCIDs: Set<String>)]
}

public protocol MinerDelegate: AnyObject, Sendable {
    func minerDidProduceBlock(_ block: Block, hash: String, pendingRemovals: MinedBlockPendingRemovals) async
}
