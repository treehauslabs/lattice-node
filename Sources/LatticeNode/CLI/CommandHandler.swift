import Lattice
import Foundation
import ArrayTrie

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
