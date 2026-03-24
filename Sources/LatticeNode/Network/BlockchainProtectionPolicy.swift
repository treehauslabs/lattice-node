import Foundation
import Ivy

public actor BlockchainProtectionPolicy: EvictionProtectionPolicy {
    private var pinnedCIDs: Set<String> = []
    private var pinnedOrder: [String] = []
    private var chainTipCIDs: Set<String> = []
    private var chainTipsByCID: [String: String] = [:]
    private let maxPinnedCount: Int

    public init(maxPinnedCount: Int = 10_000) {
        self.maxPinnedCount = maxPinnedCount
    }

    // MARK: - Pinning (miner's own content)

    public func pin(_ cid: String) {
        if pinnedCIDs.insert(cid).inserted {
            pinnedOrder.append(cid)
            evictPinnedIfNeeded()
        }
    }

    public func pinAll(_ cids: [String]) {
        for cid in cids { pin(cid) }
    }

    private func evictPinnedIfNeeded() {
        while pinnedOrder.count > maxPinnedCount {
            let oldest = pinnedOrder.removeFirst()
            pinnedCIDs.remove(oldest)
        }
    }

    public func unpin(_ cid: String) {
        pinnedCIDs.remove(cid)
    }

    public func isPinned(_ cid: String) -> Bool {
        pinnedCIDs.contains(cid)
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
        pinnedCIDs.contains(cid) || chainTipCIDs.contains(cid)
    }

    public var pinnedCount: Int { pinnedCIDs.count }
    public var chainTipCount: Int { chainTipCIDs.count }
}
