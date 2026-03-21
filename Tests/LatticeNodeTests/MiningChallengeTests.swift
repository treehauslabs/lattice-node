import XCTest
@testable import Lattice
@testable import UInt256
import cashew
import Acorn
import Tally
import Ivy
import Crypto

private struct TestFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        throw NSError(domain: "TestFetcher", code: 1)
    }
}

private func testSpec(_ dir: String = "Nexus") -> ChainSpec {
    ChainSpec(directory: dir, maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000,
              maxBlockSize: 1_000_000, premine: 0, targetBlockTime: 1_000,
              initialReward: 1024, halvingInterval: 10_000, difficultyAdjustmentWindow: 5)
}

private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// ============================================================================
// MARK: - Block Hash Prefix
// ============================================================================

@MainActor
final class BlockHashPrefixTests: XCTestCase {

    func testGetDifficultyHashPrefixIsStable() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 0, fetcher: f
        )

        let prefix1 = block.getDifficultyHashPrefix()
        let prefix2 = block.getDifficultyHashPrefix()
        XCTAssertEqual(prefix1, prefix2)
        XCTAssertFalse(prefix1.isEmpty)
    }

    func testHashPrefixPlusNonceProducesCorrectHash() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )

        for nonce: UInt64 in [0, 1, 42, 99999] {
            let block = try await BlockBuilder.buildBlock(
                previous: genesis, timestamp: t + 1000,
                difficulty: UInt256(1000), nonce: nonce, fetcher: f
            )
            let expected = block.getDifficultyHash()

            var input = block.getDifficultyHashPrefix()
            input.append(contentsOf: String(nonce).utf8)
            let computed = UInt256.hash(input)

            XCTAssertEqual(expected, computed, "Hash mismatch for nonce \(nonce)")
        }
    }

    func testDifferentNoncesProduceDifferentHashes() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 0, fetcher: f
        )

        let prefix = block.getDifficultyHashPrefix()
        var input0 = prefix
        input0.append(contentsOf: "0".utf8)
        var input1 = prefix
        input1.append(contentsOf: "1".utf8)

        XCTAssertNotEqual(UInt256.hash(input0), UInt256.hash(input1))
    }

    func testGenesisBlockHashPrefixWorks() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), nonce: 0, fetcher: f
        )

        let expected = genesis.getDifficultyHash()
        var input = genesis.getDifficultyHashPrefix()
        input.append(contentsOf: "0".utf8)
        let computed = UInt256.hash(input)

        XCTAssertEqual(expected, computed)
    }
}

// ============================================================================
// MARK: - Mining Challenge Core
// ============================================================================

@MainActor
final class MiningChallengeTests: XCTestCase {

    private func makeChallenge(
        prefixBytes: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
        blockDifficulty: Data = Data(repeating: 0xFF, count: 32)
    ) -> MiningChallenge {
        let hashPrefix = Data("test-block-header-prefix".utf8)
        return MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: blockDifficulty,
            noncePrefix: Data(prefixBytes),
            expiresAfter: .seconds(300)
        )
    }

    func testSolverReturnsValidSolution() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        let result = challenge.verify(solution: solution)
        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0, "Should have found at least some leading zeros")
        case .blockFound(_, let hardness):
            XCTAssertGreaterThan(hardness, 0)
        default:
            XCTFail("Expected workDone or blockFound, got \(result)")
        }
    }

    func testSolutionNonceHasCorrectPrefix() {
        let prefix: [UInt8] = [0xAB, 0x00, 0x00, 0x00, 0x00, 0x00]
        let challenge = makeChallenge(prefixBytes: prefix)
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        let nonceBytes = withUnsafeBytes(of: solution.nonce.bigEndian) { Data($0) }
        XCTAssertEqual(nonceBytes[0], 0xAB, "Nonce should start with the assigned prefix")
    }

    func testSolutionHashMatchesRecomputation() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        var input = challenge.hashPrefix
        input.append(contentsOf: String(solution.nonce).utf8)
        let recomputed = Data(SHA256.hash(data: input))

        XCTAssertEqual(solution.hash, recomputed)
    }

    func testVerifyRejectsWrongHash() {
        let challenge = makeChallenge()
        let solver = MiningChallengeSolver()
        let real = solver.solve(challenge)

        let fake = MiningChallengeSolution(
            nonce: real.nonce,
            hash: Data(repeating: 0x00, count: 32),
            blockNonce: nil
        )
        let result = challenge.verify(solution: fake)
        XCTAssertEqual(result, .invalid)
    }

    func testVerifyRejectsWrongPrefix() {
        let challenge = makeChallenge(prefixBytes: [0xAA, 0x00, 0x00, 0x00, 0x00, 0x00])

        let wrongNonce: UInt64 = 0xBB00_0000_0000_0000
        var input = challenge.hashPrefix
        input.append(contentsOf: String(wrongNonce).utf8)
        let hash = Data(SHA256.hash(data: input))

        let solution = MiningChallengeSolution(nonce: wrongNonce, hash: hash, blockNonce: nil)
        let result = challenge.verify(solution: solution)
        XCTAssertEqual(result, .invalid)
    }

    func testExpiredChallengeReturnsExpired() {
        let challenge = MiningChallenge(
            hashPrefix: Data("prefix".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(0)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)
        XCTAssertEqual(result, .expired)
    }

    func testDifferentPrefixesProduceDifferentNonceRanges() {
        let solver = MiningChallengeSolver()

        let challenge1 = makeChallenge(prefixBytes: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let challenge2 = makeChallenge(prefixBytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

        let sol1 = solver.solve(challenge1)
        let sol2 = solver.solve(challenge2)

        let bytes1 = withUnsafeBytes(of: sol1.nonce.bigEndian) { Data($0) }
        let bytes2 = withUnsafeBytes(of: sol2.nonce.bigEndian) { Data($0) }

        XCTAssertEqual(bytes1[0], 0x00)
        XCTAssertEqual(bytes2[0], 0x01)
    }

    func testMoreWorkProducesMoreLeadingZeros() {
        let solver = MiningChallengeSolver()

        // 7-byte prefix = 256 nonces to search
        let smallRange = MiningChallenge(
            hashPrefix: Data("test-header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        // 6-byte prefix = 65536 nonces to search
        let bigRange = MiningChallenge(
            hashPrefix: Data("test-header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let smallSol = solver.solve(smallRange)
        let bigSol = solver.solve(bigRange)

        let smallResult = smallRange.verify(solution: smallSol)
        let bigResult = bigRange.verify(solution: bigSol)

        var smallHardness = 0
        var bigHardness = 0
        if case .workDone(let h) = smallResult { smallHardness = h }
        if case .blockFound(_, let h) = smallResult { smallHardness = h }
        if case .workDone(let h) = bigResult { bigHardness = h }
        if case .blockFound(_, let h) = bigResult { bigHardness = h }

        XCTAssertGreaterThanOrEqual(bigHardness, smallHardness,
            "Larger search space should produce at least as many leading zeros")
    }
}

// ============================================================================
// MARK: - Mining Challenge with Real Block Headers
// ============================================================================

@MainActor
final class MiningChallengeIntegrationTests: XCTestCase {

    func testChallengeWithRealBlockHeader() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(1000), nonce: 0, fetcher: f
        )

        let hashPrefix = block.getDifficultyHashPrefix()
        var targetBytes = Data(count: 32)
        let target = block.difficulty
        for i in 0..<4 {
            var part = target[i].bigEndian
            targetBytes.replaceSubrange((i*8)..<((i+1)*8), with: Data(bytes: &part, count: 8))
        }

        let challenge = MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: targetBytes,
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = challenge.verify(solution: solution)

        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0)
        case .blockFound(let nonce, let hardness):
            XCTAssertGreaterThan(hardness, 0)
            var input = hashPrefix
            input.append(contentsOf: String(nonce).utf8)
            let hash = UInt256.hash(input)
            XCTAssertTrue(target >= hash, "Found block nonce should meet difficulty")
        default:
            XCTFail("Expected workDone or blockFound")
        }
    }

    func testBlockFoundNonceIsValidForMining() async throws {
        let f = TestFetcher()
        let t = now() - 20_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(UInt64.max), fetcher: f
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, timestamp: t + 1000,
            difficulty: UInt256(UInt64.max), nonce: 0, fetcher: f
        )

        let hashPrefix = block.getDifficultyHashPrefix()
        var targetBytes = Data(count: 32)
        let target = UInt256(UInt64.max)
        for i in 0..<4 {
            var part = target[i].bigEndian
            targetBytes.replaceSubrange((i*8)..<((i+1)*8), with: Data(bytes: &part, count: 8))
        }

        let challenge = MiningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: targetBytes,
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)

        if let blockNonce = solution.blockNonce {
            let candidate = Block(
                previousBlock: block.previousBlock,
                transactions: block.transactions,
                difficulty: block.difficulty,
                nextDifficulty: block.nextDifficulty,
                spec: block.spec,
                parentHomestead: block.parentHomestead,
                homestead: block.homestead,
                frontier: block.frontier,
                childBlocks: block.childBlocks,
                index: block.index,
                timestamp: block.timestamp,
                nonce: blockNonce
            )
            let hash = candidate.getDifficultyHash()
            XCTAssertTrue(target >= hash,
                "Block built with peer-found nonce should pass difficulty check")
        }
    }
}

// ============================================================================
// MARK: - Tally Mining Challenge Reputation
// ============================================================================

@MainActor
final class TallyMiningReputationTests: XCTestCase {

    func testMiningChallengeCreditsReputation() {
        let tally = Tally()
        let peer = PeerID(publicKey: "miner-peer")

        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = tally.verifyMiningChallenge(challenge, solution: solution, peer: peer)

        switch result {
        case .workDone(let hardness):
            XCTAssertGreaterThan(hardness, 0)
            let ledger = tally.peerLedger(for: peer)
            XCTAssertNotNil(ledger)
            XCTAssertEqual(ledger!.challengeHardness, hardness)
        case .blockFound:
            break
        default:
            XCTFail("Expected workDone or blockFound")
        }

        let rep = tally.reputation(for: peer)
        XCTAssertGreaterThan(rep, 0)
        XCTAssertEqual(tally.metrics.challengesVerified, 1)
    }

    func testMultipleChallengesAccumulateHardness() {
        let tally = Tally()
        let peer = PeerID(publicKey: "worker")
        let solver = MiningChallengeSolver()

        for i: UInt8 in 0..<3 {
            let challenge = MiningChallenge(
                hashPrefix: Data("header-\(i)".utf8),
                blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
                noncePrefix: Data([i, 0x00, 0x00, 0x00, 0x00, 0x00]),
                expiresAfter: .seconds(300)
            )
            let solution = solver.solve(challenge)
            _ = tally.verifyMiningChallenge(challenge, solution: solution, peer: peer)
        }

        let ledger = tally.peerLedger(for: peer)!
        XCTAssertGreaterThan(ledger.challengeHardness, 0)
        XCTAssertEqual(tally.metrics.challengesVerified, 3)

        let rep = tally.reputation(for: peer)
        XCTAssertGreaterThan(rep, 0)
    }

    func testReputationScalesWithoutCap() {
        let tally = Tally()
        let peer = PeerID(publicKey: "grinder")
        let solver = MiningChallengeSolver()

        var lastRep: Double = 0
        for i: UInt8 in 0..<10 {
            let challenge = MiningChallenge(
                hashPrefix: Data("header-\(i)".utf8),
                blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
                noncePrefix: Data([i, 0x00, 0x00, 0x00, 0x00, 0x00]),
                expiresAfter: .seconds(300)
            )
            let solution = solver.solve(challenge)
            _ = tally.verifyMiningChallenge(challenge, solution: solution, peer: peer)

            let rep = tally.reputation(for: peer)
            XCTAssertGreaterThanOrEqual(rep, lastRep, "Reputation should never decrease with more work")
            lastRep = rep
        }

        XCTAssertGreaterThan(lastRep, 0)
    }

    func testExpiredChallengeDoesNotCreditReputation() {
        let tally = Tally()
        let peer = PeerID(publicKey: "slow-peer")

        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(0)
        )

        let solver = MiningChallengeSolver()
        let solution = solver.solve(challenge)
        let result = tally.verifyMiningChallenge(challenge, solution: solution, peer: peer)

        XCTAssertEqual(result, .expired)
        XCTAssertNil(tally.peerLedger(for: peer))
        XCTAssertEqual(tally.metrics.challengesVerified, 0)
    }

    func testInvalidSolutionDoesNotCreditReputation() {
        let tally = Tally()
        let peer = PeerID(publicKey: "cheater")

        let challenge = MiningChallenge(
            hashPrefix: Data("header".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0xAA, 0x00, 0x00, 0x00, 0x00, 0x00]),
            expiresAfter: .seconds(300)
        )

        let fakeSolution = MiningChallengeSolution(
            nonce: 0xAA00_0000_0000_0000,
            hash: Data(repeating: 0x00, count: 32),
            blockNonce: nil
        )
        let result = tally.verifyMiningChallenge(challenge, solution: fakeSolution, peer: peer)

        XCTAssertEqual(result, .invalid)
        XCTAssertNil(tally.peerLedger(for: peer))
    }
}

// ============================================================================
// MARK: - Ivy Message Serialization
// ============================================================================

@MainActor
final class MiningChallengeMessageTests: XCTestCase {

    func testMiningChallengeMessageRoundtrip() {
        let hashPrefix = Data("block-header-prefix-data".utf8)
        let blockTarget = Data(repeating: 0x00, count: 32)
        let noncePrefix = Data([0xAB, 0xCD])

        let msg = Message.miningChallenge(
            hashPrefix: hashPrefix,
            blockTargetDifficulty: blockTarget,
            noncePrefix: noncePrefix
        )

        let serialized = msg.serialize()
        let deserialized = Message.deserialize(serialized)

        guard case .miningChallenge(let hp, let bt, let np) = deserialized else {
            XCTFail("Failed to deserialize miningChallenge")
            return
        }

        XCTAssertEqual(hp, hashPrefix)
        XCTAssertEqual(bt, blockTarget)
        XCTAssertEqual(np, noncePrefix)
    }

    func testMiningChallengeSolutionWithBlockNonceRoundtrip() {
        let hash = Data(repeating: 0x01, count: 32)
        let msg = Message.miningChallengeSolution(
            nonce: 12345,
            hash: hash,
            blockNonce: 67890
        )

        let serialized = msg.serialize()
        let deserialized = Message.deserialize(serialized)

        guard case .miningChallengeSolution(let n, let h, let bn) = deserialized else {
            XCTFail("Failed to deserialize miningChallengeSolution")
            return
        }

        XCTAssertEqual(n, 12345)
        XCTAssertEqual(h, hash)
        XCTAssertEqual(bn, 67890)
    }

    func testMiningChallengeSolutionWithoutBlockNonceRoundtrip() {
        let hash = Data(repeating: 0x02, count: 32)
        let msg = Message.miningChallengeSolution(
            nonce: 999,
            hash: hash,
            blockNonce: nil
        )

        let serialized = msg.serialize()
        let deserialized = Message.deserialize(serialized)

        guard case .miningChallengeSolution(let n, let h, let bn) = deserialized else {
            XCTFail("Failed to deserialize miningChallengeSolution")
            return
        }

        XCTAssertEqual(n, 999)
        XCTAssertEqual(h, hash)
        XCTAssertNil(bn)
    }

    func testMiningChallengeFrameRoundtrip() {
        let msg = Message.miningChallenge(
            hashPrefix: Data("prefix".utf8),
            blockTargetDifficulty: Data(repeating: 0xFF, count: 32),
            noncePrefix: Data([0x01])
        )

        let frame = Message.frame(msg)
        XCTAssertGreaterThan(frame.count, 4)

        let payloadLength = frame.withUnsafeBytes { buf -> UInt32 in
            buf.load(as: UInt32.self).bigEndian
        }
        XCTAssertEqual(Int(payloadLength), frame.count - 4)
    }

    func testExistingMessageTypesUnaffected() {
        let ping = Message.ping(nonce: 42)
        let serialized = ping.serialize()
        guard case .ping(let n) = Message.deserialize(serialized) else {
            XCTFail("Ping roundtrip failed")
            return
        }
        XCTAssertEqual(n, 42)

        let announce = Message.announceBlock(cid: "test-cid")
        let aSer = announce.serialize()
        guard case .announceBlock(let cid) = Message.deserialize(aSer) else {
            XCTFail("AnnounceBlock roundtrip failed")
            return
        }
        XCTAssertEqual(cid, "test-cid")
    }
}

// ============================================================================
// MARK: - MiningChallengeResult Equatable (for test assertions)
// ============================================================================

extension MiningChallengeResult: @retroactive Equatable {
    public static func == (lhs: MiningChallengeResult, rhs: MiningChallengeResult) -> Bool {
        switch (lhs, rhs) {
        case (.expired, .expired): return true
        case (.invalid, .invalid): return true
        case (.workDone(let a), .workDone(let b)): return a == b
        case (.blockFound(let na, let ha), .blockFound(let nb, let hb)): return na == nb && ha == hb
        default: return false
        }
    }
}
