import Foundation
import Ivy

public actor PeerStore {
    private let path: URL

    public init(dataDir: URL) {
        self.path = dataDir.appendingPathComponent("peers.json")
    }

    public func save(_ peers: [PeerEndpoint]) {
        let entries = peers.map { PeerEntry(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: path)
    }

    public func load() -> [PeerEndpoint] {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let entries = try? JSONDecoder().decode([PeerEntry].self, from: data) else {
            return []
        }
        return entries.map { PeerEndpoint(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
    }
}

private struct PeerEntry: Codable {
    let publicKey: String
    let host: String
    let port: UInt16
}
