import Lattice
import Foundation
import Ivy

let args = parseArgs()

if args.showHelp {
    printUsage()
    exit(0)
}

if args.showVersion {
    print("lattice-node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
    exit(0)
}

let sharedState = NodeState(subscriptions: args.subscribedChains, nodeArgs: args)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

Task {
    do {
        let identity = try loadOrCreateIdentity(dataDir: args.dataDir)

        print()
        print("  Lattice Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
        print("  ============")
        print("  Public key:  \(String(identity.publicKey.prefix(32)))...")
        print("  Data dir:    \(args.dataDir.path)")
        print("  Listen port: \(args.port)")
        print("  Discovery:   \(args.enableDiscovery ? "enabled" : "disabled")")
        if !args.bootstrapPeers.isEmpty {
            print("  Peers:       \(args.bootstrapPeers.count) bootstrap peer(s)")
        }
        print()

        let resources: NodeResourceConfig
        if args.autosize {
            resources = NodeResourceConfig.autosize(
                dataDir: args.dataDir,
                maxMemoryGB: args.maxMemoryGB,
                maxDiskGB: args.maxDiskGB
            )
            print("  Autosize:    ON")
        } else {
            resources = NodeResourceConfig(
                memoryBudgetGB: args.memoryGB,
                diskBudgetGB: args.diskGB,
                mempoolBudgetMB: args.mempoolMB,
                miningBatchSize: args.miningBatch
            )
        }

        var updatedArgs = args
        updatedArgs.memoryGB = resources.memoryBudgetGB
        updatedArgs.diskGB = resources.diskBudgetGB
        updatedArgs.mempoolMB = resources.mempoolBudgetMB
        updatedArgs.miningBatch = resources.miningBatchSize
        await sharedState.updateArgs(updatedArgs)

        print("  Memory:      \(String(format: "%.2f", resources.memoryBudgetGB)) GB")
        print("  Disk:        \(String(format: "%.2f", resources.diskBudgetGB)) GB")
        print("  Mempool:     \(String(format: "%.0f", resources.mempoolBudgetMB)) MB")
        print("  Mine batch:  \(resources.miningBatchSize)")

        let peerStore = PeerStore(dataDir: args.dataDir)
        var allPeers = args.bootstrapPeers
        if allPeers.isEmpty {
            allPeers = BootstrapPeers.nexus
        }
        let savedPeers = await peerStore.load()
        let existingKeys = Set(allPeers.map { $0.publicKey })
        for peer in savedPeers where !existingKeys.contains(peer.publicKey) {
            allPeers.append(peer)
        }
        if !allPeers.isEmpty {
            print("  Bootstrap:   \(allPeers.count) peer(s) (\(savedPeers.count) persisted)")
        }

        let currentSubscriptions = await sharedState.subscriptions
        let nodeConfig = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: identity.privateKey,
            listenPort: args.port,
            bootstrapPeers: allPeers,
            storagePath: args.dataDir,
            enableLocalDiscovery: args.enableDiscovery,
            persistInterval: 100,
            subscribedChains: currentSubscriptions,
            resources: resources
        )

        let node = try await LatticeNode(config: nodeConfig, genesisConfig: NexusGenesis.config)

        let genesisResult = node.genesisResult
        let genesisValid = NexusGenesis.verifyGenesis(genesisResult)
        if !genesisValid {
            print("  FATAL: Genesis block hash mismatch!")
            print("  Expected: \(NexusGenesis.expectedBlockHash)")
            print("  Got:      \(genesisResult.blockHash)")
            print("  This binary may be incompatible with the network.")
            exit(1)
        }
        print("  Genesis:     verified (\(String(NexusGenesis.expectedBlockHash.prefix(20)))...)")

        try? await node.restoreChildChains()
        try await node.start()

        let genesisHeight = await node.lattice.nexus.chain.getHighestBlockIndex()
        print("  Chain height: \(genesisHeight)")
        print()

        let health = HealthCheck(dataDir: args.dataDir)
        await health.start()

        var rpcServer: RPCServer? = nil
        if let rpcPort = args.rpcPort {
            let server = RPCServer(node: node, port: rpcPort, allowedOrigin: args.rpcAllowedOrigin)
            try server.start()
            rpcServer = server
            print("  RPC server:  http://localhost:\(rpcPort)/api/chain/info")
        }

        for chain in args.mineChains {
            await node.startMining(directory: chain)
            print("  Mining started on \(chain)")
        }

        startChildDiscoveryLoop(node: node, config: nodeConfig, basePort: args.port)
        startMempoolExpiryLoop(node: node)

        Task {
            while !Task.isCancelled {
                let height = await node.lattice.nexus.chain.getHighestBlockIndex()
                let peerCount = await node.network(for: "Nexus")?.ivy.connectedPeers.count ?? 0
                await health.update(chainHeight: height, peerCount: peerCount)
                try? await Task.sleep(for: .seconds(10))
            }
        }

        let shutdownHandler: @Sendable () -> Void = { [rpcServer] in
            Task {
                print("\n  Shutting down...")
                rpcServer?.stop()
                await health.stop()
                let peers = await node.connectedPeerEndpoints()
                await peerStore.save(peers)
                await node.stop()
                print("  State persisted. \(peers.count) peer(s) saved. Goodbye.")
                exit(0)
            }
        }

        sigintSource.setEventHandler { shutdownHandler() }
        sigtermSource.setEventHandler { shutdownHandler() }
        sigintSource.resume()
        sigtermSource.resume()

        if !args.mineChains.isEmpty {
            print("  Node running. Type 'status' for chain info, 'quit' to stop.")
        } else {
            print("  Node running. Type 'mine start' to begin mining, 'status' for info.")
        }
        print()

        Task.detached {
            while let line = readLine(strippingNewline: true) {
                await handleCommand(line, node: node, state: sharedState, shutdown: shutdownHandler)
            }
        }

    } catch {
        print("  Fatal: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
