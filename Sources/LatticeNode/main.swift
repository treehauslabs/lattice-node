import Lattice
import Foundation
import Ivy
import UInt256

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
    return identity
}

// MARK: - Argument Parsing

struct NodeArgs {
    var port: UInt16 = 4001
    var dataDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice")
    var bootstrapPeers: [PeerEndpoint] = []
    var mineChains: Set<String> = []
    var enableDiscovery: Bool = true
    var showHelp: Bool = false
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
        case "--no-discovery":
            args.enableDiscovery = false
        case "--help", "-h":
            args.showHelp = true
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
      --no-discovery             Disable mDNS local peer discovery
      --help, -h                 Show this help

    INTERACTIVE COMMANDS:
      mine start [chain]         Start mining a chain (default: Nexus)
      mine stop [chain]          Stop mining a chain
      mine list                  Show which chains are being mined
      status                     Show all chain heights, tips, mining, mempool
      chains                     List registered chain directories
      peers                      Show connected peer count
      quit                       Graceful shutdown
    """)
}

// MARK: - Status Display

func printStatus(_ statuses: [LatticeNode.ChainInfo]) {
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

// MARK: - Command Handler

func handleCommand(_ line: String, node: LatticeNode, shutdown: @Sendable @escaping () -> Void) async {
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
        printStatus(statuses)

    case "chains":
        let dirs = await node.allDirectories()
        let childDirs = await node.lattice.nexus.childDirectories()
        print("  Registered networks: \(dirs.joined(separator: ", "))")
        if !childDirs.isEmpty {
            print("  Known child chains: \(childDirs.sorted().joined(separator: ", "))")
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

func startChildDiscoveryLoop(node: LatticeNode, config: LatticeNodeConfig, basePort: UInt16) {
    Task {
        var nextPort = basePort + 1
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let childDirs = await node.lattice.nexus.childDirectories()
            for dir in childDirs {
                if await node.network(for: dir) == nil {
                    let childConfig = IvyConfig(
                        publicKey: config.publicKey,
                        listenPort: nextPort,
                        enableLocalDiscovery: config.enableLocalDiscovery
                    )
                    try? await node.registerChainNetwork(directory: dir, config: childConfig)
                    print("  [discovery] Registered child chain: \(dir) on port \(nextPort)")
                    nextPort += 1
                }
            }
        }
    }
}

// MARK: - Main

let args = parseArgs()

if args.showHelp {
    printUsage()
    exit(0)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

Task {
    do {
        let identity = try loadOrCreateIdentity(dataDir: args.dataDir)

        print()
        print("  Lattice Node")
        print("  ============")
        print("  Public key:  \(String(identity.publicKey.prefix(32)))...")
        print("  Data dir:    \(args.dataDir.path)")
        print("  Listen port: \(args.port)")
        print("  Discovery:   \(args.enableDiscovery ? "enabled" : "disabled")")
        if !args.bootstrapPeers.isEmpty {
            print("  Peers:       \(args.bootstrapPeers.count) bootstrap peer(s)")
        }
        print()

        let nodeConfig = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: identity.privateKey,
            listenPort: args.port,
            bootstrapPeers: args.bootstrapPeers,
            storagePath: args.dataDir,
            enableLocalDiscovery: args.enableDiscovery,
            persistInterval: 100
        )

        let node = try await LatticeNode(config: nodeConfig, genesisConfig: NexusGenesis.config)
        try? await node.restoreChildChains()
        try await node.start()

        let genesisHeight = await node.lattice.nexus.chain.getHighestBlockIndex()
        print("  Nexus chain height: \(genesisHeight)")
        print()

        for chain in args.mineChains {
            await node.startMining(directory: chain)
            print("  Mining started on \(chain)")
        }

        startChildDiscoveryLoop(node: node, config: nodeConfig, basePort: args.port)

        let shutdownHandler: @Sendable () -> Void = {
            Task {
                print("\n  Shutting down...")
                await node.stop()
                print("  State persisted. Goodbye.")
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
                await handleCommand(line, node: node, shutdown: shutdownHandler)
            }
        }

    } catch {
        print("  Fatal: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
