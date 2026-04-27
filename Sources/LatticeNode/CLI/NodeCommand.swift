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

    @Flag(name: .long, help: "Enable mDNS local peer discovery (off by default; headless/server deployments don't need it)")
    var localDiscovery: Bool = false

    @Flag(name: .long, help: "Enable cookie-based RPC authentication")
    var rpcAuth: Bool = false

    @Flag(name: .long, help: "Disable DNS seed resolution")
    var noDnsSeeds: Bool = false

    @Flag(name: .long, help: "Discovery-only mode: relay peers without syncing or mining")
    var discoveryOnly: Bool = false

    @Flag(name: .long, help: "Stateless mode: disk CAS budget forced to 0 (validates from peers; cannot mine)")
    var stateless: Bool = false

    @Option(name: .long, help: "Maximum peer connections (default 128, discovery-only 512)")
    var maxPeers: Int?

    @Option(name: .long, help: "Default finality confirmations for all chains")
    var finalityConfirmations: UInt64 = 6

    @Option(name: .long, parsing: .singleValue, help: "Per-chain finality (chain:confirmations, repeatable)")
    var finalityPolicy: [String] = []

    @Option(name: .long, help: "Path to JSON config file (overrides CLI defaults)")
    var config: String?

    @Option(name: .long, help: "Password for encrypting/decrypting the node private key")
    var keyPassword: String?

    func run() async throws {
        #if canImport(Darwin)
        setbuf(Darwin.stdout, nil)
        #endif

        // Load config file if provided — values override CLI defaults
        var effectivePort = port
        var effectiveDataDir = dataDir
        var effectivePeer = peer
        var effectiveMine = mine
        var effectiveSubscribe = subscribe
        var effectiveMemory = memory
        var effectiveDisk = disk
        var effectiveMempool = mempool
        var effectiveMiningBatch = miningBatch
        var effectiveAutosize = autosize
        var effectiveMaxMemory = maxMemory
        var effectiveMaxDisk = maxDisk
        var effectiveRpcPort = rpcPort
        var effectiveRpcBind = rpcBind
        var effectiveRpcAllowedOrigin = rpcAllowedOrigin
        var effectiveLocalDiscovery = localDiscovery
        var effectiveRpcAuth = rpcAuth
        var effectiveNoDnsSeeds = noDnsSeeds
        var effectiveDiscoveryOnly = discoveryOnly
        var effectiveStateless = stateless
        var effectiveMaxPeersOpt = maxPeers
        var effectiveFinalityConfirmations = finalityConfirmations
        var effectiveFinalityPolicy = finalityPolicy
        var effectiveKeyPassword = keyPassword

        if let configPath = config {
            let configURL = URL(fileURLWithPath: configPath)
            if let configData = try? Data(contentsOf: configURL),
               let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                if let v = json["port"] as? Int { effectivePort = UInt16(v) }
                if let v = json["dataDir"] as? String { effectiveDataDir = v }
                if let v = json["memory"] as? Double { effectiveMemory = v }
                if let v = json["disk"] as? Double { effectiveDisk = v }
                if let v = json["mempool"] as? Double { effectiveMempool = v }
                if let v = json["miningBatch"] as? Int { effectiveMiningBatch = UInt64(v) }
                if let v = json["rpcPort"] as? Int { effectiveRpcPort = UInt16(v) }
                if let v = json["rpcBind"] as? String { effectiveRpcBind = v }
                if let v = json["rpcAllowedOrigin"] as? String { effectiveRpcAllowedOrigin = v }
                if let v = json["rpcAuth"] as? Bool { effectiveRpcAuth = v }
                if let v = json["localDiscovery"] as? Bool { effectiveLocalDiscovery = v }
                else if let v = json["noDiscovery"] as? Bool { effectiveLocalDiscovery = !v }
                if let v = json["noDnsSeeds"] as? Bool { effectiveNoDnsSeeds = v }
                if let v = json["discoveryOnly"] as? Bool { effectiveDiscoveryOnly = v }
                if let v = json["stateless"] as? Bool { effectiveStateless = v }
                if let v = json["maxPeers"] as? Int { effectiveMaxPeersOpt = v }
                if let v = json["autosize"] as? Bool { effectiveAutosize = v }
                if let v = json["finalityConfirmations"] as? Int { effectiveFinalityConfirmations = UInt64(v) }
                if let v = json["keyPassword"] as? String { effectiveKeyPassword = v }
                if let peers = json["peers"] as? [String] { effectivePeer = peers }
                if let chains = json["mine"] as? [String] { effectiveMine = chains }
                if let subs = json["subscribe"] as? [String] { effectiveSubscribe = subs }
                if let policies = json["finalityPolicy"] as? [String] { effectiveFinalityPolicy = policies }
            } else {
                print("  WARNING: Could not load config file: \(configPath)")
            }
        }

        let dataDirURL = URL(fileURLWithPath: effectiveDataDir)
        let bootstrapPeers = effectivePeer.compactMap { parsePeer($0) }

        var subscribedChains = ArrayTrie<Bool>()
        subscribedChains.set(["Nexus"], value: true)
        for sub in effectiveSubscribe {
            let path = sub.split(separator: "/").map(String.init)
            // Subscribing to a child implies subscribing to every ancestor.
            for depth in 1...path.count {
                subscribedChains.set(Array(path.prefix(depth)), value: true)
            }
        }

        if effectiveStateless && !effectiveMine.isEmpty {
            print("  FATAL: --stateless is incompatible with --mine (miners need full state).")
            throw ExitCode.failure
        }
        if effectiveStateless {
            effectiveDisk = 0.0
        }

        let mineChains = Set(effectiveMine)

        let effectiveMaxPeers = effectiveMaxPeersOpt ?? (effectiveDiscoveryOnly
            ? BootstrapPeers.maxPeerConnectionsDiscovery
            : BootstrapPeers.maxPeerConnections)

        let nodeArgs = NodeArgs(
            port: effectivePort,
            dataDir: dataDirURL,
            bootstrapPeers: bootstrapPeers,
            mineChains: mineChains,
            subscribedChains: subscribedChains,
            memoryGB: effectiveMemory,
            diskGB: effectiveDisk,
            mempoolMB: effectiveMempool,
            miningBatch: effectiveMiningBatch,
            autosize: effectiveAutosize,
            maxMemoryGB: effectiveMaxMemory,
            maxDiskGB: effectiveMaxDisk,
            rpcPort: effectiveRpcPort,
            rpcBindAddress: effectiveRpcBind,
            enableDiscovery: effectiveLocalDiscovery,
            rpcAllowedOrigin: effectiveRpcAllowedOrigin,
            discoveryOnly: effectiveDiscoveryOnly,
            maxPeerConnections: effectiveMaxPeersOpt
        )

        let state = NodeState(subscriptions: subscribedChains, nodeArgs: nodeArgs)
        let identity = try loadOrCreateIdentity(dataDir: dataDirURL, password: effectiveKeyPassword)
        guard let privateKey = identity.privateKey else {
            print("  FATAL: Could not decrypt private key. Provide --key-password.")
            throw ExitCode.failure
        }

        print()
        if effectiveDiscoveryOnly {
            print("  Lattice Discovery Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ========================")
        } else {
            print("  Lattice Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ============")
        }
        print("  Public key:  \(String(identity.publicKey.prefix(32)))...")
        print("  Data dir:    \(dataDirURL.path)")
        print("  Listen port: \(effectivePort)")
        print("  Max peers:   \(effectiveMaxPeers)")
        print("  Discovery:   \(effectiveLocalDiscovery ? "enabled" : "disabled")")
        if !bootstrapPeers.isEmpty {
            print("  Peers:       \(bootstrapPeers.count) bootstrap peer(s)")
        }
        print()

        let resources = effectiveDiscoveryOnly ? NodeResourceConfig.light : configureResources(nodeArgs)
        var updatedArgs = nodeArgs
        updatedArgs.memoryGB = resources.memoryBudgetGB
        updatedArgs.diskGB = resources.diskBudgetGB
        updatedArgs.mempoolMB = resources.mempoolBudgetMB
        updatedArgs.miningBatch = resources.miningBatchSize
        await state.updateArgs(updatedArgs)

        if !effectiveDiscoveryOnly {
            print("  Memory:      \(String(format: "%.2f", resources.memoryBudgetGB)) GB")
            if effectiveStateless {
                print("  Disk:        0.00 GB (stateless)")
            } else {
                print("  Disk:        \(String(format: "%.2f", resources.diskBudgetGB)) GB")
            }
            print("  Mempool:     \(String(format: "%.0f", resources.mempoolBudgetMB)) MB")
            print("  Mine batch:  \(resources.miningBatchSize)")
        }

        var allPeers = await loadPeers(dataDirURL: dataDirURL, bootstrapPeers: bootstrapPeers)
        if !effectiveNoDnsSeeds {
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
            policies: effectiveFinalityPolicy.compactMap { FinalityPolicy.parse($0) },
            defaultConfirmations: effectiveFinalityConfirmations
        )

        let currentSubscriptions = await state.subscriptions
        let nodeConfig = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: privateKey,
            listenPort: effectivePort,
            bootstrapPeers: allPeers,
            storagePath: dataDirURL,
            enableLocalDiscovery: effectiveLocalDiscovery,
            persistInterval: 100,
            subscribedChains: currentSubscriptions,
            resources: resources,
            finality: parsedFinality,
            maxPeerConnections: effectiveMaxPeers,
            discoveryOnly: effectiveDiscoveryOnly
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

        if !effectiveDiscoveryOnly {
            try? await node.restoreChildChains()
        }
        try await node.start()

        if !effectiveDiscoveryOnly {
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

        var rpcServer: RPCServer? = nil
        var rpcTask: Task<Void, any Error>? = nil
        if !effectiveDiscoveryOnly, let rpcPort = effectiveRpcPort {
            var cookieAuth: CookieAuth? = nil
            if effectiveRpcAuth {
                let cookiePath = dataDirURL.appendingPathComponent(".cookie")
                cookieAuth = try CookieAuth.generate(at: cookiePath)
                print("  RPC auth:    cookie (\(cookiePath.path))")
            }
            let server = RPCServer(node: node, port: rpcPort, bindAddress: effectiveRpcBind, allowedOrigin: effectiveRpcAllowedOrigin, auth: cookieAuth)
            rpcServer = server
            rpcTask = Task { try await server.run() }
            print("  RPC server:  http://localhost:\(rpcPort)/api/chain/info")
        }

        var backgroundTasks: [Task<Void, Never>] = []
        if effectiveDiscoveryOnly {
            // Seed crawler: scores peers and writes seeds.txt for DNS infrastructure
            if let network = await node.network(for: NexusGenesis.config.spec.directory) {
                let crawler = SeedCrawler(ivy: network.ivy, dataDir: dataDirURL)
                backgroundTasks.append(Task { await crawler.start() })
                print("  Seed crawler: writing \(dataDirURL.path)/seeds.txt")
            }
        } else {
            for chain in mineChains {
                await node.startMining(directory: chain)
                print("  Mining started on \(chain)")
            }
            backgroundTasks.append(startChildDiscoveryLoop(node: node, config: nodeConfig, basePort: effectivePort))
            backgroundTasks.append(startMempoolLoop(node: node))
            backgroundTasks.append(startPinReannounceLoop(node: node))
        }

        let peerRefreshTask = Task { await node.startPeerRefresh() }

        if effectiveDiscoveryOnly {
            print("  Discovery node running (\(effectiveMaxPeers) max peers). Type 'quit' to stop.")
        } else if !mineChains.isEmpty {
            print("  Node running. Type 'status' for chain info, 'quit' to stop.")
        } else {
            print("  Node running. Type 'mine start' to begin mining, 'status' for info.")
        }
        print()

        let peerStore = PeerStore(dataDir: dataDirURL)
        let shutdownRequested = ShutdownFlag()

        let signalSources = installSignalHandlers {
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
        withExtendedLifetime(signalSources) {}

        print("\n  Shutting down...")
        peerRefreshTask.cancel()
        await rpcServer?.shutdown()
        rpcTask?.cancel()
        for task in backgroundTasks { task.cancel() }

        if !effectiveDiscoveryOnly {
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

private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> (DispatchSourceSignal, DispatchSourceSignal) {
    let queue = DispatchQueue(label: "lattice.signal")
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let src1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    let src2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    src1.setEventHandler(handler: handler)
    src2.setEventHandler(handler: handler)
    src1.resume()
    src2.resume()
    return (src1, src2)
}
