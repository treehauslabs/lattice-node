import Lattice
import Foundation
import Ivy

func deterministicPort(basePort: UInt16, directory: String) -> UInt16 {
    let hash = directory.utf8.reduce(0) { ($0 &* 31) &+ UInt16($1) }
    return basePort &+ 1 &+ (hash % 1000)
}

func startChildDiscoveryLoop(node: LatticeNode, config: LatticeNodeConfig, basePort: UInt16) {
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
                    print("  [discovery] Registered child chain: \(dir) on port \(port)")
                }
            }
        }
    }
}

func startMempoolExpiryLoop(node: LatticeNode) {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await node.pruneExpiredTransactions()
        }
    }
}

func startStateExpiryLoop(node: LatticeNode, expiryBlocks: UInt64 = 1_000_000) {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
            for directory in await node.allDirectories() {
                guard let store = await node.stateStore(for: directory) else { continue }
                let expiry = StateExpiry(store: store, expiryBlocks: expiryBlocks)
                let height = await store.getHeight() ?? 0
                let expired = await expiry.findExpiredAccounts(currentHeight: height)
                if !expired.isEmpty {
                    await expiry.expireAccounts(expired, atHeight: height)
                    let log = NodeLogger("expiry")
                    log.info("Expired \(expired.count) inactive accounts in \(directory)")
                }
            }
        }
    }
}

func startBatchAuctionLoop(node: LatticeNode) {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            let dir = await node.genesisConfig.spec.directory
            guard let store = await node.stateStore(for: dir) else { continue }
            let height = await store.getHeight() ?? 0

            guard let rows = try? await store.queryGeneralKeys(prefix: "commit:") else { continue }
            var revealedOrders: [BatchAuction.RevealedOrder] = []

            for (key, data) in rows {
                guard let committed = try? JSONDecoder().decode(BatchAuction.CommittedOrder.self, from: data) else { continue }
                guard BatchAuction.canReveal(commitHeight: committed.commitHeight, currentHeight: height) else { continue }
                let revealKey = "reveal:\(committed.commitHash)"
                guard let revealData = await store.getGeneral(key: revealKey) else { continue }
                guard let order = try? JSONDecoder().decode(Order.self, from: revealData) else { continue }
                revealedOrders.append(BatchAuction.RevealedOrder(order: order, salt: ""))
            }

            guard !revealedOrders.isEmpty else { continue }

            let matches = BatchAuction.executeBatch(orders: revealedOrders)
            if !matches.isEmpty {
                let log = NodeLogger("auction")
                log.info("Settled \(matches.count) order match(es) at height \(height)")
                for (key, _) in rows {
                    await store.setGeneral(key: key, value: Data(), atHeight: height)
                }
            }
        }
    }
}

func startStatePruningLoop(node: LatticeNode, retentionDepth: UInt64) {
    Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            for directory in await node.allDirectories() {
                if let store = await node.stateStore(for: directory) {
                    let height = await store.getHeight() ?? 0
                    if height > retentionDepth {
                        await store.pruneDiffs(belowHeight: height - retentionDepth)
                    }
                }
            }
        }
    }
}
