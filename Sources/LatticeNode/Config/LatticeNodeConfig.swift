import Lattice
import Foundation
import Ivy
import ArrayTrie

public let DEFAULT_RETENTION_DEPTH: UInt64 = 1000

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
    public let proxyConfig: ProxyConfig?
    public let finality: FinalityConfig

    public init(
        publicKey: String,
        privateKey: String,
        listenPort: UInt16 = 4001,
        bootstrapPeers: [PeerEndpoint] = [],
        storagePath: URL,
        enableLocalDiscovery: Bool = true,
        persistInterval: UInt64 = 100,
        subscribedChains: ArrayTrie<Bool> = {
            var t = ArrayTrie<Bool>()
            t.set(["Nexus"], value: true)
            return t
        }(),
        syncStrategy: SyncStrategy = .snapshot,
        retentionDepth: UInt64 = DEFAULT_RETENTION_DEPTH,
        resources: NodeResourceConfig = .default,
        proxyConfig: ProxyConfig? = nil,
        finality: FinalityConfig = FinalityConfig()
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
        self.proxyConfig = proxyConfig
        self.finality = finality
    }

    public func isSubscribed(chainPath: [String]) -> Bool {
        subscribedChains.get(chainPath) == true
    }
}
