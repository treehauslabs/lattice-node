import Foundation
import cashew
import ArrayTrie
import Ivy
import Acorn
import Tally

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

    /// Maps rootCID → discovered pinner public key for targeted retrieval
    private var volumePinners: [String: PeerID] = [:]

    public init(ivy: Ivy, localWorker: any AcornCASWorker) {
        self.ivy = ivy
        self.localWorker = localWorker
    }

    // MARK: - Fetcher

    public func fetch(rawCid: String) async throws -> Data {
        // 1. Check local storage (unified CID format — one lookup)
        let cid = ContentIdentifier(rawValue: rawCid)
        if let data = await localWorker.get(cid: cid) {
            return data
        }

        // 2. Fee-based retrieval through Ivy
        if let data = await ivy.get(cid: rawCid) {
            await localWorker.store(cid: cid, data: data)
            return data
        }

        throw FetcherError.notFound(rawCid)
    }

    // MARK: - VolumeAwareFetcher

    /// Called by Cashew before resolving child blocks within a Volume.
    /// Discovers pinners for the Volume's root CID so subsequent fetch()
    /// calls can route toward peers that store the subtree contiguously.
    public func provide(rootCID: String, paths: ArrayTrie<ResolutionStrategy>) async throws {
        let pinners = await ivy.discoverPinners(cid: rootCID)
        if let best = pinners.first {
            volumePinners[rootCID] = PeerID(publicKey: best.publicKey)
        }
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
