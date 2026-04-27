import Foundation
import cashew
import ArrayTrie

/// Wraps multiple per-chain fetchers, trying each in order until one succeeds.
/// Used when processing nexus blocks to provide access to both the nexus CAS
/// and child CAS stores — a child block embedded in a nexus block lives in
/// the child broker even though validation runs against the nexus fetcher.
///
/// Conforms to `VolumeAwareFetcher` and orchestrates Volume entry in two
/// phases:
///
/// 1. Ask every underlying `IvyFetcher` to try its local broker. The first
///    one that hits pushes a cache layer; the others push nothing. No
///    network is touched.
/// 2. Only if every local store missed do we go to the network — and we
///    pay at most one fetcher's timeout, walking the list in order until
///    one network resolve succeeds.
///
/// The asymmetric "all locals before any network" pattern matters because
/// per-chain isolation means a Volume's home broker is determined by what
/// chain it belongs to, not by which fetcher we happened to enter through.
final class CompositeFetcher: VolumeAwareFetcher, @unchecked Sendable {
    private let primary: Fetcher
    private let fallbacks: [Fetcher]

    /// Tracks, per rootCID currently entered, which underlying fetchers
    /// pushed a cache layer (and therefore need a matching `exitVolume`).
    /// Indexed by depth so re-entrancy on the same root works.
    private var entryStack: [(root: String, owners: [VolumeAwareFetcher])] = []
    private let entryLock = NSLock()

    init(primary: Fetcher, fallbacks: [Fetcher]) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    func fetch(rawCid: String) async throws -> Data {
        do {
            return try await primary.fetch(rawCid: rawCid)
        } catch {
            for fallback in fallbacks {
                if let data = try? await fallback.fetch(rawCid: rawCid) {
                    return data
                }
            }
            throw error
        }
    }

    func enterVolume(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        let allFetchers: [VolumeAwareFetcher] = ([primary] + fallbacks).compactMap { $0 as? VolumeAwareFetcher }

        var owners: [VolumeAwareFetcher] = []

        for f in allFetchers {
            if let ivy = f as? IvyFetcher, await ivy.tryEnterLocal(rootCID: rootCID) {
                owners.append(f)
                pushEntry(root: rootCID, owners: owners)
                return
            }
        }

        for f in allFetchers {
            if let ivy = f as? IvyFetcher {
                await ivy.enterFromNetwork(rootCID: rootCID)
                owners.append(f)
                if await ivy.cachedEntryCount(root: rootCID) > 0 {
                    pushEntry(root: rootCID, owners: owners)
                    return
                }
            } else {
                try await f.enterVolume(rootCID: rootCID, paths: paths)
                owners.append(f)
            }
        }

        pushEntry(root: rootCID, owners: owners)
    }

    func exitVolume(rootCID: String) async {
        let owners = popEntry(root: rootCID)
        for owner in owners {
            await owner.exitVolume(rootCID: rootCID)
        }
    }

    private func pushEntry(root: String, owners: [VolumeAwareFetcher]) {
        entryLock.lock()
        entryStack.append((root: root, owners: owners))
        entryLock.unlock()
    }

    private func popEntry(root: String) -> [VolumeAwareFetcher] {
        entryLock.lock()
        defer { entryLock.unlock() }
        guard let idx = entryStack.lastIndex(where: { $0.root == root }) else { return [] }
        let owners = entryStack[idx].owners
        entryStack.remove(at: idx)
        return owners
    }
}
