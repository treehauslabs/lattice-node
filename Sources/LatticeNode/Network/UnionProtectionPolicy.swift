import Foundation
import Ivy

/// Aggregates multiple per-chain protection policies into one.
/// A CID is protected if any member policy protects it — so a single node-level
/// eviction store can respect every subscribed chain's pins without each chain
/// owning its own storage.
public actor UnionProtectionPolicy: EvictionProtectionPolicy {
    private var policies: [String: BlockchainProtectionPolicy] = [:]

    public init() {}

    public func register(chain: String, policy: BlockchainProtectionPolicy) {
        policies[chain] = policy
    }

    public func unregister(chain: String) {
        policies.removeValue(forKey: chain)
    }

    public func policy(for chain: String) -> BlockchainProtectionPolicy? {
        policies[chain]
    }

    public func isProtected(_ cid: String) async -> Bool {
        for (_, policy) in policies {
            if await policy.isProtected(cid) { return true }
        }
        return false
    }
}
