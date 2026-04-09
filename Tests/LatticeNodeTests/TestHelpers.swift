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

func testSpec(_ dir: String = "Nexus", premine: UInt64 = 0) -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: premine, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
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

// MARK: - Port Allocation

private let _testPortCounter = Mutex<UInt16>(UInt16(ProcessInfo.processInfo.processIdentifier % 5000) + 40000)

func nextTestPort() -> UInt16 {
    _testPortCounter.withLock { port in
        port += 1
        return port
    }
}
