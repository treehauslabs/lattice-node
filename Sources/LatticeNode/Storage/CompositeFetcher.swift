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
}
