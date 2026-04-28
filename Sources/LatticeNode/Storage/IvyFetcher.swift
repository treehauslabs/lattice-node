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
/// Volume retrieval protocol.
///
/// `enterVolume(rootCID:)` pulls the entire Volume payload from a peer in one
/// shot via `ivy.fetchVolume`; subsequent `fetch(cid:)` calls within that
/// scope resolve from the cached entries. CID is not a network query
/// abstraction — Volume root is.
public actor IvyFetcher: VolumeAwareFetcher {
    private let ivy: Ivy
    private let broker: any VolumeBroker

    /// Stack of Volume boundary caches. Each enterVolume() pushes a new layer.
    /// exitVolume() pops via removeSubrange (cascading cleanup). fetch()
    /// searches top-down.
    private var cacheStack: [(root: String, entries: [String: Data])] = []

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

    /// Hint that `peer` is a known provider for `rootCID`. The next
    /// `enterVolume(rootCID:)` will try `peer` first when fetching the Volume
    /// from the network.
    public func bindPinner(rootCID: String, peer: PeerID) async {
        guard !rootCID.isEmpty else { return }
        await ivy.recordProvider(rootCID: rootCID, peer: peer)
    }

    // MARK: - Fetcher

    public func fetch(rawCid: String) async throws -> Data {
        if let data = cacheLookup(rawCid) { return data }

        var current: (any VolumeBroker)? = broker
        while let b = current {
            if let payload = await b.fetchVolumeLocal(root: rawCid),
               let data = payload.entries[rawCid] {
                return data
            }
            current = await b.near
        }

        let total = cacheStack.reduce(0) { $0 + $1.entries.count }
        NodeLogger("fetcher").error("notFound: \(String(rawCid.prefix(20)))… stackDepth=\(cacheStack.count) totalCached=\(total)")
        throw FetcherError.notFound(rawCid)
    }

    // MARK: - VolumeAwareFetcher

    public func enterVolume(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        if await tryEnterLocal(rootCID: rootCID) { return }
        await enterFromNetwork(rootCID: rootCID)
    }

    /// Local-only Volume entry: pushes a cache layer if (and only if) the
    /// Volume is in this fetcher's local broker chain. Returns whether the
    /// local store served the request. Walks `near` only (Memory → Disk),
    /// never `far` — `far` is the IvyBroker network tier, and consulting it
    /// here would short-circuit `enterFromNetwork`'s explicit disk writeback.
    /// Used by `CompositeFetcher` to consult every per-chain broker before
    /// paying for a network round-trip.
    public func tryEnterLocal(rootCID: String) async -> Bool {
        var current: (any VolumeBroker)? = broker
        while let b = current {
            if let payload = await b.fetchVolumeLocal(root: rootCID) {
                pushCache(root: rootCID, entries: payload.entries)
                return true
            }
            current = await b.near
        }
        return false
    }

    /// Network-side of `enterVolume`: requests the Volume from peers, caches
    /// it locally on hit, and always pushes a cache layer (possibly empty)
    /// so the call pairs cleanly with `exitVolume`.
    public func enterFromNetwork(rootCID: String) async {
        let entries = await ivy.fetchVolume(rootCID: rootCID)
        if !entries.isEmpty {
            let payload = VolumePayload(root: rootCID, entries: entries)
            try? await broker.storeVolumeLocal(payload)
        }
        pushCache(root: rootCID, entries: entries)
    }

    /// Number of entries cached at the topmost layer matching `root`.
    /// Used by `CompositeFetcher` to detect a successful network entry.
    public func cachedEntryCount(root: String) -> Int {
        guard let layer = cacheStack.last(where: { $0.root == root }) else { return 0 }
        return layer.entries.count
    }

    public func exitVolume(rootCID: String) {
        if let idx = cacheStack.lastIndex(where: { $0.root == rootCID }) {
            cacheStack.removeSubrange(idx...)
        }
    }

    // MARK: - Store

    public func store(rawCid: String, data: Data, pin: Bool = false) async {
        let payload = VolumePayload(root: rawCid, entries: [rawCid: data])
        try? await broker.storeVolumeLocal(payload)
    }
}
