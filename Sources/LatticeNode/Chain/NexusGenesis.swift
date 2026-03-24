import Lattice
import Foundation
import cashew
import UInt256

public enum NexusGenesis {

    // MARK: - Premine Owner

    public static let ownerPublicKeyHex =
        "c01c054a190f8dbd88474fbeb2b08b3b86ecb930f458a8fd7e0ecbedca245b15" +
        "32ae64647f29f0279bde50cb7e5c709f46536f746fc8c3a5f40a5b5315fa4efd"

    static let ownerPrivateKeyHex =
        "fee40cad9ce94780c9fa0173ef1be5da7a244137ace06a9bd6a39c010c61ea3f"

    public static let ownerAddress = CryptoUtils.createAddress(from: ownerPublicKeyHex)

    // MARK: - Chain Specification
    //
    // Economics:
    //   initialReward        = 2^20 = 1,048,576 tokens/block
    //   halvingInterval      = 315,576,000 blocks (~100 years at 10s blocks)
    //   totalSupply          ≈ 2 × halvingInterval × initialReward = 661,608,843,264,000
    //   premine              = halvingInterval / 5 = 63,115,200 blocks worth
    //   premineAmount        = premine × initialReward = 66,160,884,326,400 (~10%)
    //
    //   targetBlockTime      = 10,000 ms (10 seconds)
    //   maxTransactions/block = 5,000
    //   maxStateGrowth       = 3 MB per block
    //   maxBlockSize         = 10 MB
    //   difficultyWindow     = 120 blocks (~20 minutes)

    public static let spec = ChainSpec(
        directory: "Nexus",
        maxNumberOfTransactionsPerBlock: 5000,
        maxStateGrowth: 3_000_000,
        maxBlockSize: 10_000_000,
        premine: 63_115_200,
        targetBlockTime: 10_000,
        initialReward: 1_048_576,
        halvingInterval: 315_576_000,
        difficultyAdjustmentWindow: 120
    )

    // MARK: - Genesis Identity
    //
    // The expected block hash is computed from the genesis block with the
    // new 100-year halving economics. Set to nil to auto-compute on first run,
    // then hardcode the result for deterministic verification.

    nonisolated(unsafe) public static var expectedBlockHash: String?

    // MARK: - Genesis Configuration

    public static let genesisTimestamp: Int64 = 1_742_601_600_000

    public static let config = GenesisConfig(
        spec: spec,
        timestamp: genesisTimestamp,
        difficulty: UInt256.max
    )

    public static func verifyGenesis(_ result: GenesisResult) -> Bool {
        if let expected = expectedBlockHash {
            return result.blockHash == expected
        }
        expectedBlockHash = result.blockHash
        return true
    }

    // MARK: - Genesis Creation

    public static func create(fetcher: Fetcher) async throws -> GenesisResult {
        let premineAmount = spec.premineAmount()
        let accountAction = AccountAction(
            owner: ownerAddress,
            oldBalance: 0,
            newBalance: premineAmount
        )
        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            swapActions: [],
            swapClaimActions: [],
            genesisActions: [],
            peerActions: [],
            settleActions: [],
            signers: [ownerAddress],
            fee: 0,
            nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let transaction = Transaction(
            signatures: [ownerPublicKeyHex: "genesis"],
            body: bodyHeader
        )
        let block = try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [transaction],
            timestamp: config.timestamp,
            difficulty: config.difficulty,
            fetcher: fetcher
        )
        let blockHash = HeaderImpl<Block>(node: block).rawCID
        let chainState = ChainState.fromGenesis(block: block, retentionDepth: DEFAULT_RETENTION_DEPTH)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }
}
