import ArgumentParser
import Foundation
import Synchronization
import Lattice
import Ivy
import ArrayTrie
import cashew

let LatticeNodeVersion = LatticeProtocol.nodeVersion
let ProtocolVersion = LatticeProtocol.version

struct NodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "node",
        abstract: "Run the Lattice node daemon"
    )

    @Option(name: .long, help: "P2P listen port")
    var port: UInt16 = 4001

    @Option(name: .long, help: "Storage directory")
    var dataDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice").path

    @Option(name: .long, parsing: .singleValue, help: "Bootstrap peer (pubKey@host:port, repeatable)")
    var peer: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Mine chain on boot (repeatable)")
    var mine: [String] = []

    @Option(name: .long, parsing: .singleValue, help: "Subscribe to chain path (repeatable)")
    var subscribe: [String] = []

    @Option(name: .long, help: "Memory for CAS cache in GB")
    var memory: Double = 0.25

    @Option(name: .long, help: "Disk for CAS storage in GB")
    var disk: Double = 1.0

    @Option(name: .long, help: "Mempool memory in MB")
    var mempool: Double = 64.0

    @Option(name: .long, help: "Nonces per mining batch")
    var miningBatch: UInt64 = 10_000

    @Flag(name: .long, help: "Auto-detect system resources")
    var autosize: Bool = false

    @Option(name: .long, help: "Cap for autosize memory in GB")
    var maxMemory: Double?

    @Option(name: .long, help: "Cap for autosize disk in GB")
    var maxDisk: Double?

    @Option(name: .long, help: "Enable JSON RPC server on port")
    var rpcPort: UInt16?

    @Option(name: .long, help: "RPC bind address")
    var rpcBind: String = "127.0.0.1"

    @Option(name: .long, help: "CORS allowed origin")
    var rpcAllowedOrigin: String = "http://127.0.0.1"

    @Flag(name: .long, help: "Disable mDNS local peer discovery")
    var noDiscovery: Bool = false

    @Flag(name: .long, help: "Enable cookie-based RPC authentication")
    var rpcAuth: Bool = false

    @Flag(name: .long, help: "Disable DNS seed resolution")
    var noDnsSeeds: Bool = false

    @Flag(name: .long, help: "Discovery-only mode: relay peers without syncing or mining")
    var discoveryOnly: Bool = false

    @Option(name: .long, help: "Maximum peer connections (default 128, discovery-only 512)")
    var maxPeers: Int?

    @Option(name: .long, help: "Default finality confirmations for all chains")
    var finalityConfirmations: UInt64 = 6

    @Option(name: .long, parsing: .singleValue, help: "Per-chain finality (chain:confirmations, repeatable)")
    var finalityPolicy: [String] = []

    func run() async throws {
        #if canImport(Darwin)
        setbuf(Darwin.stdout, nil)
        #endif

        let dataDirURL = URL(fileURLWithPath: dataDir)
        let bootstrapPeers = peer.compactMap { parsePeer($0) }

        var subscribedChains = ArrayTrie<Bool>()
        subscribedChains.set(["Nexus"], value: true)
        for sub in subscribe {
            let path = sub.split(separator: "/").map(String.init)
            subscribedChains.set(path, value: true)
        }

        let mineChains = Set(mine)

        let effectiveMaxPeers = maxPeers ?? (discoveryOnly
            ? BootstrapPeers.maxPeerConnectionsDiscovery
            : BootstrapPeers.maxPeerConnections)

        let nodeArgs = NodeArgs(
            port: port,
            dataDir: dataDirURL,
            bootstrapPeers: bootstrapPeers,
            mineChains: mineChains,
            subscribedChains: subscribedChains,
            memoryGB: memory,
            diskGB: disk,
            mempoolMB: mempool,
            miningBatch: miningBatch,
            autosize: autosize,
            maxMemoryGB: maxMemory,
            maxDiskGB: maxDisk,
            rpcPort: rpcPort,
            rpcBindAddress: rpcBind,
            enableDiscovery: !noDiscovery,
            rpcAllowedOrigin: rpcAllowedOrigin,
            discoveryOnly: discoveryOnly,
            maxPeerConnections: maxPeers
        )

        let state = NodeState(subscriptions: subscribedChains, nodeArgs: nodeArgs)
        let identity = try loadOrCreateIdentity(dataDir: dataDirURL)

        print()
        if discoveryOnly {
            print("  Lattice Discovery Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ========================")
        } else {
            print("  Lattice Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ============")
        }
        print("  Public key:  \(String(identity.publicKey.prefix(32)))...")
        print("  Data dir:    \(dataDirURL.path)")
        print("  Listen port: \(port)")
        print("  Max peers:   \(effectiveMaxPeers)")
        print("  Discovery:   \(!noDiscovery ? "enabled" : "disabled")")
        if !bootstrapPeers.isEmpty {
            print("  Peers:       \(bootstrapPeers.count) bootstrap peer(s)")
        }
        print()

        let resources = discoveryOnly ? NodeResourceConfig.light : configureResources(nodeArgs)
        var updatedArgs = nodeArgs
        updatedArgs.memoryGB = resources.memoryBudgetGB
        updatedArgs.diskGB = resources.diskBudgetGB
        updatedArgs.mempoolMB = resources.mempoolBudgetMB
        updatedArgs.miningBatch = resources.miningBatchSize
        await state.updateArgs(updatedArgs)

        if !discoveryOnly {
            print("  Memory:      \(String(format: "%.2f", resources.memoryBudgetGB)) GB")
            print("  Disk:        \(String(format: "%.2f", resources.diskBudgetGB)) GB")
            print("  Mempool:     \(String(format: "%.0f", resources.mempoolBudgetMB)) MB")
            print("  Mine batch:  \(resources.miningBatchSize)")
        }

        var allPeers = await loadPeers(dataDirURL: dataDirURL, bootstrapPeers: bootstrapPeers)
        if !noDnsSeeds {
            let dnsResolved = await DNSSeeds.resolve()
            if !dnsResolved.isEmpty {
                let existingKeys = Set(allPeers.map { $0.publicKey })
                for peer in dnsResolved where !existingKeys.contains(peer.publicKey) {
                    allPeers.append(peer)
                }
                print("  DNS seeds:   \(dnsResolved.count) peer(s) resolved")
            }
        }
        if !allPeers.isEmpty {
            let peerStore = PeerStore(dataDir: dataDirURL)
            let savedCount = await peerStore.load().count
            print("  Bootstrap:   \(allPeers.count) peer(s) (\(savedCount) persisted)")
        }

        let parsedFinality = FinalityConfig(
            policies: finalityPolicy.compactMap { FinalityPolicy.parse($0) },
            defaultConfirmations: finalityConfirmations
        )

        let currentSubscriptions = await state.subscriptions
        let nodeConfig = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: identity.privateKey,
            listenPort: port,
            bootstrapPeers: allPeers,
            storagePath: dataDirURL,
            enableLocalDiscovery: !noDiscovery,
            persistInterval: 100,
            subscribedChains: currentSubscriptions,
            resources: resources,
            finality: parsedFinality,
            maxPeerConnections: effectiveMaxPeers,
            discoveryOnly: discoveryOnly
        )

        let node = try await LatticeNode(
            config: nodeConfig,
            genesisConfig: NexusGenesis.config,
            genesisBuilder: NexusGenesis.buildGenesisBlock
        )

        guard NexusGenesis.verifyGenesis(node.genesisResult) else {
            print("  FATAL: Genesis block hash mismatch!")
            print("  Expected: \(NexusGenesis.expectedBlockHash ?? "nil")")
            print("  Got:      \(node.genesisResult.blockHash)")
            print("  This binary may be incompatible with the network.")
            throw ExitCode.failure
        }
        print("  Genesis:     verified (\(String(node.genesisResult.blockHash.prefix(20)))...)")

        if !discoveryOnly {
            try? await node.restoreChildChains()
        }
        try await node.start()

        if !discoveryOnly {
            let mempoolLoader = MempoolPersistence(dataDir: dataDirURL)
            let savedTxs = mempoolLoader.load()
            if !savedTxs.isEmpty {
                let nexusDir = NexusGenesis.config.spec.directory
                if let network = await node.network(for: nexusDir) {
                    var restored = 0
                    for serialized in savedTxs {
                        let bodyHeader = HeaderImpl<TransactionBody>(rawCID: serialized.bodyCID)
                        guard let _ = try? await bodyHeader.resolve(fetcher: network.fetcher).node else { continue }
                        let tx = Transaction(signatures: serialized.signatures, body: bodyHeader)
                        if await network.submitTransaction(tx) { restored += 1 }
                    }
                    if restored > 0 { print("  Mempool:     \(restored)/\(savedTxs.count) transaction(s) restored from CAS") }
                }
                mempoolLoader.delete()
            }

            let genesisHeight = await node.lattice.nexus.chain.getHighestBlockIndex()
            print("  Chain height: \(genesisHeight)")
        }
        print()

        let health = HealthCheck(dataDir: dataDirURL)
        await health.start()

        var rpcTask: Task<Void, any Error>? = nil
        if !discoveryOnly, let rpcPort = rpcPort {
            var cookieAuth: CookieAuth? = nil
            if rpcAuth {
                let cookiePath = dataDirURL.appendingPathComponent(".cookie")
                cookieAuth = try CookieAuth.generate(at: cookiePath)
                print("  RPC auth:    cookie (\(cookiePath.path))")
            }
            let server = RPCServer(node: node, port: rpcPort, bindAddress: rpcBind, allowedOrigin: rpcAllowedOrigin, auth: cookieAuth)
            rpcTask = Task { try await server.run() }
            print("  RPC server:  http://localhost:\(rpcPort)/api/chain/info")
        }

        var backgroundTasks: [Task<Void, Never>] = []
        if !discoveryOnly {
            for chain in mineChains {
                await node.startMining(directory: chain)
                print("  Mining started on \(chain)")
            }
            backgroundTasks.append(startChildDiscoveryLoop(node: node, config: nodeConfig, basePort: port))
            backgroundTasks.append(startMempoolLoop(node: node))
            backgroundTasks.append(startGarbageCollectionLoop(node: node, retentionDepth: nodeConfig.retentionDepth))
        }

        let peerRefreshTask = Task { await node.startPeerRefresh() }

        let healthTask = Task {
            while !Task.isCancelled {
                let peerCount = await node.network(for: "Nexus")?.ivy.connectedPeers.count ?? 0
                if discoveryOnly {
                    await health.update(chainHeight: 0, peerCount: peerCount)
                } else {
                    let height = await node.lattice.nexus.chain.getHighestBlockIndex()
                    await health.update(chainHeight: height, peerCount: peerCount)
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }

        if discoveryOnly {
            print("  Discovery node running (\(effectiveMaxPeers) max peers). Type 'quit' to stop.")
        } else if !mineChains.isEmpty {
            print("  Node running. Type 'status' for chain info, 'quit' to stop.")
        } else {
            print("  Node running. Type 'mine start' to begin mining, 'status' for info.")
        }
        print()

        let peerStore = PeerStore(dataDir: dataDirURL)
        let shutdownRequested = ShutdownFlag()

        installSignalHandlers {
            shutdownRequested.set()
        }

        Task.detached {
            while !shutdownRequested.isSet {
                guard let line = readLine(strippingNewline: true) else {
                    await shutdownRequested.wait()
                    return
                }
                let shouldQuit = await handleCommand(line, node: node, state: state)
                if shouldQuit { break }
            }
            shutdownRequested.set()
        }

        await shutdownRequested.wait()

        print("\n  Shutting down...")
        healthTask.cancel()
        peerRefreshTask.cancel()
        rpcTask?.cancel()
        for task in backgroundTasks { task.cancel() }
        await health.stop()

        if !discoveryOnly {
            let mempoolPersistence = MempoolPersistence(dataDir: dataDirURL)
            let nexusDir = NexusGenesis.config.spec.directory
            if let network = await node.network(for: nexusDir) {
                let txs = await network.nodeMempool.allTransactions()
                if !txs.isEmpty {
                    try? mempoolPersistence.save(transactions: txs)
                    print("  Mempool:     \(txs.count) transaction(s) saved")
                }
            }
        }

        let peers = await node.connectedPeerEndpoints()
        await peerStore.save(peers)
        await node.stop()
        print("  \(peers.count) peer(s) saved. Goodbye.")
    }
}

// MARK: - Helpers

private func configureResources(_ args: NodeArgs) -> NodeResourceConfig {
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

private func loadPeers(dataDirURL: URL, bootstrapPeers: [PeerEndpoint]) async -> [PeerEndpoint] {
    var allPeers = bootstrapPeers
    if allPeers.isEmpty {
        allPeers = BootstrapPeers.nexus
    }
    let peerStore = PeerStore(dataDir: dataDirURL)
    let savedPeers = await peerStore.load()
    let existingKeys = Set(allPeers.map { $0.publicKey })
    for peer in savedPeers where !existingKeys.contains(peer.publicKey) {
        allPeers.append(peer)
    }
    return allPeers
}

func parsePeer(_ s: String) -> PeerEndpoint? {
    let parts = s.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let pubKey = String(parts[0])
    let hostPort = parts[1].split(separator: ":", maxSplits: 1)
    guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
    return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
}

private final class ShutdownFlag: Sendable {
    private let _value = Mutex(false)

    var isSet: Bool { _value.withLock { $0 } }

    func set() { _value.withLock { $0 = true } }

    func wait() async {
        while !isSet {
            try? await Task.sleep(for: .milliseconds(100))
        }
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
