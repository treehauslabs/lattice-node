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

    /// Smoke test: two real nodes both subscribed to the same Child chain,
    /// connected over TCP via the Nexus network AND the Child network. Miner
    /// produces merged-mined nexus blocks; each carries an embedded child
    /// block whose body lives in the miner's Child broker.
    ///
    /// As of this commit: the Nexus chain syncs (peer reaches the miner's
    /// nexus tip) and the Child Ivy peer link is established, but child
    /// blocks do not get applied to the peer's Child chain. The most likely
    /// cause is that on the receive side, `acceptChildBlockTree` resolves
    /// `childBlockHeader.resolve(fetcher: validationFetcher)` against a
    /// CompositeFetcher whose child-Ivy fallback fails to fetch the body
    /// from the miner's child broker — likely a serving/discovery gap rather
    /// than peering, since the Ivy peer count is 1 on both sides.
    ///
    /// This test asserts the *Nexus* sync invariants only and records the
    /// child-sync gap as a TODO so the suite still gates the path that does
    /// work today. See tasks #16/#17 for the planned peer RPC + walk that
    /// will close this gap.
    func testChildChainSyncBetweenRunningNodes() async throws {
        let kp1 = CryptoUtils.generateKeyPair()
        let kp2 = CryptoUtils.generateKeyPair()
        let p1Nexus = nextTestPort()
        let p1Child = nextTestPort()
        let p2Nexus = nextTestPort()
        let p2Child = nextTestPort()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let nexusGenesis = testGenesis(spec: testSpec("Nexus"))
        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Child"], value: true)

        let config1 = LatticeNodeConfig(
            publicKey: kp1.publicKey, privateKey: kp1.privateKey,
            listenPort: p1Nexus,
            storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false, persistInterval: 5,
            subscribedChains: subs
        )
        let config2 = LatticeNodeConfig(
            publicKey: kp2.publicKey, privateKey: kp2.privateKey,
            listenPort: p2Nexus,
            bootstrapPeers: [PeerEndpoint(publicKey: kp1.publicKey, host: "127.0.0.1", port: p1Nexus)],
            storagePath: tmpDir.appendingPathComponent("node2"),
            enableLocalDiscovery: false, persistInterval: 5,
            subscribedChains: subs
        )

        let node1 = try await LatticeNode(config: config1, genesisConfig: nexusGenesis)
        let node2 = try await LatticeNode(config: config2, genesisConfig: nexusGenesis)
        try await node1.start()
        try await node2.start()

        guard let nexus1 = await node1.network(for: "Nexus") else {
            XCTFail("Nexus net 1 missing"); return
        }
        // Build child genesis once; both nodes apply the same one (deterministic
        // — same spec, same timestamp).
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"),
            timestamp: nexusGenesis.timestamp,
            difficulty: UInt256.max,
            fetcher: nexus1.ivyFetcher
        )

        // Subscribe + register child network on node1, point node2's child
        // network at node1's child port for peer-to-peer child gossip.
        await node1.lattice.nexus.subscribe(to: "Child", genesisBlock: childGenesis)
        try await node1.registerChainNetwork(
            directory: "Child",
            config: IvyConfig(publicKey: kp1.publicKey, listenPort: p1Child,
                              bootstrapPeers: [], enableLocalDiscovery: false)
        )
        await node2.lattice.nexus.subscribe(to: "Child", genesisBlock: childGenesis)
        try await node2.registerChainNetwork(
            directory: "Child",
            config: IvyConfig(publicKey: kp2.publicKey, listenPort: p2Child,
                              bootstrapPeers: [PeerEndpoint(publicKey: kp1.publicKey, host: "127.0.0.1", port: p1Child)],
                              enableLocalDiscovery: false)
        )

        // Seed both nodes' Child broker + StateStore with genesis (genesis is
        // never embedded in a nexus block, so it doesn't propagate).
        for n in [node1, node2] {
            guard let net = await n.network(for: "Child") else {
                XCTFail("child net missing"); return
            }
            let storer = BrokerStorer(broker: await net.diskBroker)
            try VolumeImpl<Block>(node: childGenesis).storeRecursively(storer: storer)
            try await storer.flush()
            await n.applyGenesisBlock(directory: "Child", block: childGenesis)
        }

        // Wait for nexus + child peer connections to settle.
        try await Task.sleep(for: .seconds(2))

        // Mine merged blocks on node1 — each nexus block embeds a child block.
        try await mineBlocks(3, on: node1)

        let nexusHeight1 = await node1.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThan(nexusHeight1, 0, "node1 should have mined nexus blocks")

        guard let childChain1 = await node1.chain(for: "Child"),
              let childChain2 = await node2.chain(for: "Child") else {
            XCTFail("child chains missing"); return
        }
        let childHeight1 = await childChain1.getHighestBlockIndex()
        XCTAssertGreaterThan(childHeight1, 0, "merged mining should produce child blocks on miner")

        // Wait for nexus AND child sync. Child sync is gated on nexus block
        // arrival (acceptChildBlockTree runs after the nexus block lands), and
        // both validation walks pull state via DHT, so allow a longer window.
        let deadline = ContinuousClock.Instant.now + .seconds(15)
        while ContinuousClock.Instant.now < deadline {
            let n2 = await node2.lattice.nexus.chain.getHighestBlockIndex()
            let c2 = await childChain2.getHighestBlockIndex()
            if n2 >= nexusHeight1 && c2 >= childHeight1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let nexusHeight2 = await node2.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertEqual(nexusHeight2, nexusHeight1,
            "node2 should sync the Nexus chain to node1's tip (got \(nexusHeight2)/\(nexusHeight1))")

        let childPeers2 = await (node2.network(for: "Child")?.ivy.connectedPeers.count) ?? 0
        XCTAssertGreaterThan(childPeers2, 0, "node2 Child network should have peered with node1")

        let childHeight2 = await childChain2.getHighestBlockIndex()
        XCTAssertEqual(childHeight2, childHeight1,
            "node2 should sync the Child chain to node1's tip (got \(childHeight2)/\(childHeight1))")

        guard let childStore1 = await node1.stateStore(for: "Child"),
              let childStore2 = await node2.stateStore(for: "Child") else {
            XCTFail("child stores missing"); return
        }
        for h in 1...childHeight1 {
            let h1 = childStore1.getBlockHash(atHeight: h)
            let h2 = childStore2.getBlockHash(atHeight: h)
            XCTAssertEqual(h1, h2, "child block hash at height \(h) should match across nodes")
            if let cid = h2 {
                XCTAssertNotNil(
                    childStore2.getValidatorParent(childCID: cid),
                    "node2 should install validator pin for synced child block at \(h)"
                )
            }
        }

        await node1.stop()
        await node2.stop()
    }
}
