import Foundation
import cashew
import ArrayTrie
import Ivy
import VolumeBroker
import Tally
import OrderedCollections

public enum FetcherError: Error {
    case notFound(String)
}

/// A VolumeAwareFetcher that bridges Cashew's resolution system to Ivy's
/// fee-based retrieval protocol.
///
/// When Cashew enters a Volume during lazy resolution, `provide(rootCID:paths:)`
/// discovers pinners for that Volume via Ivy's DHT. Subsequent `fetch()` calls
/// route toward the discovered pinner for that subtree.
///
/// Falls back to the broker cascade (memory -> disk -> network) before hitting the DHT.
public actor IvyFetcher: VolumeAwareFetcher {
    private let ivy: Ivy
    private let broker: any VolumeBroker

    /// Stack of Volume boundary caches. Each provide() pushes a new layer.
    /// leave() pops via removeSubrange (cascading cleanup). fetch() searches
    /// top-down. Bounded by the provide/leave lifecycle — recursive resolves
    /// leave after children complete, simple resolves are cleaned up by the
    /// parent's leave.
    private var cacheStack: [(root: String, entries: [String: Data])] = []

    private var volumePinners: OrderedDictionary<String, PeerID> = [:]
    private let maxPinnerCacheSize = 512

    private var activeVolumeRoot: String?
    private var recentPinner: PeerID?

    public init(ivy: Ivy, broker: any VolumeBroker) {
        self.ivy = ivy
        self.broker = broker
    }

    private func pushCache(root: String, entries: [String: Data]) {
        cacheStack.append((root: root, entries: entries))
    }

    private func cacheLookup(_ cid: String) -> Data? {
        for i in stride(from: cacheStack.count - 1, through: 0, by: -1) {
            if let data = cacheStack[i].entries[cid] { return data }
        }
        return nil
    }

    private func touchPinnerCache(_ key: String) {
        // Move to end (most recently used)
        if let value = volumePinners.removeValue(forKey: key) {
            volumePinners[key] = value
        }
    }

    private func evictPinnerCacheIfNeeded() {
        while volumePinners.count > maxPinnerCacheSize {
            volumePinners.removeFirst()
        }
    }

    /// Bind `peer` as a known source for `rootCID`, bypassing DHT discovery.
    /// Call this when we receive data directly from a peer (e.g., a gossip
    /// block announce) — the sender is by definition a pinner for the tree
    /// and any tree it references. Subsequent `provide()` calls for this
    /// rootCID short-circuit without hitting the DHT, and `fetch()` routes
    /// misses to `peer` before falling back.
    public func bindPinner(rootCID: String, peer: PeerID) {
        guard !rootCID.isEmpty else { return }
        volumePinners[rootCID] = peer
        touchPinnerCache(rootCID)
        evictPinnerCacheIfNeeded()
        recentPinner = peer
    }

    // MARK: - Fetcher

    public func fetch(rawCid: String) async throws -> Data {
        if let data = cacheLookup(rawCid) { return data }

        if let payload = await broker.fetchVolume(root: rawCid) {
            if let data = payload.entries[rawCid] { return data }
        }

        let volumePinner = activeVolumeRoot.flatMap { volumePinners[$0] }
        let pinner = volumePinner ?? recentPinner

        if let pinner = pinner {
            if let root = activeVolumeRoot, volumePinner != nil { touchPinnerCache(root) }
            if let data = await ivy.getDirect(cid: rawCid, from: pinner) {
                let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
                try? await broker.storeVolumeLocal(payload)
                return data
            }
        }

        if let data = await ivy.get(cid: rawCid) {
            let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
            try? await broker.storeVolumeLocal(payload)
            return data
        }

        let total = cacheStack.reduce(0) { $0 + $1.entries.count }
        NodeLogger("fetcher").error("notFound: \(String(rawCid.prefix(20)))… activeVolume=\(activeVolumeRoot?.prefix(20) ?? "nil") stackDepth=\(cacheStack.count) totalCached=\(total)")
        throw FetcherError.notFound(rawCid)
    }

    // MARK: - VolumeAwareFetcher

    public func enterVolume(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        activeVolumeRoot = rootCID

        if let payload = await broker.fetchVolume(root: rootCID) {
            pushCache(root: rootCID, entries: payload.entries)
            return
        }

        if volumePinners[rootCID] != nil {
            touchPinnerCache(rootCID)
            return
        }

        let selector = Self.selectorFromPaths(paths)
        let pinners = await ivy.discoverPinners(cid: rootCID)

        // Prefer pinners whose selector covers our needs (prefix match)
        if let best = Self.bestPinner(for: selector, from: pinners) {
            volumePinners[rootCID] = PeerID(publicKey: best.publicKey)
            touchPinnerCache(rootCID)
            evictPinnerCacheIfNeeded()
        } else if let fallback = pinners.first {
            volumePinners[rootCID] = PeerID(publicKey: fallback.publicKey)
            touchPinnerCache(rootCID)
            evictPinnerCacheIfNeeded()
        }
    }

    public func exitVolume(rootCID: String) {
        if let idx = cacheStack.lastIndex(where: { $0.root == rootCID }) {
            cacheStack.removeSubrange(idx...)
        }
    }

    // MARK: - Selector Translation

    /// Convert Cashew's ArrayTrie<ResolutionStrategy> into an Ivy selector string.
    /// Uses the top-level keys of the trie as the selector path. Examples:
    ///   paths with single child "accountState" -> "/accountState"
    ///   paths with multiple children -> "/" (needs everything)
    ///   empty paths -> "/"
    static func selectorFromPaths(_ paths: ArrayTrie<ResolutionStrategy>) -> String {
        let topKeys = paths.childKeys()
        guard topKeys.count == 1, let key = topKeys.first else { return "/" }
        // Single top-level path — use it as selector
        // Check if there's a deeper single path
        if let child = paths.traverse(path: key) {
            let subKeys = child.childKeys()
            if subKeys.count == 1, let subKey = subKeys.first {
                return "/\(key)/\(subKey)"
            }
        }
        return "/\(key)"
    }

    /// Pick the pinner whose selector best covers the needed selector.
    /// "/" covers everything. "/accountState" covers "/accountState/alice".
    /// Prefer the most specific match (longest matching selector).
    static func bestPinner(
        for selector: String,
        from pinners: [(publicKey: String, selector: String)]
    ) -> (publicKey: String, selector: String)? {
        var best: (publicKey: String, selector: String)?
        var bestLen = -1

        for pinner in pinners {
            // Check if pinner's selector covers our needs
            if selector.hasPrefix(pinner.selector) || pinner.selector == "/" {
                let len = pinner.selector.count
                if len > bestLen {
                    best = pinner
                    bestLen = len
                }
            }
        }
        return best
    }

    // MARK: - Store

    /// Store data locally via the broker cascade.
    public func store(rawCid: String, data: Data, pin: Bool = false) async {
        let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
        try? await broker.storeVolumeLocal(payload)
    }
}
