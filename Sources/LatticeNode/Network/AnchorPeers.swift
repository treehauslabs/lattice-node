import Foundation
import Ivy

public actor AnchorPeers {
    private let storagePath: URL
    private var anchors: [PeerEndpoint] = []
    private let maxAnchors: Int = 6

    public init(dataDir: URL) {
        self.storagePath = dataDir.appendingPathComponent("anchors.json")
    }

    public func load() -> [PeerEndpoint] {
        guard let data = try? Data(contentsOf: storagePath),
              let decoded = try? JSONDecoder().decode([StoredPeer].self, from: data) else {
            return []
        }
        anchors = decoded.map { PeerEndpoint(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
        return anchors
    }

    public func update(peers: [PeerEndpoint]) {
        anchors = Array(peers.prefix(maxAnchors))
        let stored = anchors.map { StoredPeer(publicKey: $0.publicKey, host: $0.host, port: $0.port) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storagePath, options: .atomic)
    }

    public var current: [PeerEndpoint] { anchors }
}

private struct StoredPeer: Codable {
    let publicKey: String
    let host: String
    let port: UInt16
}
