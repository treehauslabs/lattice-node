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
    public let chainState: ChainState
    public let mempool: NodeMempool
    public let fetcher: Fetcher
    public let spec: ChainSpec

    public init(directory: String, chainState: ChainState, mempool: NodeMempool, fetcher: Fetcher, spec: ChainSpec) {
        self.directory = directory
        self.chainState = chainState
        self.mempool = mempool
        self.fetcher = fetcher
        self.spec = spec
    }
}

public struct MinedBlockPendingRemovals: Sendable {
    public let nexusTxCIDs: Set<String>
    public let childTxRemovals: [(directory: String, mempool: NodeMempool, txCIDs: Set<String>)]
}

public protocol MinerDelegate: AnyObject, Sendable {
    func minerDidProduceBlock(_ block: Block, hash: String, pendingRemovals: MinedBlockPendingRemovals) async
}
