import Lattice
import Foundation
import cashew
import UInt256

public enum TestnetGenesis {

    // MARK: - Premine Owner
    //
    // Faucet keypair — generated with `lattice-node keys generate`.
    // Store the private key offline; it is needed to sign faucet disbursements.
    // Private key: 19cda640794d333f4b254a9536b4608f35e10480deb216a69ead5831c95727e8

    public static let ownerPublicKeyHex =
        "9d961895fbbc94b3db1742d4c8d8f04939540245c67ed9728aa832de96152dff"

    public static let ownerAddress = CryptoUtils.createAddress(from: ownerPublicKeyHex)

    // MARK: - Chain Specification
    //
    // Mirrors mainnet economics at a 315× compressed timescale so halvings
    // and supply dynamics are observable within months, not decades.
    //
    //   initialReward        = 2^20 = 1,048,576 tokens/block
    //   halvingInterval      = 1,000,000 blocks (~115 days at 10s blocks)
    //   totalSupply          ≈ 2 × halvingInterval × initialReward = 2,097,152,000,000
    //   premine              = halvingInterval / 5 = 200,000 blocks worth
    //   premineAmount        = premine × initialReward = 209,715,200,000 (~10%)
    //
    //   targetBlockTime      = 10,000 ms — identical to mainnet
    //   difficultyWindow     = 120 blocks (~20 minutes)

    public static let spec = ChainSpec(
        directory: "Nexus",
        maxNumberOfTransactionsPerBlock: 5000,
        maxStateGrowth: 3_000_000,
        maxBlockSize: 10_000_000,
        premine: 200_000,
        targetBlockTime: 10_000,
        initialReward: 1_048_576,
        halvingInterval: 1_000_000,
        difficultyAdjustmentWindow: 120
    )

    // MARK: - Genesis Identity
    //
    // expectedBlockHash is nil until the testnet launches. Run once with nil,
    // capture the printed genesis CID, then hardcode it so every node verifies
    // they share the same chain.

    public static let expectedBlockHash: String? = "baguqeeraxodjzhzgip6j5w6ucjfhnj23l3qjc6mlv5rirywrulpufvjurodq"

    // MARK: - Genesis Configuration

    public static let genesisTimestamp: Int64 = 1_778_130_000_000   // 2026-05-07 00:00:00 UTC

    public static let config = GenesisConfig(
        spec: spec,
        timestamp: genesisTimestamp,
        difficulty: UInt256.max
    )

    public static func verifyGenesis(_ result: GenesisResult) -> Bool {
        if let expected = expectedBlockHash {
            return result.blockHash == expected
        }
        return true
    }

    // MARK: - Genesis Builder

    public static func buildGenesisBlock(config: GenesisConfig, fetcher: Fetcher) async throws -> Block {
        let premineAmount = spec.premineAmount()
        let accountAction = AccountAction(
            owner: ownerAddress,
            delta: Int64(premineAmount)
        )
        let body = TransactionBody(
            accountActions: [accountAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [ownerAddress],
            fee: 0,
            nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let transaction = Transaction(
            signatures: [ownerPublicKeyHex: "genesis"],
            body: bodyHeader
        )
        return try await BlockBuilder.buildGenesis(
            spec: config.spec,
            transactions: [transaction],
            timestamp: config.timestamp,
            difficulty: config.difficulty,
            fetcher: fetcher
        )
    }

    // MARK: - Genesis Creation

    public static func create(fetcher: Fetcher) async throws -> GenesisResult {
        let block = try await buildGenesisBlock(config: config, fetcher: fetcher)
        let blockHash = VolumeImpl<Block>(node: block).rawCID
        let chainState = ChainState.fromGenesis(block: block, retentionDepth: DEFAULT_RETENTION_DEPTH)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }
}
