import Foundation
import Lattice

public actor BlockIndex {
    private let stateStore: StateStore?
    private var heightToHash: [UInt64: String] = [:]
    private var hashToHeight: [String: UInt64] = [:]

    public init(storagePath: URL) {
        self.stateStore = nil
    }

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    public func insert(height: UInt64, hash: String) {
        if let oldHash = heightToHash[height] {
            hashToHeight.removeValue(forKey: oldHash)
        }
        heightToHash[height] = hash
        hashToHeight[hash] = height
    }

    public func hash(atHeight height: UInt64) -> String? {
        if let h = heightToHash[height] { return h }
        return nil
    }

    public func height(forHash hash: String) -> UInt64? {
        if let h = hashToHeight[hash] { return h }
        return nil
    }

    public func highestHeight() -> UInt64? {
        heightToHash.keys.max()
    }

    public func save() throws {
        // No-op: StateStore handles persistence via SQLite
    }

    public static func load(from storagePath: URL) throws -> BlockIndex {
        BlockIndex(storagePath: storagePath)
    }

    public func rebuildFrom(_ blocks: [PersistedBlockMeta]) {
        heightToHash.removeAll()
        hashToHeight.removeAll()
        for block in blocks {
            heightToHash[block.blockIndex] = block.blockHash
            hashToHeight[block.blockHash] = block.blockIndex
        }
    }
}
