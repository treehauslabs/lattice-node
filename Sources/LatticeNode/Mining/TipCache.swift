import Foundation

/// Lock-free (NSLock) cache for the chain tip hash.
/// Allows MinerLoop to check for tip changes without an actor hop into ChainState.
/// Updated by LatticeNode whenever a block is accepted or mined.
public final class TipCache: @unchecked Sendable {
    private var _tip: String
    private let lock = NSLock()

    public init(tip: String) {
        self._tip = tip
    }

    public var tip: String {
        lock.lock()
        defer { lock.unlock() }
        return _tip
    }

    public func update(_ newTip: String) {
        lock.lock()
        _tip = newTip
        lock.unlock()
    }
}
