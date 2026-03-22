import Lattice
import Foundation
import Ivy

@main
struct LatticeNodeApp {
    static func main() async throws {
        #if canImport(Glibc)
        setbuf(Glibc.stdout!, nil)
        #elseif canImport(Darwin)
        setbuf(Darwin.stdout, nil)
        #endif

        let args = parseArgs()

        if args.showHelp {
            printUsage()
            return
        }
        if args.showVersion {
            print("lattice-node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            return
        }

        let state = NodeState(subscriptions: args.subscribedChains, nodeArgs: args)
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

        let resources = configureResources(args: args)
        var updatedArgs = args
        updatedArgs.memoryGB = resources.memoryBudgetGB
        updatedArgs.diskGB = resources.diskBudgetGB
        updatedArgs.mempoolMB = resources.mempoolBudgetMB
        updatedArgs.miningBatch = resources.miningBatchSize
        await state.updateArgs(updatedArgs)

        print("  Memory:      \(String(format: "%.2f", resources.memoryBudgetGB)) GB")
        print("  Disk:        \(String(format: "%.2f", resources.diskBudgetGB)) GB")
        print("  Mempool:     \(String(format: "%.0f", resources.mempoolBudgetMB)) MB")
        print("  Mine batch:  \(resources.miningBatchSize)")

        let allPeers = await loadPeers(args: args)
        if !allPeers.isEmpty {
            let peerStore = PeerStore(dataDir: args.dataDir)
            let savedCount = await peerStore.load().count
            print("  Bootstrap:   \(allPeers.count) peer(s) (\(savedCount) persisted)")
        }

        let currentSubscriptions = await state.subscriptions
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

        guard NexusGenesis.verifyGenesis(node.genesisResult) else {
            print("  FATAL: Genesis block hash mismatch!")
            print("  Expected: \(NexusGenesis.expectedBlockHash)")
            print("  Got:      \(node.genesisResult.blockHash)")
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

        let healthTask = Task {
            while !Task.isCancelled {
                let height = await node.lattice.nexus.chain.getHighestBlockIndex()
                let peerCount = await node.network(for: "Nexus")?.ivy.connectedPeers.count ?? 0
                await health.update(chainHeight: height, peerCount: peerCount)
                try? await Task.sleep(for: .seconds(10))
            }
        }

        if !args.mineChains.isEmpty {
            print("  Node running. Type 'status' for chain info, 'quit' to stop.")
        } else {
            print("  Node running. Type 'mine start' to begin mining, 'status' for info.")
        }
        print()

        let peerStore = PeerStore(dataDir: args.dataDir)
        let shutdownRequested = ShutdownFlag()

        installSignalHandlers {
            shutdownRequested.set()
        }

        Task.detached {
            while !shutdownRequested.isSet {
                guard let line = readLine(strippingNewline: true) else { break }
                let shouldQuit = await handleCommand(line, node: node, state: state)
                if shouldQuit { break }
            }
            shutdownRequested.set()
        }

        await shutdownRequested.wait()

        print("\n  Shutting down...")
        healthTask.cancel()
        rpcServer?.stop()
        await health.stop()
        let peers = await node.connectedPeerEndpoints()
        await peerStore.save(peers)
        await node.stop()
        print("  State persisted. \(peers.count) peer(s) saved. Goodbye.")
    }
}

private final class ShutdownFlag: Sendable {
    private let _value = LockedValue(false)

    var isSet: Bool { _value.withLock { $0 } }

    func set() { _value.withLock { $0 = true } }

    func wait() async {
        while !isSet {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
    let queue = DispatchQueue(label: "lattice.signal")
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let src1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    let src2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    src1.setEventHandler(handler: handler)
    src2.setEventHandler(handler: handler)
    src1.resume()
    src2.resume()
}

// MARK: - Helpers

private func configureResources(args: NodeArgs) -> NodeResourceConfig {
    if args.autosize {
        print("  Autosize:    ON")
        return NodeResourceConfig.autosize(
            dataDir: args.dataDir,
            maxMemoryGB: args.maxMemoryGB,
            maxDiskGB: args.maxDiskGB
        )
    }
    return NodeResourceConfig(
        memoryBudgetGB: args.memoryGB,
        diskBudgetGB: args.diskGB,
        mempoolBudgetMB: args.mempoolMB,
        miningBatchSize: args.miningBatch
    )
}

private func loadPeers(args: NodeArgs) async -> [PeerEndpoint] {
    var allPeers = args.bootstrapPeers
    if allPeers.isEmpty {
        allPeers = BootstrapPeers.nexus
    }
    let peerStore = PeerStore(dataDir: args.dataDir)
    let savedPeers = await peerStore.load()
    let existingKeys = Set(allPeers.map { $0.publicKey })
    for peer in savedPeers where !existingKeys.contains(peer.publicKey) {
        allPeers.append(peer)
    }
    return allPeers
}

