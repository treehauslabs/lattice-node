import Lattice
import Foundation

public actor HealthCheck {
    private let path: URL
    private let interval: Duration
    private var task: Task<Void, Never>?
    private var chainHeight: UInt64 = 0
    private var peerCount: Int = 0
    private var lastBlockTime: Date?

    public init(dataDir: URL, interval: Duration = .seconds(10)) {
        self.path = dataDir.appendingPathComponent("health")
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.writeHealth()
                try? await Task.sleep(for: self?.interval ?? .seconds(10))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func update(chainHeight: UInt64, peerCount: Int) {
        self.chainHeight = chainHeight
        self.peerCount = peerCount
        self.lastBlockTime = Date()
    }

    private func writeHealth() {
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = isStale() ? "STALE" : "OK"
        let content = """
        status: \(stale)
        timestamp: \(now)
        chain_height: \(chainHeight)
        peers: \(peerCount)
        last_block: \(lastBlockTime.map { ISO8601DateFormatter().string(from: $0) } ?? "never")
        """
        if let data = content.data(using: .utf8) {
            FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private func isStale() -> Bool {
        guard let last = lastBlockTime else { return chainHeight == 0 }
        return Date().timeIntervalSince(last) > 300
    }
}
