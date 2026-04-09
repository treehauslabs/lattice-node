import Foundation
import cashew
import ArrayTrie

/// Wraps a fetcher with an in-memory cache of pre-computed transaction data.
///
/// Before resolving a block's transaction dict, the caller pre-populates the
/// cache with serialized Transaction data keyed by Volume CID. Since each
/// transaction in the block is a `VolumeImpl<Transaction>`, the resolver calls
/// `fetch(rawCid:)` with the Volume CID — hitting the cache instead of the network.
///
/// Also skips pinner discovery (`provide`) for cached CIDs, saving DHT lookups.
final class MempoolAwareFetcher: VolumeAwareFetcher, @unchecked Sendable {
    private let inner: Fetcher
    private let cache: [String: Data]

    init(inner: Fetcher, cache: [String: Data]) {
        self.inner = inner
        self.cache = cache
    }

    func fetch(rawCid: String) async throws -> Data {
        if let data = cache[rawCid] {
            return data
        }
        return try await inner.fetch(rawCid: rawCid)
    }

    func provide(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        if cache[rootCID] != nil { return }
        if let volumeAware = inner as? VolumeAwareFetcher {
            try await volumeAware.provide(rootCID: rootCID, paths: paths)
        }
    }
}
