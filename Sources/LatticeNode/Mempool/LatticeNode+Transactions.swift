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
        let chain = directory == genesisConfig.spec.directory
            ? await lattice.nexus.chain
            : await lattice.nexus.children[directory]?.chain
        if let chain {
            let isNexus = directory == genesisConfig.spec.directory
            let validator = TransactionValidator(fetcher: await network.fetcher, chainState: chain, stateStore: stateStores[directory], frontierCache: frontierCaches[directory], chainDirectory: directory, isNexus: isNexus)
            let result = await validator.validate(transaction)
            switch result {
            case .failure(let error):
                return .failure(describeValidationError(error))
            case .success:
                break
            }
        }
        if let sender = transaction.body.node?.signers.first,
           let storeNonce = stateStores[directory]?.getNonce(address: sender) {
            await network.nodeMempool.seedConfirmedNonceIfUnset(sender: sender, nonce: storeNonce)
        }
        let added = await network.submitTransaction(transaction)
        if added {
            let bodyData = transaction.body.node?.toData()
            // Store body to CAS so we can serve it to others
            if let bodyData {
                await network.storeLocally(cid: transaction.body.rawCID, data: bodyData)
            }
            metrics.increment("lattice_transactions_submitted_total")
            // Gossip with full signed transaction — receivers can validate and add to mempool
            let txData = transaction.toData()
            await network.gossipTransaction(cid: transaction.body.rawCID, transactionData: txData)
            let fee = transaction.body.node?.fee ?? 0
            let sender = transaction.body.node?.signers.first ?? ""
            await subscriptions.emit(.newTransaction(
                cid: transaction.body.rawCID,
                fee: fee,
                sender: sender
            ))
            return .success
        }
        return .failure("Transaction rejected by mempool")
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
        case .swapSignerMismatch:
            return "Swap action sender not in signers"
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

    // MARK: - Gossip Validation

    nonisolated public func chainNetwork(_ network: ChainNetwork, shouldAcceptTransaction transaction: Transaction, bodyCID: String) async -> Bool {
        let directory = await network.directory
        return await validateGossipedTransaction(transaction, directory: directory)
    }

    func validateGossipedTransaction(_ transaction: Transaction, directory: String) async -> Bool {
        guard let chain = await chain(for: directory) else { return true }
        guard let network = networks[directory] else { return true }
        let isNexus = directory == genesisConfig.spec.directory
        let validator = TransactionValidator(
            fetcher: await network.fetcher,
            chainState: chain,
            stateStore: stateStores[directory],
            frontierCache: frontierCaches[directory],
            chainDirectory: directory,
            isNexus: isNexus
        )
        let result = await validator.validate(transaction)
        guard case .success = result else { return false }
        if let sender = transaction.body.node?.signers.first,
           let storeNonce = stateStores[directory]?.getNonce(address: sender) {
            await network.nodeMempool.seedConfirmedNonceIfUnset(sender: sender, nonce: storeNonce)
        }
        return true
    }

    public func broadcastTransaction(directory: String, transaction: Transaction) async {
        guard let network = networks[directory] else { return }
        guard let bodyData = transaction.body.node?.toData() else { return }
        await network.storeLocally(cid: transaction.body.rawCID, data: bodyData)
        await network.gossipTransaction(cid: transaction.body.rawCID)
    }
}
