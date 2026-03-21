import Lattice
import Foundation
import cashew
import UInt256

public enum NexusGenesis {

    // MARK: - Premine Owner

    public static let ownerPublicKeyHex =
        "23bd122868fd8d414440961d1c2bdc32c5fd3ae4fa148e2efb53b99ed1f268a1" +
        "2518099ef534c7d5bfeb854173d417c2b15bf929b26606dc054e548fab3e5d36"

    public static let ownerAddress =
        "baguqeerawndzsjdmx4tkndm7evea6qsvrprpv4jvabrzhdzvijf4rivlq3hq"

    // MARK: - Chain Specification
    //
    // Economics:
    //   initialReward        = 2^20 = 1,048,576
    //   halvingInterval      = 2^44 = 17,592,186,044,416 blocks
    //   totalSupply          ≈ 2^65 (geometric series, halving to zero)
    //   premine              = halvingInterval / 5 = 3,518,437,208,883 blocks
    //   premineAmount        = 3,689,348,814,741,700,608
    //   premineAmount / totalSupply ≈ 10%
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
        premine: 3_518_437_208_883,
        targetBlockTime: 10_000,
        initialReward: 1_048_576,
        halvingInterval: 17_592_186_044_416,
        difficultyAdjustmentWindow: 120
    )

    // MARK: - Pre-computed Genesis Transaction Signature

    static let premineSignature =
        "2166be9fc56bd628c723a68ff5af1ef6ccc43dcff60617431996ad6f006b0a8d" +
        "da161ddb21e396fa6d562210a1fe7e5b5cafa0ac1c09598d38a1b9f9be9fc294"

    // MARK: - Chain Identity

    public static let expectedBlockHash =
        "baguqeerae7p6crb5k44mtn7iwg7hpls7pikwoo7hjdg2ch5tdluvgfqy774a"

    // MARK: - Genesis Configuration

    public static let config = GenesisConfig(
        spec: spec,
        timestamp: 0,
        difficulty: UInt256.max
    )

    public static func verifyGenesis(_ result: GenesisResult) -> Bool {
        result.blockHash == expectedBlockHash
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
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [ownerAddress],
            fee: 0,
            nonce: 0
        )
        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        let transaction = Transaction(
            signatures: [ownerPublicKeyHex: premineSignature],
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
        let chainState = ChainState.fromGenesis(block: block)
        return GenesisResult(block: block, blockHash: blockHash, chainState: chainState)
    }
}
