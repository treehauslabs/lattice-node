import Foundation
import Ivy
import OrderedCollections

public actor BlockchainProtectionPolicy: EvictionProtectionPolicy {
    /// Node's own pinned content (e.g. blocks it mined, tx bodies it produced).
    private var pinnedCIDs: OrderedSet<String> = []
    private let maxPinnedCount: Int

    /// CIDs related to the node's own account — never subject to FIFO eviction.
    /// Contains block hashes, transaction CIDs, and body CIDs for transactions
    /// that involve the node's address (sent, received, or mined).
    private var accountCIDs: Set<String> = []

    /// Per-chain state-root CIDs (frontier / homestead / tx / childBlocks / tip).
    /// Protected while subscribed; cleared on unsubscribe via `clearStateRoots`.
    private var stateRootCIDs: Set<String> = []
    private var stateRootsByChain: [String: Set<String>] = [:]

    /// Recent blocks retained for reorg safety — TTL-protected, not tied to chain subscription.
    /// After the TTL elapses, block bodies become eligible for LRU eviction; new pinners
    /// in the network can serve them if anyone needs history.
    private var recentBlockExpiry: [String: ContinuousClock.Instant] = [:]
    private let recentBlockTTL: Duration

    public init(
        maxPinnedCount: Int = 10_000,
        recentBlockTTL: Duration = .seconds(3600)
    ) {
        self.maxPinnedCount = maxPinnedCount
        self.recentBlockTTL = recentBlockTTL
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

    // MARK: - State-root protection (per-chain, permanent while subscribed)

    /// Replace the set of state-root CIDs protected for `chain`.
    /// Typical roots: tip block, frontier, homestead, transactions, childBlocks.
    public func setStateRoots(chain: String, roots: [String]) {
        if let old = stateRootsByChain[chain] {
            for cid in old where !roots.contains(cid) {
                // Only drop from flat set if no other chain still references it.
                if !otherChainHasRoot(cid, excluding: chain) {
                    stateRootCIDs.remove(cid)
                }
            }
        }
        stateRootsByChain[chain] = Set(roots)
        for cid in roots { stateRootCIDs.insert(cid) }
    }

    public func clearStateRoots(chain: String) {
        guard let roots = stateRootsByChain.removeValue(forKey: chain) else { return }
        for cid in roots where !otherChainHasRoot(cid, excluding: chain) {
            stateRootCIDs.remove(cid)
        }
    }

    private func otherChainHasRoot(_ cid: String, excluding chain: String) -> Bool {
        for (otherChain, roots) in stateRootsByChain where otherChain != chain {
            if roots.contains(cid) { return true }
        }
        return false
    }

    // MARK: - Recent-block protection (TTL)

    public func addRecentBlock(_ cid: String) {
        recentBlockExpiry[cid] = .now.advanced(by: recentBlockTTL)
    }

    public func pruneExpiredRecentBlocks() {
        let now = ContinuousClock.now
        recentBlockExpiry = recentBlockExpiry.filter { $0.value > now }
    }

    // MARK: - EvictionProtectionPolicy

    public func isProtected(_ cid: String) async -> Bool {
        if accountCIDs.contains(cid) { return true }
        if pinnedCIDs.contains(cid) { return true }
        if stateRootCIDs.contains(cid) { return true }
        if let expiry = recentBlockExpiry[cid], expiry > .now { return true }
        return false
    }

    public var pinnedCount: Int { pinnedCIDs.count }
    public var stateRootCount: Int { stateRootCIDs.count }
    public var recentBlockCount: Int { recentBlockExpiry.count }
    public var accountPinnedCount: Int { accountCIDs.count }
}
