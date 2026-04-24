import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn
import Foundation

/// S10: persistInterval default is 100. Before anyone tightens it toward 1
/// (the motivation was "recover-from-CAS gap = window since last persist"),
/// we need concrete per-persist wall-cost numbers so we can reason about the
/// trade-off instead of guessing. This test mines progressively deeper chains
/// and prints the JSON encode + file write cost at each depth.
///
/// The assertion is a loose upper bound so CI catches a regression where a
/// chain-state field grows unboundedly (e.g. someone inlines a tx list or a
/// retention buffer into `PersistedChainState`). Absolute numbers are expected
/// to drift with hardware; that's why the thresholds are generous.
final class PersistCadenceTests: XCTestCase {

    func testPersistCostScalesLinearlyWithChainDepth() async throws {
        let f = cas()
        let baseTime = now() - 2_000_000
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: baseTime, difficulty: UInt256(1000), fetcher: f
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let persister = ChainStatePersister(storagePath: tmpDir, directory: "Nexus")

        // Mine 250 blocks. 250 > default persistInterval (100) so we capture
        // at least two full persist windows worth of hashToBlock growth.
        var prev = genesis
        var samples: [(height: Int, snapshotMs: Double, saveMs: Double, bytes: Int)] = []
        let probeHeights: Set<Int> = [10, 50, 100, 200, 250]

        for i in 1...250 {
            let block = try await BlockBuilder.buildBlock(
                previous: prev, timestamp: baseTime + Int64(i) * 1000,
                difficulty: UInt256(1000), nonce: UInt64(i), fetcher: f
            )
            let header = VolumeImpl<Block>(node: block)
            await f.store(rawCid: header.rawCID, data: block.toData()!)
            _ = await chain.submitBlock(
                parentBlockHeaderAndIndex: nil, blockHeader: header, block: block
            )
            prev = block

            if probeHeights.contains(i) {
                let tSnap = ContinuousClock.now
                let snapshot = await chain.persist()
                let dSnap = ContinuousClock.now - tSnap

                let tSave = ContinuousClock.now
                try await persister.save(snapshot)
                let dSave = ContinuousClock.now - tSave

                let path = tmpDir.appendingPathComponent("Nexus/chain_state.json")
                let bytes = (try? Data(contentsOf: path).count) ?? 0
                samples.append((
                    height: i,
                    snapshotMs: dSnap.milliseconds,
                    saveMs: dSave.milliseconds,
                    bytes: bytes
                ))
            }
        }

        print("[S10] persist cost measurement (retentionDepth=\(DEFAULT_RETENTION_DEPTH))")
        print("[S10]   height  snapshotMs  saveMs   bytes")
        for s in samples {
            print(String(format: "[S10]   %-6d  %-10.3f  %-7.3f  %d",
                         s.height, s.snapshotMs, s.saveMs, s.bytes))
        }

        // Regression guards: if the full persist (snapshot + save) at 250 blocks
        // breaks 500ms on this hardware something fundamentally regressed. The
        // file size should also stay well under 10MB at retention-bounded depth.
        let deepest = samples.last!
        XCTAssertLessThan(deepest.snapshotMs + deepest.saveMs, 500,
                          "persist at height=\(deepest.height) took \(deepest.snapshotMs + deepest.saveMs)ms — unexpected regression")
        XCTAssertLessThan(deepest.bytes, 10_000_000,
                          "chain_state.json at height=\(deepest.height) is \(deepest.bytes) bytes — persisted state should be retention-bounded")
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attos) = self.components
        return Double(seconds) * 1_000 + Double(attos) / 1_000_000_000_000_000
    }
}
