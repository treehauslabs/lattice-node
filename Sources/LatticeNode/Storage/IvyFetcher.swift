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
    private var cache: [String: Data] = [:]

    /// Maps rootCID -> discovered pinner for targeted retrieval.
    /// OrderedDictionary maintains insertion order for LRU eviction.
    private var volumePinners: OrderedDictionary<String, PeerID> = [:]
    private let maxPinnerCacheSize = 512

    /// The currently active Volume root — set by provide(), used by fetch()
    /// to route requests directly to the pinner instead of DHT-walking.
    private var activeVolumeRoot: String?

    /// Most recently bound pinner, used as a fallback when `activeVolumeRoot`
    /// has no explicit pinner. A peer that gave us a block transitively holds
    /// every sub-volume it references, but DHT discovery for those sub-volumes
    /// lags — falling back to this peer turns a 15s DHT-walk timeout into one
    /// extra round-trip to a connected node that almost certainly has the data.
    private var recentPinner: PeerID?

    public init(ivy: Ivy, broker: any VolumeBroker) {
        self.ivy = ivy
        self.broker = broker
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
        if let data = cache[rawCid] { return data }

        if let payload = await broker.fetchVolume(root: rawCid) {
            if let data = payload.entries[rawCid] { return data }
        }

        let volumePinner = activeVolumeRoot.flatMap { volumePinners[$0] }
        let pinner = volumePinner ?? recentPinner

        // 2. Route directly to a known pinner (one hop) via the fee-less direct
        //    path — gossip follow-up, not a cold DHT query.
        if let pinner = pinner {
            if let root = activeVolumeRoot, volumePinner != nil { touchPinnerCache(root) }
            if let data = await ivy.getDirect(cid: rawCid, from: pinner) {
                // Store back into broker cascade for future reads
                let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
                try? await broker.storeVolumeLocal(payload)
                return data
            }
        }

        // 3. Fall back to untargeted DHT walk
        if let data = await ivy.get(cid: rawCid) {
            let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
            try? await broker.storeVolumeLocal(payload)
            return data
        }

        NodeLogger("fetcher").error("notFound: \(String(rawCid.prefix(20)))… activeVolume=\(activeVolumeRoot?.prefix(20) ?? "nil") cacheSize=\(cache.count)")
        throw FetcherError.notFound(rawCid)
    }

    // MARK: - VolumeAwareFetcher

    /// Called by Cashew before resolving child blocks within a Volume.
    /// Translates Cashew's resolution paths into an Ivy selector, discovers pinners
    /// that cover the needed subtree, and targets subsequent fetch() calls at the best match.
    public func provide(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        activeVolumeRoot = rootCID
        cache.removeAll(keepingCapacity: true)

        if let payload = await broker.fetchVolume(root: rootCID) {
            for (cid, data) in payload.entries { cache[cid] = data }
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
