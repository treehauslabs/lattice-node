import XCTest
@testable import Lattice
@testable import LatticeNode

/// P1 #5: child-block CAS writes are deduped by skipping the full
/// `storeBlockRecursively` walk when the subtree is already resident in the
/// shared CAS (the parent block's walk persists it). Guard rails:
///   - `ChainNetwork.hasCID` must reflect bytes that actually landed in CAS.
///   - `registerBlockVolume` must be safe to call for a CID whose bytes are
///     already present and must not depend on caller-provided childCIDs.
final class ChildBlockDedupeTests: XCTestCase {

    func testHasCIDReflectsCASResidency() async throws {
        let kp = CryptoUtils.generateKeyPair()
        let port = nextTestPort()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let genesis = testGenesis()
        let config = LatticeNodeConfig(
            publicKey: kp.publicKey, privateKey: kp.privateKey,
            listenPort: port, storagePath: tmp,
            enableLocalDiscovery: false
        )
        let node = try await LatticeNode(config: config, genesisConfig: genesis)
        try await node.start()
        defer { Task { await node.stop() } }

        try await mineBlocks(1, on: node)

        let nexusDir = "Nexus"
        guard let network = await node.network(for: nexusDir),
              let chain = await node.chain(for: nexusDir) else {
            XCTFail("nexus network missing"); return
        }
        let tipCID = await chain.getMainChainTip()
        XCTAssertFalse(tipCID.isEmpty, "chain should have advanced past genesis")

        let hasTip = await network.hasCID(tipCID)
        XCTAssertTrue(hasTip, "storeBlockRecursively must make tip bytes observable via hasCID")

        // Random CID must miss — otherwise the fast path would skip the walk
        // for genuinely-absent subtrees and leak missing bytes downstream.
        let hasBogus = await network.hasCID("bafybogusdoesnotexist0000000000000000000000000")
        XCTAssertFalse(hasBogus, "hasCID must not report presence for unknown CIDs")
    }

}
