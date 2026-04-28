import Lattice
import Foundation
import Ivy
import VolumeBroker

func deterministicPort(basePort: UInt16, directory: String) -> UInt16 {
    let hash = directory.utf8.reduce(0) { ($0 &* 31) &+ UInt16($1) }
    return basePort &+ 1 &+ (hash % 1000)
}

@discardableResult
func startChildDiscoveryLoop(node: LatticeNode, config: LatticeNodeConfig, basePort: UInt16) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let childDirs = await node.lattice.nexus.childDirectories()
            for dir in childDirs {
                if await node.network(for: dir) == nil {
                    let port = deterministicPort(basePort: basePort, directory: dir)
                    let childConfig = IvyConfig(
                        publicKey: config.publicKey,
                        listenPort: port,
                        enableLocalDiscovery: config.enableLocalDiscovery
                    )
                    try? await node.registerChainNetwork(directory: dir, config: childConfig)
                    let log = NodeLogger("discovery")
                    log.info("Registered child chain: \(dir) on port \(port)")
                }
            }
        }
    }
}

@discardableResult
func startMempoolLoop(node: LatticeNode) -> Task<Void, Never> {
    Task {
        // Only run tx_history pruning every N mempool-loop ticks so we're not
        // hitting SQLite with a DELETE every 60s on every chain.
        var tickCount = 0
        let txHistoryPruneEvery = 10 // ~every 10 minutes at the 60s cadence
        // Keep the last ~1 day of foreign-address tx history so RPC lookups for
        // recently-seen addresses still resolve; older rows are dropped because
        // the only *required* history is the node's own (rebuilt at startup).
        let txHistoryRetentionBlocks: UInt64 = 8640 // ~24h at 10s blocks
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await node.pruneExpiredTransactions()
            await node.sweepPeerTracking()
            for directory in await node.allDirectories() {
                if let network = await node.network(for: directory) {
                    let _ = try? await network.diskBroker.evictUnpinned()
                }
            }
            tickCount += 1
            if tickCount % txHistoryPruneEvery == 0 {
                await node.pruneTransactionHistory(retentionBlocks: txHistoryRetentionBlocks)
            }
        }
    }
}

/// Checkpoint WAL + run incremental vacuum on every chain's SQLite store.
/// Slow cadence — WAL truncation is cheap but not free, and incremental
/// vacuum is IO-heavy. Once per hour is plenty to keep the WAL from
/// ballooning and the DB file from drifting away from its logical size
/// after tx_history / state_diffs prune passes (UNSTOPPABLE_LATTICE S7).
@discardableResult
func startStorageMaintenanceLoop(node: LatticeNode) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600)) // 1 hour
            await node.maintainStorage()
        }
    }
}

/// Re-announce all pinned Volumes periodically.
/// Pin announcements expire after 24 hours; this re-announces every 6 hours
/// so peers can continue discovering us as a provider for data we hold.
@discardableResult
func startPinReannounceLoop(node: LatticeNode) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(21600)) // 6 hours
            for directory in await node.allDirectories() {
                if let network = await node.network(for: directory) {
                    await network.ivy.evict()
                }
                await node.reannouncePinnedVolumes(directory: directory)
            }
            await node.demoteLowScoringAnchors()
        }
    }
}
