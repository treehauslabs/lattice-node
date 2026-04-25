import Foundation
import VolumeBroker
import Ivy

public actor IvyBroker: VolumeBroker {
    public var near: (any VolumeBroker)?
    public var far: (any VolumeBroker)?

    private weak var node: Ivy?

    public init(node: Ivy) { self.node = node }

    public func hasVolume(root: String) -> Bool { false }

    public func fetchVolumeLocal(root: String) async -> VolumePayload? {
        guard let node else { return nil }
        let result = await node.fetchVolume(rootCID: root)
        guard !result.isEmpty else { return nil }
        return VolumePayload(root: root, entries: result)
    }

    public func storeVolumeLocal(_ payload: VolumePayload) throws {}

    public func pin(root: String, owner: String, count: Int, ttl: Duration?) async throws {
        guard let node else { return }
        let expiry: UInt64
        if let ttl {
            expiry = UInt64(Date().timeIntervalSince1970) + UInt64(ttl.components.seconds)
        } else {
            expiry = UInt64(Date().timeIntervalSince1970) + 86400
        }
        await node.publishPinAnnounce(rootCID: root, selector: "/", expiry: expiry, signature: Data(), fee: 0)
    }

    public func unpin(root: String, owner: String, count: Int) {}
    public func unpinAll(owner: String) {}
    public func owners(root: String) -> Set<String> { [] }
    public func evictUnpinned() throws -> Int { 0 }
}
