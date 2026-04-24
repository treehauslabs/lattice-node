import Foundation
import Ivy
import OrderedCollections

public actor BlockchainProtectionPolicy: EvictionProtectionPolicy {
    /// Node's own pinned content (e.g. blocks it mined, tx bodies it produced).
    private var pinnedCIDs: OrderedSet<String> = []
    private let maxPinnedCount: Int

    /// CIDs related to the node's own account. LRU-capped: without a cap, a
    /// miner accumulates ~3 entries per block forever (block hash + txCID +
    /// bodyCID on each coinbase). At a 10s block time that's ~9.5M entries/year
    /// permanently in memory and checked on every eviction. The announce
    /// coupling below (`announceExpiry`) still keeps any pin the network was
    /// told about protected regardless of LRU eviction here, so dropping old
    /// entries from this set is safe — anything still actively announced
    /// remains in `isProtected`.
    private var accountCIDs: OrderedSet<String> = []
    private let maxAccountCIDs: Int

    /// Per-chain state-root CIDs (frontier / homestead / tx / childBlocks / tip).
    /// Protected while subscribed; cleared on unsubscribe via `clearStateRoots`.
    private var stateRootCIDs: Set<String> = []
    private var stateRootsByChain: [String: Set<String>] = [:]

    /// Recent blocks retained for reorg safety — TTL-protected, not tied to chain subscription.
    /// After the TTL elapses, block bodies become eligible for LRU eviction; new pinners
    /// in the network can serve them if anyone needs history.
    private var recentBlockExpiry: [String: ContinuousClock.Instant] = [:]
    private let recentBlockTTL: Duration

    /// Seconds-since-epoch at which each live pin announce expires. An entry here
    /// means: we told the network we pin this CID until at least `announceExpiry[cid]`.
    /// Eviction MUST NOT drop the bytes before that moment, or peers routed here
    /// will see 404s and Ivy reputation will drop. Coupling the two lifetimes here
    /// makes any future LRU cap on other sets (pinnedCIDs, accountCIDs) safe by
    /// default — see P0 #4a in UNSTOPPABLE_LATTICE.md.
    private var announceExpiry: [String: UInt64] = [:]

    public init(
        maxPinnedCount: Int = 10_000,
        maxAccountCIDs: Int = 200_000,
        recentBlockTTL: Duration = .seconds(3600)
    ) {
        self.maxPinnedCount = maxPinnedCount
        self.maxAccountCIDs = maxAccountCIDs
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
        bumpAccount(cid)
        evictAccountIfNeeded()
    }

    public func pinAccountBatch(_ cids: [String]) {
        for cid in cids { bumpAccount(cid) }
        evictAccountIfNeeded()
    }

    public func isAccountPinned(_ cid: String) -> Bool {
        accountCIDs.contains(cid)
    }

    private func bumpAccount(_ cid: String) {
        // LRU: remove existing position (if any) and append at the tail so the
        // most-recently-touched CIDs sit at the back and the oldest drop first.
        accountCIDs.remove(cid)
        accountCIDs.append(cid)
    }

    private func evictAccountIfNeeded() {
        while accountCIDs.count > maxAccountCIDs {
            accountCIDs.removeFirst()
        }
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

    // MARK: - Announce coupling

    /// Record that we have announced `cid` to the network with an expiry of
    /// `expirySecsSinceEpoch`. Retains the *latest* expiry seen for this CID
    /// so overlapping reannounces extend (never shorten) the protection window.
    public func recordAnnounce(cid: String, expirySecsSinceEpoch: UInt64) {
        guard !cid.isEmpty else { return }
        if let existing = announceExpiry[cid], existing >= expirySecsSinceEpoch { return }
        announceExpiry[cid] = expirySecsSinceEpoch
    }

    /// Drop announce entries that have already expired. Called opportunistically
    /// by the reannounce loop so the map doesn't grow unbounded across restart.
    public func pruneExpiredAnnounces() {
        let now = UInt64(Date().timeIntervalSince1970)
        announceExpiry = announceExpiry.filter { $0.value > now }
    }

    public var announcedCount: Int { announceExpiry.count }

    // MARK: - EvictionProtectionPolicy

    public func isProtected(_ cid: String) async -> Bool {
        if accountCIDs.contains(cid) { return true }
        if pinnedCIDs.contains(cid) { return true }
        if stateRootCIDs.contains(cid) { return true }
        if let expiry = recentBlockExpiry[cid], expiry > .now { return true }
        if let expiry = announceExpiry[cid], expiry > UInt64(Date().timeIntervalSince1970) { return true }
        return false
    }

    public var pinnedCount: Int { pinnedCIDs.count }
    public var stateRootCount: Int { stateRootCIDs.count }
    public var recentBlockCount: Int { recentBlockExpiry.count }
    public var accountPinnedCount: Int { accountCIDs.count }
}
