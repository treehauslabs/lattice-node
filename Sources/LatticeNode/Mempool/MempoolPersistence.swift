import Foundation
import Lattice

public struct SerializedTransaction: Codable, Sendable {
    public let signatures: [String: String]
    public let bodyCID: String

    public init(signatures: [String: String], bodyCID: String) {
        self.signatures = signatures
        self.bodyCID = bodyCID
    }
}

public struct MempoolPersistence: Sendable {
    public let storagePath: URL

    public init(dataDir: URL) {
        self.storagePath = dataDir.appendingPathComponent("mempool.json")
    }

    public func save(transactions: [Transaction]) throws {
        let serialized = transactions.map {
            SerializedTransaction(signatures: $0.signatures, bodyCID: $0.body.rawCID)
        }
        let data = try JSONEncoder().encode(serialized)
        try data.write(to: storagePath, options: .atomic)
    }

    public func load() -> [SerializedTransaction] {
        guard let data = try? Data(contentsOf: storagePath) else { return [] }
        return (try? JSONDecoder().decode([SerializedTransaction].self, from: data)) ?? []
    }

    public func delete() {
        try? FileManager.default.removeItem(at: storagePath)
    }
}
