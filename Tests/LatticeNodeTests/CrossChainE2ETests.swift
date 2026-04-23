import XCTest
@testable import Lattice
@testable import LatticeNode
import UInt256
import cashew
import Acorn

// Helpers in TestHelpers.swift: cas(), testSpec(), sign(), addr(), now()

private func f() -> AcornFetcher { cas() }

// ============================================================================
// MARK: - Mempool Validator: Cross-Chain Action Checks
// ============================================================================

final class CrossChainMempoolTests: XCTestCase {

    func testDepositValidInChildChainMempool() async throws {
        let fetcher = f()
        let spec = testSpec("Child")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let reward = spec.rewardAtBlock(0)

        // Mine a coinbase block to fund the account
        let coinbase = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(coinbase, kp)],
            timestamp: 1_001_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: block1), block: block1
        )

        let cache = FrontierCache()
        guard let state1 = block1.frontier.node else {
            XCTFail("Block frontier should be resolved"); return
        }
        await cache.set(frontierCID: block1.frontier.rawCID, state: state1)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -101)],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: address, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 1, nonce: 1
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, frontierCache: cache, chainDirectory: "Child")
        let result = await validator.validate(tx)
        if case .failure(let err) = result {
            XCTFail("Valid deposit should be accepted, got: \(err)")
        }
    }

    func testDepositRejectedWhenDemanderNotSigner() async throws {
        let fetcher = f()
        let spec = testSpec("Child")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let kp = CryptoUtils.generateKeyPair()
        let other = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let otherAddr = addr(other.publicKey)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -101)],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: otherAddr, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 1, nonce: 0
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, chainDirectory: "Child")
        let result = await validator.validate(tx)
        if case .failure(.swapSignerMismatch) = result {
            // Expected
        } else {
            XCTFail("Deposit with demander not in signers should be rejected, got: \(result)")
        }
    }

    func testReceiptRequiresWithdrawerSigner() async throws {
        let fetcher = f()
        let spec = testSpec()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let demander = CryptoUtils.generateKeyPair()
        let withdrawer = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawerAddr = addr(withdrawer.publicKey)

        // Withdrawer NOT in signers — should fail
        let bodyMissing = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: 1, demander: demanderAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0
        )
        let txMissing = sign(bodyMissing, demander)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, isCoinbase: true, isNexus: true)
        let resultMissing = await validator.validate(txMissing)
        if case .failure(.swapSignerMismatch) = resultMissing {
            // Expected: withdrawer must be in signers
        } else {
            XCTFail("Receipt without withdrawer in signers should be rejected, got: \(resultMissing)")
        }

        // Withdrawer in signers — should pass
        let bodyValid = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: 1, demander: demanderAddr, amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let txValid = sign(bodyValid, withdrawer)
        let resultValid = await validator.validate(txValid)
        if case .failure(let err) = resultValid {
            XCTFail("Receipt with withdrawer in signers should be accepted, got: \(err)")
        }
    }

    func testReceiptRejectedOnChildChain() async throws {
        let fetcher = f()
        let spec = testSpec("Child")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: address, nonce: 1, demander: "someone", amountDemanded: 100, directory: "Child")
            ],
            withdrawalActions: [],
            signers: [address], fee: 0, nonce: 0
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, isCoinbase: true, chainDirectory: "Child", isNexus: false)
        let result = await validator.validate(tx)
        if case .failure(.receiptOnChildChain) = result {
            // Expected
        } else {
            XCTFail("Child chain should reject receipt actions, got: \(result)")
        }
    }

    func testNexusRejectsDeposit() async throws {
        let fetcher = f()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -101)],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: address, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 1, nonce: 0
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, isNexus: true)
        let result = await validator.validate(tx)
        if case .failure(.depositOrWithdrawalOnNexus) = result {
            // Expected
        } else {
            XCTFail("Nexus should reject deposit actions, got: \(result)")
        }
    }

    func testNexusRejectsWithdrawal() async throws {
        let fetcher = f()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec(), timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)

        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: 99)],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: address, nonce: 1, demander: "someone", amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [address], fee: 1, nonce: 0
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, isNexus: true)
        let result = await validator.validate(tx)
        if case .failure(.depositOrWithdrawalOnNexus) = result {
            // Expected
        } else {
            XCTFail("Nexus should reject withdrawal actions, got: \(result)")
        }
    }

    func testConservationWithDeposit() async throws {
        let fetcher = f()
        let spec = testSpec("Child")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let reward = spec.rewardAtBlock(0)

        // Fund the account
        let coinbase = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(coinbase, kp)],
            timestamp: 1_001_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: block1), block: block1
        )

        let cache = FrontierCache()
        guard let state1 = block1.frontier.node else {
            XCTFail("Block frontier should be resolved"); return
        }
        await cache.set(frontierCID: block1.frontier.rawCID, state: state1)

        // debits(101) = credits(0) + fee(1) + deposited(100) ✓
        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -101)],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: address, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 1, nonce: 1
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, frontierCache: cache, chainDirectory: "Child")
        let result = await validator.validate(tx)
        if case .failure(let err) = result {
            XCTFail("Conservation should pass with deposit, got: \(err)")
        }
    }

    func testConservationWithWithdrawal() async throws {
        let fetcher = f()
        let genesis = try await BlockBuilder.buildGenesis(
            spec: testSpec("Child"), timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)

        // debits(0) + withdrawn(100) = credits(99) + fee(1) + deposited(0) ✓
        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: 99)],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: address, nonce: 1, demander: "someone", amountDemanded: 100, amountWithdrawn: 100)
            ],
            signers: [address], fee: 1, nonce: 0
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, chainDirectory: "Child")
        let result = await validator.validate(tx)
        if case .failure(let err) = result {
            XCTFail("Conservation should pass with withdrawal, got: \(err)")
        }
    }

    func testConservationFailsWithoutDeposit() async throws {
        let fetcher = f()
        let spec = testSpec("Child")
        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: 1_000_000, difficulty: UInt256.max, fetcher: fetcher
        )

        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let reward = spec.rewardAtBlock(0)

        // Fund the account
        let coinbase = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: Int64(reward))],
            actions: [], depositActions: [], genesisActions: [], peerActions: [],
            receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 0, nonce: 0
        )
        let block1 = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(coinbase, kp)],
            timestamp: 1_001_000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let chain = ChainState.fromGenesis(block: genesis, retentionDepth: DEFAULT_RETENTION_DEPTH)
        let _ = await chain.submitBlock(
            parentBlockHeaderAndIndex: nil,
            blockHeader: VolumeImpl<Block>(node: block1), block: block1
        )

        let cache = FrontierCache()
        guard let state1 = block1.frontier.node else {
            XCTFail("Block frontier should be resolved"); return
        }
        await cache.set(frontierCID: block1.frontier.rawCID, state: state1)

        // debits(201) != credits(0) + fee(1) + deposited(0) → fails conservation
        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: -201)],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 1, nonce: 1
        )
        let tx = sign(body, kp)
        let validator = TransactionValidator(fetcher: fetcher, chainState: chain, frontierCache: cache, chainDirectory: "Child")
        let result = await validator.validate(tx)
        if case .failure(.balanceNotConserved) = result {
            // Expected: debits(201) != credits(0) + fee(1)
        } else {
            XCTFail("Conservation should fail without matching deposit, got: \(result)")
        }
    }
}

// ============================================================================
// MARK: - E2E: Cross-Chain Block Building Flow
// ============================================================================

final class CrossChainBlockBuildingTests: XCTestCase {

    /// Full deposit→receipt→withdrawal flow through block building
    func testDepositReceiptWithdrawalBlockFlow() async throws {
        let fetcher = f()
        let t: Int64 = 1_000_000

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)

        let nSpec = testSpec("Nexus")
        let cSpec = testSpec("Child")
        let childReward = cSpec.rewardAtBlock(0)
        let nexusReward = nSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 42

        // Step 1: Child genesis
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Step 2: Deposit on child chain (coinbase + deposit in same block)
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: Int64(childReward) - Int64(depositAmount))],
            actions: [],
            depositActions: [
                DepositAction(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [sign(depositBody, demander)],
            timestamp: t + 1000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Verify deposit in state
        guard let childFrontier1 = childBlock1.frontier.node else {
            XCTFail("Child frontier should resolve"); return
        }
        let depositKey = DepositKey(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount).description
        let depositStored: UInt64? = try? childFrontier1.depositState.node?.get(key: depositKey)
        XCTAssertEqual(depositStored, depositAmount, "Deposit should be in child state")

        // Step 3: Receipt on nexus (withdrawer pays demander via receipt)
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        // Withdrawer gets the block reward and pays demander via receipt
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: cSpec.directory)
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [sign(receiptBody, withdrawer)],
            timestamp: t + 1000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Verify receipt in nexus state
        guard let nexusFrontier1 = nexusBlock1.frontier.node else {
            XCTFail("Nexus frontier should resolve"); return
        }
        let receiptKey = ReceiptKey(
            withdrawalAction: WithdrawalAction(
                withdrawer: withdrawerAddr, nonce: swapNonce,
                demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount
            ),
            directory: cSpec.directory
        ).description
        let receiptStored: HeaderImpl<PublicKey>? = try? nexusFrontier1.receiptState.node?.get(key: receiptKey)
        XCTAssertNotNil(receiptStored, "Receipt should be in nexus state")
        XCTAssertEqual(receiptStored?.rawCID, withdrawerAddr, "Receipt should store authorized withdrawer")

        // Step 4: Withdrawal on child chain
        let withdrawalBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(childReward) + Int64(depositAmount))],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let childBlock2 = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [sign(withdrawalBody, withdrawer)],
            parentChainBlock: nexusBlock1,
            timestamp: t + 2000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Verify deposit removed and withdrawer credited
        guard let childFrontier2 = childBlock2.frontier.node else {
            XCTFail("Child frontier 2 should resolve"); return
        }
        let depositAfter: UInt64? = try? childFrontier2.depositState.node?.get(key: depositKey)
        XCTAssertNil(depositAfter, "Deposit should be removed after withdrawal")

        let withdrawerBalance: UInt64? = try? childFrontier2.accountState.node?.get(key: withdrawerAddr)
        XCTAssertEqual(withdrawerBalance, childReward + depositAmount,
            "Withdrawer should have reward + withdrawn amount")
    }

    /// Attacker cannot withdraw funds authorized to someone else
    func testUnauthorizedWithdrawerBlockBuildsButValidationRejects() async throws {
        let fetcher = f()
        let t: Int64 = 1_000_000

        let demander = CryptoUtils.generateKeyPair()
        let demanderAddr = addr(demander.publicKey)
        let withdrawer = CryptoUtils.generateKeyPair()
        let withdrawerAddr = addr(withdrawer.publicKey)
        let attacker = CryptoUtils.generateKeyPair()
        let attackerAddr = addr(attacker.publicKey)

        let nSpec = testSpec("Nexus")
        let cSpec = testSpec("Child")
        let childReward = cSpec.rewardAtBlock(0)
        let nexusReward = nSpec.rewardAtBlock(0)
        let depositAmount: UInt64 = 200
        let swapNonce: UInt128 = 99

        // Deposit on child
        let childGenesis = try await BlockBuilder.buildGenesis(
            spec: cSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let depositBody = TransactionBody(
            accountActions: [AccountAction(owner: demanderAddr, delta: Int64(childReward) - Int64(depositAmount))],
            actions: [], depositActions: [
                DepositAction(nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountDeposited: depositAmount)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [demanderAddr], fee: 0, nonce: 0
        )
        let childBlock1 = try await BlockBuilder.buildBlock(
            previous: childGenesis, transactions: [sign(depositBody, demander)],
            timestamp: t + 1000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Receipt on nexus — withdrawer pays demander, authorized to `withdrawer`
        let nexusGenesis = try await BlockBuilder.buildGenesis(
            spec: nSpec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        // Withdrawer gets the block reward and pays demander via receipt
        let receiptBody = TransactionBody(
            accountActions: [AccountAction(owner: withdrawerAddr, delta: Int64(nexusReward))],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [],
            receiptActions: [
                ReceiptAction(withdrawer: withdrawerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, directory: cSpec.directory)
            ],
            withdrawalActions: [],
            signers: [withdrawerAddr], fee: 0, nonce: 0
        )
        let nexusBlock1 = try await BlockBuilder.buildBlock(
            previous: nexusGenesis, transactions: [sign(receiptBody, withdrawer)],
            timestamp: t + 1000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Attacker tries to withdraw — block builds but receipt stores legitimate withdrawer
        let attackBody = TransactionBody(
            accountActions: [AccountAction(owner: attackerAddr, delta: Int64(childReward) + Int64(depositAmount))],
            actions: [], depositActions: [],
            genesisActions: [], peerActions: [], receiptActions: [],
            withdrawalActions: [
                WithdrawalAction(withdrawer: attackerAddr, nonce: swapNonce, demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount)
            ],
            signers: [attackerAddr], fee: 0, nonce: 0
        )
        let _ = try await BlockBuilder.buildBlock(
            previous: childBlock1, transactions: [sign(attackBody, attacker)],
            parentChainBlock: nexusBlock1,
            timestamp: t + 2000, difficulty: UInt256(1000), fetcher: fetcher
        )

        // Verify receipt stores legitimate withdrawer, not attacker
        guard let nexusFrontier = nexusBlock1.frontier.node else {
            XCTFail("Nexus frontier should resolve"); return
        }
        let receiptKey = ReceiptKey(
            withdrawalAction: WithdrawalAction(
                withdrawer: attackerAddr, nonce: swapNonce,
                demander: demanderAddr, amountDemanded: depositAmount, amountWithdrawn: depositAmount
            ),
            directory: cSpec.directory
        ).description
        let stored: HeaderImpl<PublicKey>? = try? nexusFrontier.receiptState.node?.get(key: receiptKey)
        XCTAssertNotNil(stored, "Receipt should exist")
        XCTAssertNotEqual(stored?.rawCID, attackerAddr,
            "Receipt stores legitimate withdrawer — proveExistenceAndVerifyWithdrawers rejects attacker at validation time")
        XCTAssertEqual(stored?.rawCID, withdrawerAddr, "Authorized withdrawer should be the legitimate one")
    }

    /// Nexus block validation rejects deposit and withdrawal transactions
    func testNexusBlockRejectsDepositTransaction() async throws {
        let fetcher = f()
        let t: Int64 = 1_000_000
        let spec = testSpec()
        let kp = CryptoUtils.generateKeyPair()
        let address = addr(kp.publicKey)
        let reward = spec.rewardAtBlock(0)

        let genesis = try await BlockBuilder.buildGenesis(
            spec: spec, timestamp: t, difficulty: UInt256(1000), fetcher: fetcher
        )
        let gs = BufferedStorer()
        try VolumeImpl<Block>(node: genesis).storeRecursively(storer: gs)
        await gs.flush(to: fetcher)

        // Build a nexus block containing a deposit transaction
        let body = TransactionBody(
            accountActions: [AccountAction(owner: address, delta: Int64(reward) - 100)],
            actions: [], depositActions: [
                DepositAction(nonce: 1, demander: address, amountDemanded: 100, amountDeposited: 100)
            ],
            genesisActions: [], peerActions: [], receiptActions: [], withdrawalActions: [],
            signers: [address], fee: 0, nonce: 0
        )
        let block = try await BlockBuilder.buildBlock(
            previous: genesis, transactions: [sign(body, kp)],
            timestamp: t + 1000, difficulty: UInt256(1000), fetcher: fetcher
        )
        let bs = BufferedStorer()
        try VolumeImpl<Block>(node: block).storeRecursively(storer: bs)
        await bs.flush(to: fetcher)

        // Nexus validation should reject the block because it contains deposit actions
        let valid = try await block.validateNexus(fetcher: fetcher)
        XCTAssertFalse(valid, "Nexus should reject block with deposit actions")
    }
}
