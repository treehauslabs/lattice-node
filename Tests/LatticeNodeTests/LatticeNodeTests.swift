import XCTest
import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

@MainActor
final class LatticeNodeTests: XCTestCase {

    // MARK: - NexusGenesis boots correctly

    func testNexusGenesisSpecIsValid() {
        XCTAssertTrue(NexusGenesis.spec.isValid)
        XCTAssertEqual(NexusGenesis.spec.directory, "Nexus")
    }

    func testNexusGenesisCreatesBlock() async throws {
        let result = try await NexusGenesis.create(fetcher: TestFetcher())
        XCTAssertFalse(result.blockHash.isEmpty)
        XCTAssertNotNil(result.chainState)
    }


    func testNexusGenesisBlockIsDeterministic() async throws {
        let r1 = try await NexusGenesis.create(fetcher: TestFetcher())
        let r2 = try await NexusGenesis.create(fetcher: TestFetcher())
        XCTAssertEqual(r1.blockHash, r2.blockHash)
    }

    // MARK: - ChainLevel hierarchy for multi-chain

    func testChainLevelStartsWithNoChildren() async throws {
        let genesis = try await NexusGenesis.create(fetcher: TestFetcher())
        let level = ChainLevel(chain: genesis.chainState, children: [:])
        let dirs = await level.childDirectories()
        XCTAssertTrue(dirs.isEmpty)
    }

    func testRegisterChildChain() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(directory: "Payments", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 0, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])
        await level.restoreChildChain(directory: "Payments", level: childLevel)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Payments"])
    }

    func testRestoreChildChain() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(directory: "Data", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: 0, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childChain = ChainState.fromGenesis(block: childGenesis)
        let childLevel = ChainLevel(chain: childChain, children: [:])

        await level.restoreChildChain(directory: "Data", level: childLevel)
        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs, ["Data"])
    }

    func testDuplicateRegisterIgnored() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])

        let childSpec = ChainSpec(directory: "X", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let g = try await BlockBuilder.buildGenesis(spec: childSpec, timestamp: 0, difficulty: UInt256(1000), fetcher: fetcher)
        let xChain = ChainState.fromGenesis(block: g)
        let xLevel = ChainLevel(chain: xChain, children: [:])
        await level.restoreChildChain(directory: "X", level: xLevel)
        await level.restoreChildChain(directory: "X", level: xLevel)

        let dirs = await level.childDirectories()
        XCTAssertEqual(dirs.count, 1)
    }

    // MARK: - Lattice actor processes blocks

    func testLatticeProcessesNexusBlock() async throws {
        let fetcher = TestFetcher()
        let genesis = try await NexusGenesis.create(fetcher: fetcher)
        let level = ChainLevel(chain: genesis.chainState, children: [:])
        let lattice = Lattice(nexus: level)

        let height = await lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertEqual(height, 0)
    }

    // MARK: - Chain state persistence roundtrip

    func testPersistAndRestoreChainState() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)

        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedChainState.self, from: data)
        let restored = ChainState.restore(from: decoded)

        let originalTip = await chain.getMainChainTip()
        let restoredTip = await restored.getMainChainTip()
        XCTAssertEqual(originalTip, restoredTip)

        let restoredHeight = await restored.getHighestBlockIndex()
        XCTAssertEqual(restoredHeight, 1)
    }

    func testRestoredChainAcceptsNewBlocks() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let b1 = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b1), block: b1
        )

        let persisted = await chain.persist()
        let restored = ChainState.restore(from: persisted)

        let b2 = try await BlockBuilder.buildBlock(
            previous: b1, timestamp: t + 2000,
            difficulty: UInt256(1000), nonce: 2, fetcher: fetcher
        )
        let result = await restored.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: HeaderImpl<Block>(node: b2), block: b2
        )
        XCTAssertTrue(result.extendsMainChain)
        let height = await restored.getHighestBlockIndex()
        XCTAssertEqual(height, 2)
    }

    // MARK: - Miner lifecycle

    func testMinerStartStop() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 10_000
        let spec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                             maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                             premine: 0, targetBlockTime: 1_000,
                             initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis)
        let mempool = Mempool(maxSize: 100)
        let miner = MinerLoop(chainState: chain, mempool: mempool, fetcher: fetcher, spec: spec)

        let before = await miner.isMining
        XCTAssertFalse(before)

        await miner.start()
        let during = await miner.isMining
        XCTAssertTrue(during)

        await miner.stop()
        let after = await miner.isMining
        XCTAssertFalse(after)
    }

    // MARK: - Multi-chain block building

    func testBuildBlockWithChildBlocks() async throws {
        let fetcher = TestFetcher()
        let t = Int64(Date().timeIntervalSince1970 * 1000) - 20_000
        let nexusSpec = ChainSpec(directory: "Nexus", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
        let childSpec = ChainSpec(directory: "Child", maxNumberOfTransactionsPerBlock: 100,
                                  maxStateGrowth: 100_000, maxBlockSize: 1_000_000,
                                  premine: 0, targetBlockTime: 1_000,
                                  initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)

        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nexusSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )

        let block = try await BlockBuilder.buildBlock(
            previous: nexusGenesis,
            childBlocks: ["Child": childGenesis],
            timestamp: t + 1000, difficulty: UInt256(1000), nonce: 1, fetcher: fetcher
        )

        let header = HeaderImpl<Block>(node: block)
        XCTAssertFalse(header.rawCID.isEmpty)
    }
}
