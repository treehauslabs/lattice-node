import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn
import Foundation
import Synchronization

// MARK: - In-Memory CAS Worker

actor TestCASWorker: AcornCASWorker {
    var near: (any AcornCASWorker)?
    var far: (any AcornCASWorker)?
    var timeout: Duration? { nil }
    private var store: [ContentIdentifier: Data] = [:]
    func has(cid: ContentIdentifier) -> Bool { store[cid] != nil }
    func getLocal(cid: ContentIdentifier) async -> Data? { store[cid] }
    func storeLocal(cid: ContentIdentifier, data: Data) async { store[cid] = data }
    var count: Int { store.count }
}

func cas() -> AcornFetcher { AcornFetcher(worker: TestCASWorker()) }

// MARK: - Chain Spec & Genesis

func testSpec(_ dir: String = "Nexus", premine: UInt64 = 0, difficultyAdjustmentWindow: UInt64 = 5) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: difficultyAdjustmentWindow)
}

func testGenesis(spec: ChainSpec? = nil) -> GenesisConfig {
    GenesisConfig(spec: spec ?? testSpec(), timestamp: now() - 10_000, difficulty: UInt256.max)
}

// MARK: - Transaction Helpers

func sign(_ body: TransactionBody, _ kp: (privateKey: String, publicKey: String)) -> Transaction {
    let h = HeaderImpl<TransactionBody>(node: body)
    let sig = CryptoUtils.sign(message: h.rawCID, privateKeyHex: kp.privateKey)!
    return Transaction(signatures: [kp.publicKey: sig], body: h)
}

func addr(_ pubKey: String) -> String {
    HeaderImpl<PublicKey>(node: PublicKey(key: pubKey)).rawCID
}

// MARK: - Time

func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - Deterministic Mining

/// Mine exactly `count` blocks on the target chain. Starts the nexus miner
/// (which drives merged mining for child chains) and polls until the target
/// chain advances by `count` blocks. Returns immediately when done —
/// no unnecessary sleeping or difficulty climbing.
func mineBlocks(
    _ count: Int,
    on node: LatticeNode,
    chain directory: String = "Nexus"
) async throws {
    let getHeight: () async -> UInt64 = {
        if directory == "Nexus" {
            return await node.lattice.nexus.chain.getHighestBlockIndex()
        } else {
            return await node.lattice.nexus.children[directory]?.chain.getHighestBlockIndex() ?? 0
        }
    }
    let startHeight = await getHeight()
    let targetHeight = startHeight + UInt64(count)
    await node.startMining(directory: "Nexus")
    while await getHeight() < targetHeight {
        try await Task.sleep(for: .milliseconds(10))
    }
    await node.stopMining(directory: "Nexus")
    // Wait for any in-flight detached block processing tasks
    try await Task.sleep(for: .milliseconds(500))
}

// MARK: - Port Allocation

private let _testPortCounter = Mutex<UInt16>(UInt16(ProcessInfo.processInfo.processIdentifier % 5000) + 40000)

func nextTestPort() -> UInt16 {
    _testPortCounter.withLock { port in
        port += 1
        return port
    }
}
