import Foundation
import Lattice

public actor BlockIndex {
    private var heightToHash: [UInt64: String] = [:]
    private var hashToHeight: [String: UInt64] = [:]
    private let storagePath: URL

    private struct Entry: Codable {
        let height: UInt64
        let hash: String
    }

    public init(storagePath: URL) {
        self.storagePath = storagePath.appendingPathComponent("block_index.json")
    }

    private init(storagePath: URL, entries: [Entry]) {
        self.storagePath = storagePath.appendingPathComponent("block_index.json")
        for entry in entries {
            heightToHash[entry.height] = entry.hash
            hashToHeight[entry.hash] = entry.height
        }
    }

    public func insert(height: UInt64, hash: String) {
        if let oldHash = heightToHash[height] {
            hashToHeight.removeValue(forKey: oldHash)
        }
        heightToHash[height] = hash
        hashToHeight[hash] = height
    }

    public func hash(atHeight height: UInt64) -> String? {
        heightToHash[height]
    }

    public func height(forHash hash: String) -> UInt64? {
        hashToHeight[hash]
    }

    public func highestHeight() -> UInt64? {
        heightToHash.keys.max()
    }

    public func save() throws {
        let entries = heightToHash.map { Entry(height: $0.key, hash: $0.value) }
            .sorted { $0.height < $1.height }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        let dir = storagePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: storagePath, options: .atomic)
    }

    public static func load(from storagePath: URL) throws -> BlockIndex {
        let filePath = storagePath.appendingPathComponent("block_index.json")
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return BlockIndex(storagePath: storagePath)
        }
        let data = try Data(contentsOf: filePath)
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return BlockIndex(storagePath: storagePath, entries: entries)
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
