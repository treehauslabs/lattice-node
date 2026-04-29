import Lattice
import Foundation
import cashew

/// Caches the resolved frontier LatticeState to avoid redundant Merkle
/// trie resolution during bursts of transaction validation against the
/// same chain tip. Keyed by frontier CID — automatically invalidated
/// when the chain advances to a new block.
public actor FrontierCache {
    private var cachedCID: String?
    private var cachedState: LatticeState?

    public init() {}

    public func get(frontierCID: String) -> LatticeState? {
        guard cachedCID == frontierCID else { return nil }
        return cachedState
    }

    public func set(frontierCID: String, state: LatticeState) {
        cachedCID = frontierCID
        cachedState = state
    }

    public func invalidate() {
        cachedCID = nil
        cachedState = nil
    }
}
