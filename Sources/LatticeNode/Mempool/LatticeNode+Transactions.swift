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
        case .added, .replacedExisting:
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
    /// With automatic receipts (v2), there is no pending pool. All
    /// transactions are either admitted as valid or rejected outright.
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
                frontierCache: postStateCaches[directory],
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

        return await network.nodeMempool.addTransaction(transaction)
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
    /// the same `admitToMempool` classifier as direct submits.
    /// Returns true on any acceptance (added or replaced) so the caller
    /// can rebroadcast.
    nonisolated public func chainNetwork(_ network: ChainNetwork, admitTransaction transaction: Transaction, bodyCID: String) async -> Bool {
        let directory = await network.directory
        let result = await admitToMempool(transaction: transaction, directory: directory)
        switch result {
        case .added, .replacedExisting: return true
        case .rejected: return false
        }
    }

}
