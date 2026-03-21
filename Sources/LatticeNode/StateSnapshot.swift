import Lattice
import Foundation
import cashew
import Acorn

public struct StateSnapshot: Codable, Sendable {
    public let blockHash: String
    public let blockIndex: UInt64
    public let timestamp: Int64
    public let homesteadCID: String
    public let frontierCID: String
    public let specCID: String
    public let difficulty: String

    public init(block: Block, blockHash: String) {
        self.blockHash = blockHash
        self.blockIndex = block.index
        self.timestamp = block.timestamp
        self.homesteadCID = block.homestead.rawCID
        self.frontierCID = block.frontier.rawCID
        self.specCID = block.spec.rawCID
        self.difficulty = block.difficulty.toPrefixedHexString()
    }
}

public actor SnapshotManager {
    private let storagePath: URL
    private let snapshotInterval: UInt64

    public init(storagePath: URL, snapshotInterval: UInt64 = 1000) {
        self.storagePath = storagePath
        self.snapshotInterval = snapshotInterval
    }

    public func shouldSnapshot(blockIndex: UInt64) -> Bool {
        blockIndex > 0 && blockIndex % snapshotInterval == 0
    }

    public func saveSnapshot(_ snapshot: StateSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let path = snapshotPath(for: snapshot.blockIndex)
        try FileManager.default.createDirectory(
            at: storagePath.appendingPathComponent("snapshots"),
            withIntermediateDirectories: true
        )
        try data.write(to: path)
    }

    public func loadSnapshot(blockIndex: UInt64) throws -> StateSnapshot? {
        let path = snapshotPath(for: blockIndex)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(StateSnapshot.self, from: data)
    }

    public func latestSnapshot() throws -> StateSnapshot? {
        let snapshotsDir = storagePath.appendingPathComponent("snapshots")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path) else {
            return nil
        }
        let indices = files.compactMap { name -> UInt64? in
            guard name.hasSuffix(".json") else { return nil }
            return UInt64(name.dropLast(5))
        }.sorted(by: >)
        guard let latest = indices.first else { return nil }
        return try loadSnapshot(blockIndex: latest)
    }

    private func snapshotPath(for blockIndex: UInt64) -> URL {
        storagePath
            .appendingPathComponent("snapshots")
            .appendingPathComponent("\(blockIndex).json")
    }
}
