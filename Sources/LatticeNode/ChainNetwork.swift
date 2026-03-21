import Lattice
import Foundation
import Ivy
import Acorn
import AcornDiskWorker
import AcornMemoryWorker
import Tally
import cashew
import UInt256

public protocol ChainNetworkDelegate: AnyObject, Sendable {
    func chainNetwork(_ network: ChainNetwork, didReceiveBlock cid: String, data: Data, from peer: PeerID) async
    func chainNetwork(_ network: ChainNetwork, didReceiveBlockAnnouncement cid: String, from peer: PeerID) async
}

public actor ChainNetwork: IvyDelegate {
    public let directory: String
    public let ivy: Ivy
    public let fetcher: AcornFetcher
    public let mempool: Mempool
    private let storage: any AcornCASWorker
    private let memoryWorker: MemoryCASWorker
    public let verifiedStore: VerifiedDistanceStore
    private let resources: NodeResourceConfig
    public weak var delegate: ChainNetworkDelegate?
    private var subscribedChains: Set<String>

    public init(
        directory: String,
        config: IvyConfig,
        storagePath: URL,
        resources: NodeResourceConfig = .default,
        chainCount: Int = 1
    ) async throws {
        self.directory = directory
        self.subscribedChains = Set([directory])
        self.resources = resources
        self.mempool = Mempool(maxSize: resources.mempoolSizePerChain(chainCount: chainCount))

        let memoryBytes = resources.memoryBytesPerChain(chainCount: chainCount)
        let memoryEntries = max(memoryBytes / 4096, 100)
        let memory = MemoryCASWorker(
            capacity: memoryEntries,
            maxBytes: memoryBytes
        )
        self.memoryWorker = memory

        let diskBytes = resources.diskBytesPerChain(chainCount: chainCount)
        let disk = try DiskCASWorker(
            directory: storagePath.appendingPathComponent(directory),
            maxBytes: diskBytes
        )

        let verified = VerifiedDistanceStore(
            inner: disk,
            nodePublicKey: config.publicKey,
            maxEntries: max(diskBytes / 4096, 1000)
        )
        self.verifiedStore = verified

        let ivy = Ivy(config: config)
        let network = await ivy.reticulumWorker()

        let composite = await CompositeCASWorker(
            workers: ["mem": memory, "disk": verified, "net": network],
            order: ["mem", "disk", "net"]
        )

        self.ivy = ivy
        self.storage = composite
        self.fetcher = AcornFetcher(worker: composite)
    }

    public func start() async throws {
        await ivy.setDelegate(self)
        try await ivy.start()

        let chain = ChainDestination(chainDirectory: directory)
        let reticulum = await ivy.reticulumWorker()
        await reticulum.bindToChain(chain)
    }

    public func stop() async {
        await ivy.stop()
    }

    // MARK: - Chain Tip Management

    public func setChainTip(tipCID: String, referencedCIDs: [String]) async {
        await verifiedStore.setChainTip(chain: directory, tipCID: tipCID, referencedCIDs: referencedCIDs)
    }

    // MARK: - Chain Subscription

    public func subscribe(to chainDirectory: String) {
        subscribedChains.insert(chainDirectory)
    }

    public func unsubscribe(from chainDirectory: String) {
        subscribedChains.remove(chainDirectory)
    }

    public func isSubscribed(to chainDirectory: String) -> Bool {
        subscribedChains.contains(chainDirectory)
    }

    public func subscribedDirectories() -> Set<String> {
        subscribedChains
    }

    // MARK: - Block Operations

    public func publishBlock(cid: String, data: Data, referencedCIDs: [String] = []) async {
        await verifiedStore.storePinned(cid: ContentIdentifier(rawValue: cid), data: data)
        await ivy.publishBlock(cid: cid, data: data)
    }

    public func announceBlock(cid: String) async {
        await ivy.announceBlock(cid: cid)
    }

    public func storeBlock(cid: String, data: Data) async {
        await fetcher.store(rawCid: cid, data: data)
    }

    // MARK: - Mempool Operations

    public func submitTransaction(_ transaction: Transaction) async -> Bool {
        await mempool.add(transaction: transaction)
    }

    public func selectTransactionsForBlock(maxCount: Int) async -> [Transaction] {
        await mempool.selectTransactions(maxCount: maxCount)
    }

    public func pruneConfirmedTransactions(txCIDs: Set<String>) async {
        await mempool.removeAll(txCIDs: txCIDs)
    }

    // MARK: - IvyDelegate

    nonisolated public func ivy(_ ivy: Ivy, didConnect peer: PeerID) {}
    nonisolated public func ivy(_ ivy: Ivy, didDisconnect peer: PeerID) {}

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlockAnnouncement cid: String, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlockAnnouncement: cid, from: peer) }
    }

    nonisolated public func ivy(_ ivy: Ivy, didReceiveBlock cid: String, data: Data, from peer: PeerID) {
        Task { await delegate?.chainNetwork(self, didReceiveBlock: cid, data: data, from: peer) }
    }
}

extension Ivy {
    func setDelegate(_ delegate: IvyDelegate) {
        self.delegate = delegate
    }
}
