import Lattice
import Foundation
import Ivy

public struct NodeResourceConfig: Sendable {
    public let memoryBudgetGB: Double
    public let diskBudgetGB: Double
    public let mempoolBudgetMB: Double
    public let miningBatchSize: UInt64
    public let nodeIdentityHash: [UInt8]?

    public init(
        memoryBudgetGB: Double = 0.25,
        diskBudgetGB: Double = 1.0,
        mempoolBudgetMB: Double = 64.0,
        miningBatchSize: UInt64 = 10_000,
        nodeIdentityHash: [UInt8]? = nil
    ) {
        self.memoryBudgetGB = memoryBudgetGB
        self.diskBudgetGB = diskBudgetGB
        self.mempoolBudgetMB = mempoolBudgetMB
        self.miningBatchSize = miningBatchSize
        self.nodeIdentityHash = nodeIdentityHash
    }

    public static let `default` = NodeResourceConfig()

    public static let light = NodeResourceConfig(
        memoryBudgetGB: 0.064,
        diskBudgetGB: 0.25,
        mempoolBudgetMB: 16.0,
        miningBatchSize: 5_000
    )

    public static let heavy = NodeResourceConfig(
        memoryBudgetGB: 1.0,
        diskBudgetGB: 10.0,
        mempoolBudgetMB: 256.0,
        miningBatchSize: 50_000
    )

    public func memoryBytesPerChain(chainCount: Int) -> Int {
        let total = Int(memoryBudgetGB * 1_073_741_824)
        return max(total / max(chainCount, 1), 1_048_576)
    }

    public func diskBytesPerChain(chainCount: Int) -> Int {
        let total = Int(diskBudgetGB * 1_073_741_824)
        return max(total / max(chainCount, 1), 1_048_576)
    }

    /// Total disk budget for the node's shared content-addressed store.
    /// All chains share this budget; per-chain protection pins decide what survives LRU.
    /// A budget of 0 is honored as-is (stateless mode); otherwise we floor at 1 MiB to avoid
    /// accidentally configuring a useless sub-MiB store.
    public func totalDiskBytes() -> Int {
        if diskBudgetGB <= 0 { return 0 }
        return max(Int(diskBudgetGB * 1_073_741_824), 1_048_576)
    }

    public func mempoolSizePerChain(chainCount: Int) -> Int {
        let totalBytes = Int(mempoolBudgetMB * 1_048_576)
        let estimatedTxSize = 512
        let totalTxs = totalBytes / estimatedTxSize
        return max(totalTxs / max(chainCount, 1), 100)
    }

    /// Max storage entries for the verified distance store (one per CID).
    /// Derived from disk budget assuming ~4KB average entry size.
    public var maxStorageEntries: Int {
        max(Int(diskBudgetGB * 1_073_741_824) / 4096, 1000)
    }

    public func withIdentity(publicKey: String) -> NodeResourceConfig {
        NodeResourceConfig(
            memoryBudgetGB: memoryBudgetGB,
            diskBudgetGB: diskBudgetGB,
            mempoolBudgetMB: mempoolBudgetMB,
            miningBatchSize: miningBatchSize,
            nodeIdentityHash: Router.hash(publicKey)
        )
    }

    public static func autosize(
        dataDir: URL,
        maxMemoryGB: Double? = nil,
        maxDiskGB: Double? = nil
    ) -> NodeResourceConfig {
        let systemRAMBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let systemRAMGB = systemRAMBytes / 1_073_741_824

        let freeDiskBytes = (try? FileManager.default.attributesOfFileSystem(
            forPath: dataDir.path
        )[.systemFreeSize] as? Int) ?? 0
        let freeDiskGB = Double(freeDiskBytes) / 1_073_741_824

        // Memory: 25% of system RAM, minimum 128MB, reserve 1GB for OS
        var memGB = max((systemRAMGB - 1.0) * 0.25, 0.128)
        if let cap = maxMemoryGB { memGB = min(memGB, cap) }

        // Disk: 50% of free disk, minimum 1GB, reserve 5GB for OS
        var diskGB = max((freeDiskGB - 5.0) * 0.50, 1.0)
        if let cap = maxDiskGB { diskGB = min(diskGB, cap) }

        // Mempool: 1% of memory budget, minimum 16MB
        let mempoolMB = max(memGB * 1024 * 0.01, 16.0)

        // Mining batch: scale with available cores
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let batch = UInt64(max(cores * 5_000, 10_000))

        return NodeResourceConfig(
            memoryBudgetGB: memGB,
            diskBudgetGB: diskGB,
            mempoolBudgetMB: mempoolMB,
            miningBatchSize: batch
        )
    }
}
