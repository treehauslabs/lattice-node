import Lattice
import Foundation
import cashew
import UInt256

public let MINIMUM_TRANSACTION_FEE: UInt64 = 1
public let MAX_TRANSACTION_FEE: UInt64 = 1_000_000_000_000
public let MAX_NONCE_DRIFT: UInt64 = 64
public let MAX_TRANSACTION_SIZE: Int = 102_400

public enum TransactionValidationError: Error, Sendable {
    case missingBody
    case invalidSignatures
    case signerMismatch
    case duplicateAccountOwner(String)
    case insufficientBalance(owner: String, balance: UInt64, required: UInt64)
    case noStateAvailable
    case swapSignerMismatch
    case stateResolutionFailed
    case feeTooLow(actual: UInt64, minimum: UInt64)
    case feeTooHigh(actual: UInt64, maximum: UInt64)
    case nonceAlreadyUsed(nonce: UInt64)
    case nonceFromFuture(nonce: UInt64)
    case balanceNotConserved(totalDebits: UInt64, totalCredits: UInt64, fee: UInt64)
    case transactionTooLarge(size: Int, max: Int)
    case chainPathMismatch
    case depositOrWithdrawalOnNexus
}

public struct TransactionValidator: Sendable {
    private let fetcher: Fetcher
    private let chainState: ChainState
    private let isCoinbase: Bool
    private let stateStore: StateStore?
    private let frontierCache: FrontierCache?
    private let chainDirectory: String?
    private let isNexus: Bool

    public init(fetcher: Fetcher, chainState: ChainState, isCoinbase: Bool = false, stateStore: StateStore? = nil, frontierCache: FrontierCache? = nil, chainDirectory: String? = nil, isNexus: Bool = false) {
        self.fetcher = fetcher
        self.chainState = chainState
        self.isCoinbase = isCoinbase
        self.stateStore = stateStore
        self.frontierCache = frontierCache
        self.chainDirectory = chainDirectory
        self.isNexus = isNexus
    }

    public func validate(_ transaction: Transaction) async -> Result<Void, TransactionValidationError> {
        guard let body = transaction.body.node else {
            return .failure(.missingBody)
        }

        if let err = validateSize(body) { return .failure(err) }
        if let err = await validateSignatures(transaction, body: body) { return .failure(err) }
        if let err = validateFees(body) { return .failure(err) }
        if let err = validateNonce(body) { return .failure(err) }
        if let err = validateChainPath(body) { return .failure(err) }
        if let err = validateSwaps(body) { return .failure(err) }
        if let err = validateUniqueOwners(body) { return .failure(err) }
        if let err = await validateBalances(body) { return .failure(err) }
        if let err = validateConservation(body) { return .failure(err) }

        return .success(())
    }

    // MARK: - Validation Phases

    private func validateSize(_ body: TransactionBody) -> TransactionValidationError? {
        if let bodyData = body.toData(), bodyData.count > MAX_TRANSACTION_SIZE {
            return .transactionTooLarge(size: bodyData.count, max: MAX_TRANSACTION_SIZE)
        }
        return nil
    }

    private func validateSignatures(_ transaction: Transaction, body: TransactionBody) async -> TransactionValidationError? {
        if transaction.signatures.isEmpty {
            return .invalidSignatures
        }
        let sigMessage = transaction.body.rawCID
        let sigs = Array(transaction.signatures)
        if sigs.count == 1 {
            if !CryptoUtils.verify(message: sigMessage, signature: sigs[0].value, publicKeyHex: sigs[0].key) {
                return .invalidSignatures
            }
        } else {
            let allValid = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                for (publicKeyHex, signature) in sigs {
                    group.addTask {
                        CryptoUtils.verify(message: sigMessage, signature: signature, publicKeyHex: publicKeyHex)
                    }
                }
                for await result in group {
                    if !result { group.cancelAll(); return false }
                }
                return true
            }
            if !allValid { return .invalidSignatures }
        }

        let signatureAddresses = Set(transaction.signatures.keys.map {
            HeaderImpl<PublicKey>(node: PublicKey(key: $0)).rawCID
        })
        for signer in body.signers {
            if !signatureAddresses.contains(signer) {
                return .signerMismatch
            }
        }

        let signerSet = Set(body.signers)
        for action in body.accountActions where action.isDebit {
            if !signerSet.contains(action.owner) {
                return .signerMismatch
            }
        }

        return nil
    }

    private func validateFees(_ body: TransactionBody) -> TransactionValidationError? {
        if !isCoinbase && body.fee < MINIMUM_TRANSACTION_FEE {
            return .feeTooLow(actual: body.fee, minimum: MINIMUM_TRANSACTION_FEE)
        }
        if !isCoinbase && body.fee > MAX_TRANSACTION_FEE {
            return .feeTooHigh(actual: body.fee, maximum: MAX_TRANSACTION_FEE)
        }
        return nil
    }

    private func validateNonce(_ body: TransactionBody) -> TransactionValidationError? {
        guard !isCoinbase else { return nil }
        let sender = body.signers.first ?? ""
        let confirmedNonce = stateStore?.getNonce(address: sender) ?? 0
        if body.nonce < confirmedNonce {
            return .nonceAlreadyUsed(nonce: body.nonce)
        }
        if body.nonce > confirmedNonce + MAX_NONCE_DRIFT {
            return .nonceFromFuture(nonce: body.nonce)
        }
        return nil
    }

    private func validateChainPath(_ body: TransactionBody) -> TransactionValidationError? {
        guard !body.chainPath.isEmpty, let dir = chainDirectory else { return nil }
        if !body.chainPath.contains(dir) { return .chainPathMismatch }
        return nil
    }

    private func validateSwaps(_ body: TransactionBody) -> TransactionValidationError? {
        // Nexus cannot have deposit or withdrawal actions
        if isNexus {
            if !body.depositActions.isEmpty { return .depositOrWithdrawalOnNexus }
            if !body.withdrawalActions.isEmpty { return .depositOrWithdrawalOnNexus }
        }
        let signerSet = Set(body.signers)
        for deposit in body.depositActions {
            if deposit.amountDeposited == 0 { return .swapSignerMismatch }
            if deposit.amountDeposited != deposit.amountDemanded { return .swapSignerMismatch }
            if !signerSet.contains(deposit.demander) { return .swapSignerMismatch }
        }
        for withdrawal in body.withdrawalActions {
            if withdrawal.amountWithdrawn == 0 { return .swapSignerMismatch }
            if withdrawal.amountWithdrawn != withdrawal.amountDemanded { return .swapSignerMismatch }
            if !signerSet.contains(withdrawal.withdrawer) { return .swapSignerMismatch }
        }
        // Receipt actions don't need specific signer checks — the normal
        // account action signing ensures the fee payer authorized the transaction
        return nil
    }

    private func validateUniqueOwners(_ body: TransactionBody) -> TransactionValidationError? {
        var seenOwners = Set<String>()
        for action in body.accountActions {
            if !seenOwners.insert(action.owner).inserted {
                return .duplicateAccountOwner(action.owner)
            }
        }
        return nil
    }

    private func validateBalances(_ body: TransactionBody) async -> TransactionValidationError? {
        // Only need to check debits have sufficient balance
        let debitActions = body.accountActions.filter { $0.isDebit }
        guard !debitActions.isEmpty else { return nil }

        guard let snapshot = await chainState.tipSnapshot else {
            return .noStateAvailable
        }

        let state: LatticeState
        if let cached = await frontierCache?.get(frontierCID: snapshot.frontierCID) {
            state = cached
        } else {
            let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
            guard let resolved = try? await frontierHeader.resolve(fetcher: fetcher).node else {
                return .stateResolutionFailed
            }
            state = resolved
            await frontierCache?.set(frontierCID: snapshot.frontierCID, state: state)
        }

        let ownerKeys = debitActions.map { $0.owner }
        var accountPaths = [[String]: ResolutionStrategy]()
        for key in ownerKeys { accountPaths[[key]] = .targeted }
        guard let accountDict = try? await state.accountState.resolve(paths: accountPaths, fetcher: fetcher).node else {
            return .stateResolutionFailed
        }

        for action in debitActions {
            let actualBalance: UInt64 = (try? accountDict.get(key: action.owner)) ?? 0
            let debitAmount = action.absoluteAmount
            if actualBalance < debitAmount {
                return .insufficientBalance(
                    owner: action.owner,
                    balance: actualBalance,
                    required: debitAmount
                )
            }
        }

        return nil
    }

    private func validateConservation(_ body: TransactionBody) -> TransactionValidationError? {
        guard !isCoinbase else { return nil }

        if body.fee > 0 && body.accountActions.isEmpty {
            return .balanceNotConserved(totalDebits: 0, totalCredits: 0, fee: body.fee)
        }

        guard !body.accountActions.isEmpty else { return nil }

        var totalDebits: UInt64 = 0
        var totalCredits: UInt64 = 0
        for action in body.accountActions {
            if action.delta == Int64.min {
                return .balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee)
            }
            if action.delta < 0 {
                let (newDebits, dOverflow) = totalDebits.addingReportingOverflow(UInt64(-action.delta))
                if dOverflow { return .balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee) }
                totalDebits = newDebits
            } else if action.delta > 0 {
                let (newCredits, cOverflow) = totalCredits.addingReportingOverflow(UInt64(action.delta))
                if cOverflow { return .balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee) }
                totalCredits = newCredits
            }
        }
        // Conservation: debits + totalWithdrawn = credits + fee + totalDeposited
        // Deposits lock funds (outflow), withdrawals unlock funds (inflow)
        var totalDeposited: UInt64 = 0
        for deposit in body.depositActions {
            let (nd, dOverflow) = totalDeposited.addingReportingOverflow(deposit.amountDeposited)
            if dOverflow { return .balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee) }
            totalDeposited = nd
        }
        var totalWithdrawn: UInt64 = 0
        for withdrawal in body.withdrawalActions {
            let (nw, wOverflow) = totalWithdrawn.addingReportingOverflow(withdrawal.amountWithdrawn)
            if wOverflow { return .balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee) }
            totalWithdrawn = nw
        }

        let (lhs, lhsOverflow) = totalDebits.addingReportingOverflow(totalWithdrawn)
        let (creditsWithFee, feeOverflow) = totalCredits.addingReportingOverflow(body.fee)
        let (rhs, rhsOverflow) = creditsWithFee.addingReportingOverflow(totalDeposited)
        if lhsOverflow || feeOverflow || rhsOverflow || lhs != rhs {
            return .balanceNotConserved(
                totalDebits: totalDebits,
                totalCredits: totalCredits,
                fee: body.fee
            )
        }
        return nil
    }
}
