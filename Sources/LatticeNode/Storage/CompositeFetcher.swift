import Foundation
import cashew

/// Wraps multiple fetchers, trying each in order until one succeeds.
/// Used when processing nexus blocks to provide access to both the nexus CAS
/// and child CAS stores — child block state data lives in child CAS but
/// validation runs with the nexus fetcher.
final class CompositeFetcher: Fetcher, @unchecked Sendable {
    private let primary: Fetcher
    private let fallbacks: [Fetcher]

    init(primary: Fetcher, fallbacks: [Fetcher]) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    func fetch(rawCid: String) async throws -> Data {
        let shortCid = String(rawCid.prefix(16))
        do {
            return try await primary.fetch(rawCid: rawCid)
        } catch {
            let fallbackStart = ContinuousClock.now
            for (idx, fallback) in fallbacks.enumerated() {
                if let data = try? await fallback.fetch(rawCid: rawCid) {
                    LatticeNode.diagLog("CompositeFetcher fallback-hit[\(idx)] \(shortCid)… fallbackElapsed=\(ContinuousClock.now - fallbackStart)")
                    return data
                }
            }
            LatticeNode.diagLog("CompositeFetcher all-failed \(shortCid)… fallbacks=\(fallbacks.count) fallbackElapsed=\(ContinuousClock.now - fallbackStart)")
            throw error
        }
    }
}
