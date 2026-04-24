import XCTest
@testable import Lattice
@testable import LatticeNode
@testable import Ivy
import UInt256
import cashew
import ArrayTrie

/// UNSTOPPABLE_LATTICE P1 #14,#15: every deploy-then-destroy cycle must release
/// every per-chain map, caches, StateStore, protection policy, and metric
/// series. Without this, a node that churns child chains leaks bytes per cycle.
final class ChainLifecycleCleanupTests: XCTestCase {

    func testDestroyChainNetworkClearsAllPerChainState() async throws {
        let p1 = nextTestPort()
        let p2 = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var subs = ArrayTrie<Bool>()
        subs.set(["Nexus"], value: true)
        subs.set(["Nexus", "Child"], value: true)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false, persistInterval: 5,
            subscribedChains: subs
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()

        let nexusNet = await node.network(for: "Nexus")!
        let childSpec = testSpec("Child")
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: childSpec,
            timestamp: now() - 10_000,
            difficulty: UInt256.max,
            fetcher: nexusNet.ivyFetcher
        )
        await node.lattice.nexus.subscribe(to: "Child", genesisBlock: childGenesis)
        let ivyConfig = IvyConfig(
            publicKey: kp.publicKey, listenPort: p2,
            bootstrapPeers: [], enableLocalDiscovery: false
        )
        try await node.registerChainNetwork(directory: "Child", config: ivyConfig)

        // Write a per-chain metric series so we can watch cleanup remove it.
        // NodeMetrics is Sendable, so pull it out across the actor hop once.
        let metrics = await node.metrics
        metrics.set("lattice_chain_height{chain=\"Child\"}", value: 0)
        metrics.set("lattice_chain_height{chain=\"Nexus\"}", value: 0)

        // Sanity-check presence before destroy.
        let dirsBefore = await node.allDirectories()
        XCTAssertTrue(dirsBefore.contains("Child"), "Child should be registered")
        let childNetBefore = await node.network(for: "Child")
        XCTAssertNotNil(childNetBefore)
        let childStoreBefore = await node.stateStore(for: "Child")
        XCTAssertNotNil(childStoreBefore)
        let childPolicyBefore = await node.unionProtection.policy(for: "Child")
        XCTAssertNotNil(childPolicyBefore)
        XCTAssertTrue(metrics.prometheus().contains("chain=\"Child\""))

        await node.destroyChainNetwork(directory: "Child")

        // Every per-chain handle the node holds should be gone.
        let childNetAfter = await node.network(for: "Child")
        XCTAssertNil(childNetAfter, "networks entry should be dropped")
        let childStoreAfter = await node.stateStore(for: "Child")
        XCTAssertNil(childStoreAfter, "stateStores entry should be dropped")
        let childPolicyAfter = await node.unionProtection.policy(for: "Child")
        XCTAssertNil(childPolicyAfter, "UnionProtectionPolicy should no longer include Child")

        let dirsAfter = await node.allDirectories()
        XCTAssertFalse(dirsAfter.contains("Child"), "allDirectories should no longer list Child")
        XCTAssertTrue(dirsAfter.contains("Nexus"), "Nexus should survive the child teardown")

        // Per-chain metric keys scrubbed; nexus keys untouched.
        let metricsText = metrics.prometheus()
        XCTAssertFalse(metricsText.contains("chain=\"Child\""),
                       "Per-chain metric series should be dropped")
        XCTAssertTrue(metricsText.contains("chain=\"Nexus\""),
                      "Nexus metric series should survive child teardown")

        // Nexus chain still functions.
        let nexusNetAfter = await node.network(for: "Nexus")
        XCTAssertNotNil(nexusNetAfter)
        let nexusChainAfter = await node.chain(for: "Nexus")
        XCTAssertNotNil(nexusChainAfter)

        await node.stop()
    }

    func testDestroyChainNetworkRefusesNexus() async throws {
        let p1 = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: p1, storagePath: tmpDir.appendingPathComponent("node1"),
            enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: testGenesis())
        try await node.start()

        await node.destroyChainNetwork(directory: "Nexus")

        let nexusNet = await node.network(for: "Nexus")
        XCTAssertNotNil(nexusNet,
                        "Destroying the nexus must be a no-op — it's load-bearing")
        let nexusChain = await node.chain(for: "Nexus")
        XCTAssertNotNil(nexusChain)

        await node.stop()
    }
}
