import XCTest
@testable import Lattice
@testable import LatticeNode
import ArrayTrie
import VolumeBroker
import cashew
import Ivy
import UInt256

/// Cross-chain `validates:<childCID>` pin lifecycle. Each child block at any
/// merged-mining depth pins the **nexus** block whose admission carried it
/// (one-hop, no chain walk). Verifies install on apply, lookup via the
/// LatticeNode-level helper, and release at retention boundary.
final class ValidatorPinTests: XCTestCase {

    private func bootNexusWithChild(
        blockCount: Int,
        retentionDepth: UInt64 = DEFAULT_RETENTION_DEPTH
    ) async throws -> (node: LatticeNode, tmpDir: URL) {
        let kp = CryptoUtils.generateKeyPair()
        let p1 = nextTestPort()
        let p2 = nextTestPort()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let nexusGenesis = testGenesis(spec: testSpec("Nexus"))
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Child"], value: true)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false, persistInterval: 5,
            subscribedChains: subs,
            retentionDepth: retentionDepth
        )
        let node = try await LatticeNode(config: config, genesisConfig: nexusGenesis)
        try await node.start()

        guard let nexusNet = await node.network(for: "Nexus") else {
            XCTFail("Nexus network missing"); throw CancellationError()
        }
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"),
            timestamp: nexusGenesis.timestamp,
            difficulty: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )
        await node.lattice.nexus.subscribe(to: "Child", genesisBlock: childGenesis)
        let ivyConfig = IvyConfig(
            publicKey: kp.publicKey, listenPort: p2,
            bootstrapPeers: [], enableLocalDiscovery: false
        )
        try await node.registerChainNetwork(directory: "Child", config: ivyConfig)

        guard let childNet = await node.network(for: "Child") else {
            XCTFail("Child network not registered"); throw CancellationError()
        }
        let childDisk = await childNet.diskBroker
        let storer = BrokerStorer(broker: childDisk)
        try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: storer)
        try await storer.flush()
        await node.applyGenesisBlock(directory: "Child", block: childGenesis)

        if blockCount > 0 { try await mineBlocks(blockCount, on: node) }
        return (node, tmpDir)
    }

    /// After merged mining, every child block should have a validator pin
    /// pointing at the nexus block that admitted it. The pin record should
    /// live in the child chain's StateStore and the broker should hold a
    /// `validates:<childCID>` owner pinning the nexus CID.
    func testValidatorPinInstalledAfterMergedMining() async throws {
        let env = try await bootNexusWithChild(blockCount: 3)
        defer { Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        guard let childChain = await env.node.chain(for: "Child"),
              let childStore = await env.node.stateStore(for: "Child"),
              let childNet = await env.node.network(for: "Child") else {
            XCTFail("child resources missing"); return
        }

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertGreaterThan(childHeight, 0, "merged mining should have produced child blocks")

        var anyPinFound = false
        for h in 1...childHeight {
            guard let childCID = childStore.getBlockHash(atHeight: h) else { continue }
            // StateStore validator_pins row should record the nexus CID.
            let nexusCID = childStore.getValidatorParent(childCID: childCID)
            XCTAssertNotNil(nexusCID, "child block at height \(h) should have a validator parent pin")
            guard let nexusCID else { continue }
            anyPinFound = true

            // Cross-store lookup should also resolve via the node-level helper.
            let viaNode = await env.node.validatorParent(forChildCID: childCID)
            XCTAssertEqual(viaNode, nexusCID, "node-level lookup should match per-store row")

            // Broker should have an owner-tagged pin under `validates:<childCID>`
            // pointing at the nexus CID.
            let disk = await childNet.diskBroker
            let owners = await disk.owners(root: nexusCID)
            XCTAssertTrue(
                owners.contains("validates:\(childCID)"),
                "broker missing validates:\(childCID) owner on \(nexusCID); have \(owners)"
            )
        }
        XCTAssertTrue(anyPinFound, "expected at least one validator pin")
    }

    /// `releaseValidatorPins` (invoked from `pruneBlocks` at retention
    /// boundary) should remove both the StateStore row and the broker pin.
    /// Drives this by mining past a small retention depth so the earliest
    /// child blocks age out.
    func testValidatorPinReleasedAtRetentionBoundary() async throws {
        let retention: UInt64 = 2
        let env = try await bootNexusWithChild(blockCount: 5, retentionDepth: retention)
        defer { Task { await env.node.stop(); try? FileManager.default.removeItem(at: env.tmpDir) } }

        guard let childChain = await env.node.chain(for: "Child"),
              let childStore = await env.node.stateStore(for: "Child"),
              let childNet = await env.node.network(for: "Child") else {
            XCTFail("child resources missing"); return
        }

        let childHeight = await childChain.getHighestBlockIndex()
        XCTAssertGreaterThan(childHeight, retention,
            "need to mine past retention to exercise prune; got height \(childHeight)")

        // Heights at or below `childHeight - retention` should have been
        // released by `releaseValidatorPins`. The .tip retention prunes one
        // block back per applied block, so over many blocks every
        // older-than-retention height should have its row removed.
        let cutoff = childHeight - retention
        for h in 1...cutoff {
            let entries = childStore.getValidatorPins(height: h)
            XCTAssertTrue(entries.isEmpty,
                "validator_pins at height \(h) should be released (cutoff=\(cutoff), tip=\(childHeight)); have \(entries.count)")
        }

        // The retained tail (heights > cutoff) should still hold pins on the
        // broker. Sanity-check the latest height.
        if let tipChildCID = childStore.getBlockHash(atHeight: childHeight),
           let tipNexus = childStore.getValidatorParent(childCID: tipChildCID) {
            let disk = await childNet.diskBroker
            let owners = await disk.owners(root: tipNexus)
            XCTAssertTrue(
                owners.contains("validates:\(tipChildCID)"),
                "tip child's validator pin should still be live; owners=\(owners)"
            )
        }
    }
}
