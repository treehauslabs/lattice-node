import Foundation
import Lattice

public struct SerializedTransaction: Codable, Sendable {
    public let signatures: [String: String]
    public let bodyCID: String
    public let bodyData: String

    public init(signatures: [String: String], bodyCID: String, bodyData: String) {
        self.signatures = signatures
        self.bodyCID = bodyCID
        self.bodyData = bodyData
    }
}

public struct MempoolPersistence: Sendable {
    public let storagePath: URL

    public init(dataDir: URL) {
        self.storagePath = dataDir.appendingPathComponent("mempool.json")
    }

    public func save(transactions: [Transaction]) throws {
        var serialized: [SerializedTransaction] = []
        for tx in transactions {
            guard let bodyData = tx.body.node?.toData() else { continue }
            serialized.append(SerializedTransaction(
                signatures: tx.signatures,
                bodyCID: tx.body.rawCID,
                bodyData: bodyData.map { String(format: "%02x", $0) }.joined()
            ))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(serialized)
        try data.write(to: storagePath, options: .atomic)
    }

    public func load() -> [SerializedTransaction] {
        guard let data = try? Data(contentsOf: storagePath) else { return [] }
        guard let decoded = try? JSONDecoder().decode([SerializedTransaction].self, from: data) else { return [] }
        return decoded
    }

    public func delete() {
        try? FileManager.default.removeItem(at: storagePath)
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: storagePath.path)
    }
}
