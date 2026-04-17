import Foundation
import Ivy
import OrderedCollections

public actor BlockchainProtectionPolicy: EvictionProtectionPolicy {
    private var pinnedCIDs: OrderedSet<String> = []
    private var chainTipCIDs: Set<String> = []
    private var chainTipsByCID: [String: String] = [:]
    private let maxPinnedCount: Int

    /// CIDs related to the node's own account — never subject to FIFO eviction.
    /// Contains block hashes, transaction CIDs, and body CIDs for transactions
    /// that involve the node's address (sent, received, or mined).
    private var accountCIDs: Set<String> = []

    public init(maxPinnedCount: Int = 10_000) {
        self.maxPinnedCount = maxPinnedCount
    }

    // MARK: - Pinning (miner's own content)

    public func pin(_ cid: String) {
        pinnedCIDs.append(cid)
        evictPinnedIfNeeded()
    }

    public func pinAll(_ cids: [String]) {
        for cid in cids { pin(cid) }
    }

    private func evictPinnedIfNeeded() {
        while pinnedCIDs.count > maxPinnedCount {
            pinnedCIDs.removeFirst()
        }
    }

    public func unpin(_ cid: String) {
        pinnedCIDs.remove(cid)
    }

    public func isPinned(_ cid: String) -> Bool {
        pinnedCIDs.contains(cid)
    }

    // MARK: - Account pinning (permanent, not evicted)

    public func pinAccount(_ cid: String) {
        accountCIDs.insert(cid)
    }

    public func pinAccountBatch(_ cids: [String]) {
        for cid in cids { accountCIDs.insert(cid) }
    }

    public func isAccountPinned(_ cid: String) -> Bool {
        accountCIDs.contains(cid)
    }

    // MARK: - Chain tip tracking (subscribed chains)

    public func setChainTip(chain: String, tipCID: String, referencedCIDs: [String]) {
        let oldCIDs = chainTipsByCID.filter { $0.value == chain }.map(\.key)
        for cid in oldCIDs {
            chainTipCIDs.remove(cid)
            chainTipsByCID.removeValue(forKey: cid)
        }

        chainTipCIDs.insert(tipCID)
        chainTipsByCID[tipCID] = chain
        for cid in referencedCIDs {
            chainTipCIDs.insert(cid)
            chainTipsByCID[cid] = chain
        }
    }

    public func clearChainTip(chain: String) {
        let toRemove = chainTipsByCID.filter { $0.value == chain }.map(\.key)
        for cid in toRemove {
            chainTipCIDs.remove(cid)
            chainTipsByCID.removeValue(forKey: cid)
        }
    }

    // MARK: - EvictionProtectionPolicy

    public func isProtected(_ cid: String) async -> Bool {
        accountCIDs.contains(cid) || pinnedCIDs.contains(cid) || chainTipCIDs.contains(cid)
    }

    public var pinnedCount: Int { pinnedCIDs.count }
    public var chainTipCount: Int { chainTipCIDs.count }
    public var accountPinnedCount: Int { accountCIDs.count }
}
