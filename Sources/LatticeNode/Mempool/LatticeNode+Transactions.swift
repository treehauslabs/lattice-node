import Lattice
import Foundation
import cashew

extension LatticeNode {

    public func submitTransaction(directory: String, transaction: Transaction) async -> Bool {
        switch await submitTransactionWithReason(directory: directory, transaction: transaction) {
        case .success: return true
        case .failure: return false
        }
    }

    public enum TransactionSubmitResult: Sendable {
        case success
        case failure(String)
    }

    public func submitTransactionWithReason(directory: String, transaction: Transaction) async -> TransactionSubmitResult {
        guard let network = networks[directory] else {
            return .failure("Unknown chain: \(directory)")
        }
        let addResult = await admitToMempool(transaction: transaction, directory: directory)
        switch addResult {
        case .rejected(let reason):
            return .failure(reason)
        case .added, .addedPending, .replacedExisting:
            break
        }
        metrics.increment("lattice_transactions_submitted_total")
        if let bodyData = transaction.body.node?.toData(),
           let txData = transaction.toData() {
            await network.storeLocally(cid: transaction.body.rawCID, data: bodyData)
            await network.gossipTransaction(cid: transaction.body.rawCID, bodyData: bodyData, transactionData: txData)
        }
        let fee = transaction.body.node?.fee ?? 0
        let sender = transaction.body.node?.signers.first ?? ""
        await subscriptions.emit(.newTransaction(
            cid: transaction.body.rawCID,
            fee: fee,
            sender: sender
        ))
        return .success
    }

    /// Unified mempool admission for any chain. One classifier funnels:
    ///   - direct submit (RPC, restart restoration)
    ///   - gossip-received transactions
    ///   - reorg orphan re-add (nexus and child)
    ///
    /// On a non-nexus chain, withdrawal-bearing transactions are classified
    /// against the parent chain's receiptState at its current tip:
    ///   - all required receipts present + match expected withdrawer → valid
    ///   - any required receipt missing → pending (held until parent block
    ///     adds it; nonce slot reserved, never selected by the miner)
    ///   - any receipt-present-but-wrong-withdrawer → rejected (permanent;
    ///     receipt key already commits to a different owner on parent chain)
    ///
    /// Pending classification is the fix for the receipt-visibility race in
    /// merged mining: a withdrawal whose required receipt is being added to
    /// the parent block in the same round used to silently fail validation
    /// and get dropped from mempool. With pending, it sits dormant until
    /// the parent block lands, then `recheckPending` promotes it.
    public func admitToMempool(transaction: Transaction, directory: String) async -> AddResult {
        guard let network = networks[directory] else {
            return .rejected(reason: "Unknown chain: \(directory)")
        }
        guard let body = transaction.body.node else {
            return .rejected(reason: "Missing transaction body")
        }

        if let chain = await chain(for: directory) {
            let isNexus = directory == genesisConfig.spec.directory
            let validator = TransactionValidator(
                fetcher: await network.fetcher,
                chainState: chain,
                frontierCache: frontierCaches[directory],
                chainDirectory: directory,
                isNexus: isNexus
            )
            let result = await validator.validate(transaction)
            if case .failure(let error) = result {
                return .rejected(reason: describeValidationError(error))
            }
        }

        if let sender = body.signers.first,
           let tipNonce = try? await getNonce(address: sender, directory: directory) {
            await network.nodeMempool.updateConfirmedNonce(sender: sender, nonce: tipNonce)
        }

        // Withdrawals only exist on child chains; on the nexus the validator
        // will already have rejected. Empty-withdrawals tx skips parent probe.
        let nexusDir = genesisConfig.spec.directory
        if directory == nexusDir || body.withdrawalActions.isEmpty {
            return await network.nodeMempool.addTransaction(transaction)
        }

        var pending: Set<ReceiptRequirement> = []
        for wa in body.withdrawalActions {
            let key = ReceiptKey(withdrawalAction: wa, directory: directory).description
            // getReceipt returns String? (nil = absent); try? wraps into
            // String?? on throw, so flatten back to String? before use.
            let stored: String? = (try? await getReceipt(
                demander: wa.demander,
                amountDemanded: wa.amountDemanded,
                nonce: wa.nonce,
                directory: directory
            )) ?? nil
            if let stored {
                // Receipt key on parent commits to a single withdrawer.
                // Mismatch is permanent — no future state change can flip it.
                if stored != wa.withdrawer {
                    return .rejected(reason: "Receipt \(key) belongs to \(stored), not \(wa.withdrawer)")
                }
            } else {
                pending.insert(ReceiptRequirement(
                    receiptKey: key,
                    expectedWithdrawer: wa.withdrawer
                ))
            }
        }

        if pending.isEmpty {
            return await network.nodeMempool.addTransaction(transaction)
        }
        return await network.nodeMempool.addPendingTransaction(
            transaction,
            receiptRequirements: pending
        )
    }

    func describeValidationError(_ error: TransactionValidationError) -> String {
        switch error {
        case .missingBody:
            return "Transaction body not resolved"
        case .invalidSignatures:
            return "Invalid signature(s)"
        case .signerMismatch:
            return "Signers do not match signatures"
        case .duplicateAccountOwner(let owner):
            return "Duplicate account action for owner: \(owner)"
        case .insufficientBalance(let owner, let balance, let required):
            return "Insufficient balance for \(owner): has \(balance), needs \(required)"
        case .noStateAvailable:
            return "Chain state not available"
        case .depositActionInvalid:
            return "Deposit action invalid (zero amount or demander not in signers)"
        case .receiptActionInvalid:
            return "Receipt action invalid (zero amount or withdrawer not in signers)"
        case .withdrawalActionInvalid:
            return "Withdrawal action invalid (zero amount or withdrawer not in signers)"
        case .stateResolutionFailed:
            return "Failed to resolve chain state"
        case .feeTooLow(let actual, let minimum):
            return "Fee too low: \(actual) < minimum \(minimum)"
        case .nonceAlreadyUsed(let nonce):
            return "Nonce already used or expired: \(nonce)"
        case .nonceFromFuture(let nonce):
            return "Nonce too far in the future: \(nonce)"
        case .balanceNotConserved(let debits, let credits, let fee):
            return "Balance not conserved: debits \(debits) != credits \(credits) + fee \(fee)"
        case .transactionTooLarge(let size, let max):
            return "Transaction too large: \(size) bytes (max \(max))"
        case .feeTooHigh(let actual, let maximum):
            return "Fee too high: \(actual) > maximum \(maximum)"
        case .chainPathMismatch:
            return "Transaction chainPath does not match this chain"
        case .depositOrWithdrawalOnNexus:
            return "Deposit and withdrawal actions are not allowed on the nexus chain"
        case .receiptOnChildChain:
            return "Receipt actions are not allowed on child chains"
        }
    }

    // MARK: - Gossip Admission

    /// Gossip-path admission. Funnels a peer-broadcast transaction through
    /// the same `admitToMempool` classifier as direct submits — receipt-
    /// blocked withdrawals land in pending instead of being silently dropped.
    /// Returns true on any acceptance (valid, pending, or replaced) so the
    /// caller can rebroadcast.
    nonisolated public func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> Bool {
        let directory = await network.directory
        let result = await admitToMempool(transaction: transaction, directory: directory)
        switch result {
        case .added, .addedPending, .replacedExisting: return true
        case .rejected: return false
        }
    }

}
