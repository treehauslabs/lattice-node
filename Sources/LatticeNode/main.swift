import Lattice
import Foundation
import Ivy
import UInt256
import ArrayTrie

// MARK: - Version

let LatticeNodeVersion = "0.1.0"
let ProtocolVersion: UInt16 = 1

// MARK: - Identity Persistence

struct IdentityFile: Codable {
    let publicKey: String
    let privateKey: String
}

func loadOrCreateIdentity(dataDir: URL) throws -> IdentityFile {
    let path = dataDir.appendingPathComponent("identity.json")
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(IdentityFile.self, from: data)
    }
    let kp = CryptoUtils.generateKeyPair()
    let identity = IdentityFile(publicKey: kp.publicKey, privateKey: kp.privateKey)
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(identity)
    try data.write(to: path)
    #if !os(Windows)
    chmod(path.path, 0o600)
    #endif
    return identity
}

// MARK: - Argument Parsing

struct NodeArgs {
    var port: UInt16 = 4001
    var dataDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice")
    var bootstrapPeers: [PeerEndpoint] = []
    var mineChains: Set<String> = []
    var subscribedChains: ArrayTrie<Bool> = {
        var t = ArrayTrie<Bool>()
        t.set(["Nexus"], value: true)
        return t
    }()
    var memoryGB: Double = 0.25
    var diskGB: Double = 1.0
    var mempoolMB: Double = 64.0
    var miningBatch: UInt64 = 10_000
    var autosize: Bool = false
    var maxMemoryGB: Double? = nil
    var maxDiskGB: Double? = nil
    var rpcPort: UInt16? = nil
    var enableDiscovery: Bool = true
    var showHelp: Bool = false
    var showVersion: Bool = false
    var rpcAllowedOrigin: String = "http://127.0.0.1"
}

func parseArgs() -> NodeArgs {
    var args = NodeArgs()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--port":
            i += 1
            if i < argv.count, let p = UInt16(argv[i]) { args.port = p }
        case "--data-dir":
            i += 1
            if i < argv.count { args.dataDir = URL(fileURLWithPath: argv[i]) }
        case "--peer":
            i += 1
            if i < argv.count, let ep = parsePeer(argv[i]) { args.bootstrapPeers.append(ep) }
        case "--mine":
            i += 1
            if i < argv.count {
                args.mineChains.insert(argv[i])
            } else {
                args.mineChains.insert("Nexus")
            }
        case "--subscribe":
            i += 1
            if i < argv.count {
                let path = argv[i].split(separator: "/").map(String.init)
                args.subscribedChains.set(path, value: true)
            }
        case "--memory":
            i += 1
            if i < argv.count, let v = Double(argv[i]) { args.memoryGB = v }
        case "--disk":
            i += 1
            if i < argv.count, let v = Double(argv[i]) { args.diskGB = v }
        case "--mempool":
            i += 1
            if i < argv.count, let v = Double(argv[i]) { args.mempoolMB = v }
        case "--mining-batch":
            i += 1
            if i < argv.count, let v = UInt64(argv[i]) { args.miningBatch = v }
        case "--autosize":
            args.autosize = true
        case "--max-memory":
            i += 1
            if i < argv.count, let v = Double(argv[i]) { args.maxMemoryGB = v }
        case "--max-disk":
            i += 1
            if i < argv.count, let v = Double(argv[i]) { args.maxDiskGB = v }
        case "--rpc-port":
            i += 1
            if i < argv.count, let p = UInt16(argv[i]) { args.rpcPort = p }
        case "--no-discovery":
            args.enableDiscovery = false
        case "--rpc-allowed-origin":
            i += 1
            if i < argv.count { args.rpcAllowedOrigin = argv[i] }
        case "--help", "-h":
            args.showHelp = true
        case "--version", "-v":
            args.showVersion = true
        default:
            break
        }
        i += 1
    }
    return args
}

func parsePeer(_ s: String) -> PeerEndpoint? {
    let parts = s.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let pubKey = String(parts[0])
    let hostPort = parts[1].split(separator: ":", maxSplits: 1)
    guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
    return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
}

func printUsage() {
    print("""
    lattice-node — Multi-chain Lattice node with merged mining

    USAGE:
      LatticeNode [OPTIONS]

    OPTIONS:
      --port <N>                 P2P listen port (default: 4001)
      --data-dir <path>          Storage directory (default: ~/.lattice)
      --peer <pubKey@host:port>  Bootstrap peer (repeatable)
      --mine <chain>             Mine chain on boot (default: Nexus if no arg; repeatable)
      --subscribe <path>         Subscribe to chain path (e.g. Nexus/Payments; repeatable)
      --memory <GB>              Memory for CAS cache (default: 0.25)
      --disk <GB>                Disk for CAS storage (default: 1.0)
      --mempool <MB>             Mempool memory (default: 64)
      --mining-batch <N>         Nonces per batch (default: 10000)
      --autosize                 Auto-detect system resources (recommended)
      --max-memory <GB>          Cap for autosize memory (optional)
      --max-disk <GB>            Cap for autosize disk (optional)
      --rpc-port <N>             Enable JSON RPC server on port (e.g. 8080)

    SIZING GUIDE:
      2GB RAM / 40GB disk VPS   --memory 0.5  --disk 20
      4GB RAM / 80GB disk VPS   --memory 1.0  --disk 40
      8GB RAM / 160GB disk VPS  --memory 2.0  --disk 80
      Memory: ~25% of system RAM. Disk: ~50% of system disk.
      Budgets are shared across all subscribed chains.
      --no-discovery             Disable mDNS local peer discovery
      --rpc-allowed-origin <url> CORS allowed origin (default: http://127.0.0.1)
      --version, -v              Show version and protocol info
      --help, -h                 Show this help

    INTERACTIVE COMMANDS:
      mine start [chain]         Start mining a chain (default: Nexus)
      mine stop [chain]          Stop mining a chain
      mine list                  Show which chains are being mined
      subscribe <path>           Subscribe to a chain path (e.g. Nexus/Payments)
      unsubscribe <path>         Unsubscribe from a chain path (cannot unsubscribe Nexus)
      subscriptions              List subscribed chain paths
      status                     Show all chain heights, tips, mining, mempool
      chains                     List registered chain directories
      peers                      Show connected peer count
      quit                       Graceful shutdown
    """)
}

// MARK: - Status Display

func printStatus(_ statuses: [LatticeNode.ChainInfo], resources: NodeArgs) {
    print()
    let chainCount = max(statuses.count, 1)
    let memPerChain = resources.memoryGB / Double(chainCount)
    let diskPerChain = resources.diskGB / Double(chainCount)
    print("  Resources: \(fmt(resources.memoryGB)) GB memory / \(fmt(resources.diskGB)) GB disk across \(chainCount) chain(s)")
    print("  Per-chain: \(fmt(memPerChain)) GB memory / \(fmt(diskPerChain)) GB disk / \(Int(resources.mempoolMB)/chainCount) MB mempool")
    print()
    print("  Chain               Height     Tip                    Mining   Mempool")
    print("  -----               ------     ---                    ------   -------")
    for s in statuses {
        let dir = s.directory.padding(toLength: 18, withPad: " ", startingAt: 0)
        let height = String(s.height).padding(toLength: 10, withPad: " ", startingAt: 0)
        let tip = String(s.tip.prefix(22)).padding(toLength: 22, withPad: " ", startingAt: 0)
        let mining = (s.mining ? "YES" : "no").padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(dir) \(height) \(tip) \(mining) \(s.mempoolCount)")
    }
    print()
}

private func fmt(_ gb: Double) -> String {
    String(format: "%.2f", gb)
}

// MARK: - Shared Node State (actor-isolated to prevent data races)

actor NodeState {
    var subscriptions: ArrayTrie<Bool>
    var nodeArgs: NodeArgs

    init(subscriptions: ArrayTrie<Bool>, nodeArgs: NodeArgs) {
        self.subscriptions = subscriptions
        self.nodeArgs = nodeArgs
    }

    func updateArgs(_ args: NodeArgs) {
        self.nodeArgs = args
    }

    func subscribe(path: [String]) {
        subscriptions.set(path, value: true)
    }

    func unsubscribe(path: [String]) {
        subscriptions = subscriptions.deleting(path: path)
    }
}

// MARK: - Command Handler

func handleCommand(_ line: String, node: LatticeNode, state: NodeState, shutdown: @Sendable @escaping () -> Void) async {
    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init)
    guard !parts.isEmpty else { return }

    switch parts[0] {
    case "mine":
        guard parts.count >= 2 else {
            print("  Usage: mine start|stop|list [chain]")
            return
        }
        let chain = parts.count >= 3 ? parts[2] : "Nexus"
        switch parts[1] {
        case "start":
            await node.startMining(directory: chain)
            print("  Mining started on \(chain)")
        case "stop":
            await node.stopMining(directory: chain)
            print("  Mining stopped on \(chain)")
        case "list":
            let statuses = await node.chainStatus()
            let mining = statuses.filter { $0.mining }.map { $0.directory }
            if mining.isEmpty {
                print("  Not mining any chains")
            } else {
                print("  Mining: \(mining.joined(separator: ", "))")
            }
        default:
            print("  Usage: mine start|stop|list [chain]")
        }

    case "status":
        let statuses = await node.chainStatus()
        let currentArgs = await state.nodeArgs
        printStatus(statuses, resources: currentArgs)

    case "chains":
        let dirs = await node.allDirectories()
        let childDirs = await node.lattice.nexus.childDirectories()
        print("  Registered networks: \(dirs.joined(separator: ", "))")
        if !childDirs.isEmpty {
            print("  Known child chains: \(childDirs.sorted().joined(separator: ", "))")
        }

    case "subscribe":
        guard parts.count >= 2 else {
            print("  Usage: subscribe <chain/path>")
            return
        }
        let path = parts[1].split(separator: "/").map(String.init)
        await state.subscribe(path: path)
        print("  Subscribed to \(parts[1])")

    case "unsubscribe":
        guard parts.count >= 2 else {
            print("  Usage: unsubscribe <chain/path>")
            return
        }
        if parts[1] == "Nexus" {
            print("  Cannot unsubscribe from Nexus")
            return
        }
        let path = parts[1].split(separator: "/").map(String.init)
        await state.unsubscribe(path: path)
        print("  Unsubscribed from \(parts[1])")

    case "subscriptions":
        let all = await state.subscriptions.allValues()
        if all.isEmpty {
            print("  No subscriptions")
        } else {
            print("  Subscribed chains: \(all.count) path(s)")
        }

    case "peers":
        if let net = await node.network(for: "Nexus") {
            let count = await net.ivy.connectedPeers.count
            print("  Connected peers: \(count)")
        }

    case "quit", "exit":
        shutdown()

    default:
        print("  Unknown command: \(parts[0])")
        print("  Commands: mine, status, chains, peers, quit")
    }
}

// MARK: - Child Chain Discovery

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

// MARK: - Main

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

        // Merge user-specified peers with hardcoded and persisted peers
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

        // Verify genesis chain identity
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

        // Start health check writer
        let health = HealthCheck(dataDir: args.dataDir)
        await health.start()

        // Start RPC server if requested
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

        // Periodic health updates
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

        // Interactive command loop on a background thread
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
