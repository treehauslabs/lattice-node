import Lattice
import Foundation
import Ivy
import ArrayTrie

public let DEFAULT_RETENTION_DEPTH: UInt64 = 1000

public enum StorageMode: String, Sendable {
    case stateless
    case stateful
    case historical
}

public enum BlockRetention: String, Sendable {
    case tip
    case retention
    case historical
}

public struct LatticeNodeConfig: Sendable {
    public let publicKey: String
    public let privateKey: String
    public let listenPort: UInt16
    public let bootstrapPeers: [PeerEndpoint]
    public let storagePath: URL
    public let enableLocalDiscovery: Bool
    public let persistInterval: UInt64
    public let subscribedChains: ArrayTrie<Bool>
    public let syncStrategy: SyncStrategy
    public let retentionDepth: UInt64
    public let resources: NodeResourceConfig
    public let finality: FinalityConfig
    public let maxPeerConnections: Int
    public let discoveryOnly: Bool
    public let storageMode: StorageMode
    public let blockRetention: BlockRetention

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = false,
        persistInterval: UInt64 = 100,
        subscribedChains: ArrayTrie<Bool> = {
            var t = ArrayTrie<Bool>()
            t.set(["Nexus"], value: true)
            return t
        }(),
        syncStrategy: SyncStrategy = .snapshot,
        retentionDepth: UInt64 = DEFAULT_RETENTION_DEPTH,
        resources: NodeResourceConfig = .default,
        finality: FinalityConfig = FinalityConfig(),
        maxPeerConnections: Int = BootstrapPeers.maxPeerConnections,
        discoveryOnly: Bool = false,
        storageMode: StorageMode = .stateful,
        blockRetention: BlockRetention = .retention
    ) {
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.listenPort = listenPort
        self.bootstrapPeers = bootstrapPeers
        self.storagePath = storagePath
        self.enableLocalDiscovery = enableLocalDiscovery
        self.persistInterval = persistInterval
        var subs = subscribedChains
        subs.set(["Nexus"], value: true)
        self.subscribedChains = subs
        self.syncStrategy = syncStrategy
        self.retentionDepth = retentionDepth
        self.resources = resources
        self.finality = finality
        self.maxPeerConnections = maxPeerConnections
        self.discoveryOnly = discoveryOnly
        self.storageMode = storageMode
        self.blockRetention = blockRetention
    }

    public func isSubscribed(chainPath: [String]) -> Bool {
        subscribedChains.get(chainPath) == true
    }

    public func addingSubscription(chainPath: [String]) -> LatticeNodeConfig {
        var subs = subscribedChains
        subs.set(chainPath, value: true)
        return LatticeNodeConfig(
            publicKey: publicKey,
            privateKey: privateKey,
            listenPort: listenPort,
            bootstrapPeers: bootstrapPeers,
            storagePath: storagePath,
            enableLocalDiscovery: enableLocalDiscovery,
            persistInterval: persistInterval,
            subscribedChains: subs,
            syncStrategy: syncStrategy,
            retentionDepth: retentionDepth,
            resources: resources,
            finality: finality,
            maxPeerConnections: maxPeerConnections,
            discoveryOnly: discoveryOnly,
            storageMode: storageMode,
            blockRetention: blockRetention
        )
    }

    public func removingSubscription(chainPath: [String]) -> LatticeNodeConfig {
        guard chainPath != ["Nexus"] else { return self }
        var subs = subscribedChains
        subs.set(chainPath, value: false)
        return LatticeNodeConfig(
            publicKey: publicKey,
            privateKey: privateKey,
            listenPort: listenPort,
            bootstrapPeers: bootstrapPeers,
            storagePath: storagePath,
            enableLocalDiscovery: enableLocalDiscovery,
            persistInterval: persistInterval,
            subscribedChains: subs,
            syncStrategy: syncStrategy,
            retentionDepth: retentionDepth,
            resources: resources,
            finality: finality,
            maxPeerConnections: maxPeerConnections,
            discoveryOnly: discoveryOnly,
            storageMode: storageMode,
            blockRetention: blockRetention
        )
    }
}
