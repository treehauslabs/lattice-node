import Foundation
import cashew
import ArrayTrie
import Ivy
import Acorn
import Tally
import OrderedCollections

/// A VolumeAwareFetcher that bridges Cashew's resolution system to Ivy's
/// fee-based retrieval protocol.
///
/// When Cashew enters a Volume during lazy resolution, `provide(rootCID:paths:)`
/// discovers pinners for that Volume via Ivy's DHT. Subsequent `fetch()` calls
/// route toward the discovered pinner for that subtree.
///
/// Falls back to the local composite CAS (memory + disk) before hitting the network.
public actor IvyFetcher: VolumeAwareFetcher {
    private let ivy: Ivy
    private let localWorker: any AcornCASWorker

    /// Maps rootCID → discovered pinner for targeted retrieval.
    /// OrderedDictionary maintains insertion order for LRU eviction.
    private var volumePinners: OrderedDictionary<String, PeerID> = [:]
    private let maxPinnerCacheSize = 512

    /// The currently active Volume root — set by provide(), used by fetch()
    /// to route requests directly to the pinner instead of DHT-walking.
    private var activeVolumeRoot: String?

    public init(ivy: Ivy, localWorker: any AcornCASWorker) {
        self.ivy = ivy
        self.localWorker = localWorker
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

    // MARK: - Fetcher

    public func fetch(rawCid: String) async throws -> Data {
        // 1. Check local storage (memory + node-level shared CAS; merged-mining child
        //    state written by the nexus miner lives in the same store).
        let cid = ContentIdentifier(rawValue: rawCid)
        if let data = await localWorker.get(cid: cid) {
            return data
        }

        // 2. If we have a pinner for the active Volume, go directly to them (one hop)
        if let root = activeVolumeRoot, let pinner = volumePinners[root] {
            touchPinnerCache(root)
            if let data = await ivy.get(cid: rawCid, target: pinner) {
                await localWorker.store(cid: cid, data: data)
                return data
            }
        }

        // 3. Fall back to untargeted DHT walk
        if let data = await ivy.get(cid: rawCid) {
            await localWorker.store(cid: cid, data: data)
            return data
        }

        throw FetcherError.notFound(rawCid)
    }

    // MARK: - VolumeAwareFetcher

    /// Called by Cashew before resolving child blocks within a Volume.
    /// Translates Cashew's resolution paths into an Ivy selector, discovers pinners
    /// that cover the needed subtree, and targets subsequent fetch() calls at the best match.
    public func provide(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        activeVolumeRoot = rootCID

        // Use cached pinner if we already know one
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
    ///   paths with single child "accountState" → "/accountState"
    ///   paths with multiple children → "/" (needs everything)
    ///   empty paths → "/"
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

    /// Store data locally and optionally announce to the network.
    public func store(rawCid: String, data: Data, pin: Bool = false) async {
        let cid = ContentIdentifier(rawValue: rawCid)
        await localWorker.store(cid: cid, data: data)
        if pin {
            await ivy.save(cid: rawCid, data: data, pin: true)
        }
    }
}
