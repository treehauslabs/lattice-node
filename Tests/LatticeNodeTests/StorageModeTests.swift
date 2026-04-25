import XCTest
@testable import LatticeNode
@testable import Lattice
import cashew
import VolumeBroker
import UInt256

final class StorageModeTests: XCTestCase {

    private func makeNode(
        mode: StorageMode,
        blockRetention: BlockRetention = .retention,
        retentionDepth: UInt64 = 3
    ) async throws -> (node: LatticeNode, kp: (privateKey: String, publicKey: String), tmpDir: URL) {
        let port = nextTestPort()
        let kp = CryptoUtils.generateKeyPair()
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port,
            storagePath: tmpDir.appendingPathComponent("node"),
            enableLocalDiscovery: false,
            retentionDepth: retentionDepth,
            storageMode: mode,
            blockRetention: blockRetention
        )
        let genesis = testGenesis()
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        return (node, kp, tmpDir)
    }

    private func diskBroker(for node: LatticeNode, directory: String = "Nexus") async -> DiskBroker? {
        await node.network(for: directory)?.diskBroker
    }

    private func storedRootsAtHeight(_ store: StateStore, _ height: UInt64) -> [(root: String, count: Int)] {
        store.getStoredRoots(height: height)
    }

    private func replacedRootsAtHeight(_ store: StateStore, _ height: UInt64) -> [(root: String, count: Int)] {
        store.getReplacedRoots(height: height)
    }

    // MARK: - Stateful Mode

    func testStatefulPinsCreatedRoots() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(2, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let roots1 = storedRootsAtHeight(store, 1)
        XCTAssertFalse(roots1.isEmpty, "stateful should persist stored roots")

        for (root, _) in roots1 {
            let owners = await broker.owners(root: root)
            XCTAssertTrue(owners.contains("Nexus:1"), "root \(root.prefix(12)) should be pinned by Nexus:1")
        }
    }

    func testStatefulUnpinsReplacedAtRetention() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(1, on: node)

        guard let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing store")
        }

        let rootsBlock1 = storedRootsAtHeight(store, 1)
        XCTAssertFalse(rootsBlock1.isEmpty)

        try await mineBlocks(4, on: node)

        guard let broker = await diskBroker(for: node) else {
            return XCTFail("missing broker")
        }

        let replacedBlock1 = replacedRootsAtHeight(store, 1)
        for (root, _) in replacedBlock1 {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains("Nexus:1"),
                "replaced root from block 1 should be unpinned after retention (height >= 3)")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.isEmpty,
                "latest block's created roots should still be pinned")
        }
    }

    // MARK: - Stateless Mode

    func testStatelessTipOnlyPins() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateless, blockRetention: .tip)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(5, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.isEmpty,
                "even stateless+tip should pin the current tip")
        }

        if height >= 2 {
            let earlyRoots = storedRootsAtHeight(store, 1)
            for (root, _) in earlyRoots {
                let owners = await broker.owners(root: root)
                XCTAssertFalse(owners.contains("Nexus:1"),
                    "tip retention should have unpinned old block's owner")
            }
        }
    }

    func testStatelessStillStoresData() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateless)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(1, on: node)

        guard let broker = await diskBroker(for: node) else {
            return XCTFail("missing broker")
        }

        let tip = await node.lattice.nexus.chain.getMainChainTip()
        let hasBlock = await broker.hasVolume(root: tip)
        XCTAssertTrue(hasBlock, "stateless should still store block data (just not pin it)")
    }

    // MARK: - Historical Mode

    func testHistoricalKeepsMainChainPins() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .historical, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let rootsBlock1 = storedRootsAtHeight(store, 1)
        for (root, _) in rootsBlock1 {
            let owners = await broker.owners(root: root)
            XCTAssertTrue(owners.contains("Nexus:1"),
                "historical mode should keep main chain block 1's pins even past retention")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        for h in UInt64(1)...min(height, 3) {
            let roots = storedRootsAtHeight(store, h)
            for (root, _) in roots {
                let owners = await broker.owners(root: root)
                XCTAssertFalse(owners.isEmpty,
                    "historical mode should keep all main chain pins at height \(h)")
            }
        }
    }

    // MARK: - Ref-counted pins

    func testRefCountedPinSurvivesPartialUnpin() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        guard let broker = await diskBroker(for: node) else {
            return XCTFail("missing broker")
        }

        try await broker.pin(root: "test-root", owner: "Nexus:1", count: 3)
        var owners = await broker.owners(root: "test-root")
        XCTAssertTrue(owners.contains("Nexus:1"))

        try await broker.unpin(root: "test-root", owner: "Nexus:1", count: 2)
        owners = await broker.owners(root: "test-root")
        XCTAssertTrue(owners.contains("Nexus:1"), "count=1 should still be pinned")

        try await broker.unpin(root: "test-root", owner: "Nexus:1", count: 1)
        owners = await broker.owners(root: "test-root")
        XCTAssertTrue(owners.isEmpty, "count=0 should be unpinned")
    }

    // MARK: - StateDiff persistence

    func testStateDiffPersistedPerBlock() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(3, on: node)

        guard let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing store")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        var anyStored = false
        for h in UInt64(1)...height {
            let stored = storedRootsAtHeight(store, h)
            if !stored.isEmpty { anyStored = true }
        }
        XCTAssertTrue(anyStored, "should have stored roots for at least one block")
    }

    // MARK: - Cross-mode: eviction correctness

    func testStatefulEvictionRemovesUnpinnedVolumes() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let evicted = try await broker.evictUnpinned()

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let has = await broker.hasVolume(root: root)
            XCTAssertTrue(has, "latest block's volumes should survive eviction")
        }

        if evicted > 0 {
            let replacedBlock1 = replacedRootsAtHeight(store, 1)
            for (root, _) in replacedBlock1 {
                let owners = await broker.owners(root: root)
                if owners.isEmpty {
                    let has = await broker.hasVolume(root: root)
                    XCTAssertFalse(has,
                        "unpinned replaced root should be evictable")
                }
            }
        }
    }

    // MARK: - Block Retention: tip

    func testBlockRetentionTipUnpinsPreviousBlock() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .tip, retentionDepth: 1000)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(5, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.isEmpty, "latest block roots should be pinned")
        }

        if height >= 2 {
            let oldRoots = storedRootsAtHeight(store, 1)
            for (root, _) in oldRoots {
                let owners = await broker.owners(root: root)
                XCTAssertFalse(owners.contains("Nexus:1"),
                    "tip mode should have unpinned block 1's owner")
            }
        }
    }

    // MARK: - Block Retention: retention

    func testBlockRetentionKeepsWithinDepth() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .retention, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(5, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.isEmpty, "latest block roots should be pinned")
        }

        let oldRoots = storedRootsAtHeight(store, 1)
        for (root, _) in oldRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains("Nexus:1"),
                "block 1 should be unpinned past retention depth 2")
        }
    }

    // MARK: - Block Retention: historical

    func testBlockRetentionHistoricalKeepsMainChain() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .historical, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let rootsBlock1 = storedRootsAtHeight(store, 1)
        for (root, _) in rootsBlock1 {
            let owners = await broker.owners(root: root)
            XCTAssertTrue(owners.contains("Nexus:1"),
                "historical block retention should keep main chain block 1's pins")
        }
    }

    // MARK: - Deep: eviction actually removes data

    func testTipRetentionEvictsOldBlockData() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .tip, retentionDepth: 1000)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(1, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let block1Roots = storedRootsAtHeight(store, 1)
        XCTAssertFalse(block1Roots.isEmpty, "block 1 should have stored roots")

        let block1ExclusiveRoots = block1Roots.map(\.root)
        for root in block1ExclusiveRoots {
            let hasVol = await broker.hasVolume(root: root)
            XCTAssertTrue(hasVol,
                "block 1 Volume data should exist before eviction")
        }

        try await mineBlocks(3, on: node)
        let _ = try await broker.evictUnpinned()

        var anyEvicted = false
        for root in block1ExclusiveRoots {
            let owners = await broker.owners(root: root)
            if owners.isEmpty {
                let has = await broker.hasVolume(root: root)
                if !has { anyEvicted = true }
            }
        }
        XCTAssertTrue(anyEvicted,
            "tip retention + eviction should remove at least some old block data from disk")
    }

    func testRetentionEvictsDataPastDepth() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .retention, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(1, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let block1Roots = storedRootsAtHeight(store, 1).map(\.root)
        for root in block1Roots {
            let hasVol = await broker.hasVolume(root: root)
            XCTAssertTrue(hasVol,
                "block 1 data should exist initially")
        }

        try await mineBlocks(4, on: node)
        let evicted = try await broker.evictUnpinned()

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThanOrEqual(height, 4)

        var anyGone = false
        for root in block1Roots {
            let owners = await broker.owners(root: root)
            let still = await broker.hasVolume(root: root)
            if owners.isEmpty && !still {
                anyGone = true
            }
        }
        XCTAssertTrue(anyGone || evicted > 0,
            "retention depth 2: block 1 data should be evictable after height >= 4")
    }

    func testHistoricalRetentionPreservesDataAtOldHeights() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .historical, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let _ = try await broker.evictUnpinned()

        for h in UInt64(1)...3 {
            let roots = storedRootsAtHeight(store, h)
            for (root, _) in roots {
                let hasVol = await broker.hasVolume(root: root)
            XCTAssertTrue(hasVol,
                    "historical retention: block \(h) data should survive eviction")
            }
        }
    }

    // MARK: - Deep: combined block + state retention

    func testStatefulRetentionCombination() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .stateful, blockRetention: .retention, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let height = await node.lattice.nexus.chain.getHighestBlockIndex()
        XCTAssertGreaterThanOrEqual(height, 5)

        let latestRoots = storedRootsAtHeight(store, height)
        for (root, _) in latestRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.isEmpty,
                "latest block data should always be pinned")
            let hasVol = await broker.hasVolume(root: root)
            XCTAssertTrue(hasVol,
                "latest block Volume should exist")
        }

        let block1StoredRoots = storedRootsAtHeight(store, 1)
        let block1ReplacedRoots = replacedRootsAtHeight(store, 1)

        let _ = try await broker.evictUnpinned()

        for (root, _) in block1StoredRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains("Nexus:1"),
                "retention: block 1 owner should be gone (block pruning)")
        }

        for (root, _) in block1ReplacedRoots {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains("Nexus:1"),
                "stateful: block 1's replaced state roots should be unpinned")
        }
    }

    func testHistoricalStateCombinedWithRetentionBlocks() async throws {
        let (node, _, tmpDir) = try await makeNode(mode: .historical, blockRetention: .retention, retentionDepth: 2)
        defer { Task { await node.stop() }; try? FileManager.default.removeItem(at: tmpDir) }

        try await mineBlocks(6, on: node)

        guard let broker = await diskBroker(for: node),
              let store = await node.stateStore(for: "Nexus") else {
            return XCTFail("missing broker or store")
        }

        let block1Stored = storedRootsAtHeight(store, 1)
        for (root, _) in block1Stored {
            let owners = await broker.owners(root: root)
            XCTAssertFalse(owners.contains("Nexus:1"),
                "retention block mode unpins block 1 past depth")
        }

        let block1Replaced = replacedRootsAtHeight(store, 1)
        for (root, _) in block1Replaced {
            let owners = await broker.owners(root: root)
            XCTAssertTrue(owners.contains("Nexus:1"),
                "historical state mode should keep main chain replaced roots pinned")
        }
    }
}
