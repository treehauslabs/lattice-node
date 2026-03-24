import Lattice
import Foundation
import Ivy

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
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await node.pruneExpiredTransactions()
        }
    }
}

@discardableResult
func startGarbageCollectionLoop(node: LatticeNode, retentionDepth: UInt64, expiryBlocks: UInt64 = 1_000_000) -> Task<Void, Never> {
    Task {
        var gcCycle: UInt64 = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            gcCycle += 1

            for directory in await node.allDirectories() {
                guard let store = await node.stateStore(for: directory) else { continue }
                let height = await store.getHeight() ?? 0

                if height > retentionDepth {
                    await store.pruneDiffs(belowHeight: height - retentionDepth)
                }

                if gcCycle % 12 == 0 {
                    let expiry = StateExpiry(store: store, expiryBlocks: expiryBlocks)
                    let expired = await expiry.findExpiredAccounts(currentHeight: height)
                    if !expired.isEmpty {
                        await expiry.expireAccounts(expired, atHeight: height)
                        let log = NodeLogger("gc")
                        log.info("Expired \(expired.count) inactive accounts in \(directory)")
                    }
                }
            }
        }
    }
}
