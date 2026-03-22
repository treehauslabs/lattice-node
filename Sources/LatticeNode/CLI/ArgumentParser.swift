import Foundation
import Ivy
import ArrayTrie

let LatticeNodeVersion = "0.1.0"
let ProtocolVersion: UInt16 = 1

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
