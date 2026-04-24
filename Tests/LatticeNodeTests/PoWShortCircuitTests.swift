import XCTest
import UInt256
import cashew
@testable import Lattice
@testable import LatticeNode

private struct PoWTestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "PoWTestFetcher", code: 1)
    }
}

/// S2: PoW gossip-recv short-circuit — reject blocks whose hash doesn't meet
/// their own claimed difficulty before spending any CAS write or state-resolve.
final class PoWShortCircuitTests: XCTestCase {

    /// A freshly mined block satisfies `difficulty >= hash`, so the cheap
    /// gossip-path sanity check must accept it.
    func testMinedBlockPassesPoWCheck() async throws {
        let f = PoWTestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let mined = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256.max, nonce: 0, fetcher: f
        )
        // difficulty = UInt256.max accepts any hash, so the mined block must pass.
        XCTAssertTrue(mined.validateBlockDifficulty(nexusHash: mined.getDifficultyHash()))
    }

    /// A forged block that claims difficulty=1 but whose hash is well above
    /// that target must fail the short-circuit. Any random mined block will
    /// have a hash far above 1, so claiming difficulty=1 without matching
    /// PoW work is detectable purely from header bytes.
    func testForgedLowDifficultyFailsPoWCheck() async throws {
        let f = PoWTestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        // Build with difficulty=max so BlockBuilder finds a valid nonce fast,
        // then hand-construct an otherwise-identical block that claims
        // difficulty=1 to simulate a forger who didn't burn any PoW work.
        let mined = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256.max, nonce: 0, fetcher: f
        )
        let forged = Block(
            version: mined.version,
            previousBlock: mined.previousBlock,
            transactions: mined.transactions,
            difficulty: UInt256(1),
            nextDifficulty: mined.nextDifficulty,
            spec: mined.spec,
            parentHomestead: mined.parentHomestead,
            homestead: mined.homestead,
            frontier: mined.frontier,
            childBlocks: mined.childBlocks,
            index: mined.index,
            timestamp: mined.timestamp,
            nonce: mined.nonce
        )
        XCTAssertFalse(forged.validateBlockDifficulty(nexusHash: forged.getDifficultyHash()),
                       "block claiming difficulty=1 must fail the PoW short-circuit")
    }
}
