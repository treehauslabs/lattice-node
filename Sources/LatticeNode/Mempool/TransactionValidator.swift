import Lattice
import Foundation
import cashew
import UInt256

public let MINIMUM_TRANSACTION_FEE: UInt64 = 1
public let MAX_TRANSACTION_FEE: UInt64 = 1_000_000_000_000
public let MAX_NONCE_DRIFT: UInt64 = 600
public let MAX_TRANSACTION_SIZE: Int = 102_400

public enum TransactionValidationError: Error, Sendable {
    case missingBody
    case invalidSignatures
    case signerMismatch
    case duplicateAccountOwner(String)
    case balanceMismatch(owner: String, expected: UInt64, claimed: UInt64)
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
}

public struct TransactionValidator: Sendable {
    private let fetcher: Fetcher
    private let chainState: ChainState
    private let isCoinbase: Bool
    private let stateStore: StateStore?
    private let frontierCache: FrontierCache?

    public init(fetcher: Fetcher, chainState: ChainState, isCoinbase: Bool = false, stateStore: StateStore? = nil, frontierCache: FrontierCache? = nil) {
        self.fetcher = fetcher
        self.chainState = chainState
        self.isCoinbase = isCoinbase
        self.stateStore = stateStore
        self.frontierCache = frontierCache
    }

    public func validate(_ transaction: Transaction) async -> Result<Void, TransactionValidationError> {
        guard let body = transaction.body.node else {
            return .failure(.missingBody)
        }

        if let bodyData = body.toData(), bodyData.count > MAX_TRANSACTION_SIZE {
            return .failure(.transactionTooLarge(size: bodyData.count, max: MAX_TRANSACTION_SIZE))
        }

        if transaction.signatures.isEmpty {
            return .failure(.invalidSignatures)
        }
        let sigMessage = transaction.body.rawCID
        let sigs = Array(transaction.signatures)
        if sigs.count == 1 {
            if !CryptoUtils.verify(message: sigMessage, signature: sigs[0].value, publicKeyHex: sigs[0].key) {
                return .failure(.invalidSignatures)
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
            if !allValid { return .failure(.invalidSignatures) }
        }
        let signatureAddresses = Set(transaction.signatures.keys.map {
            HeaderImpl<PublicKey>(node: PublicKey(key: $0)).rawCID
        })
        for signer in body.signers {
            if !signatureAddresses.contains(signer) {
                return .failure(.signerMismatch)
            }
        }

        let signerSet = Set(body.signers)
        for action in body.accountActions where action.newBalance < action.oldBalance {
            if !signerSet.contains(action.owner) {
                return .failure(.signerMismatch)
            }
        }

        if !isCoinbase && body.fee < MINIMUM_TRANSACTION_FEE {
            return .failure(.feeTooLow(actual: body.fee, minimum: MINIMUM_TRANSACTION_FEE))
        }
        if !isCoinbase && body.fee > MAX_TRANSACTION_FEE {
            return .failure(.feeTooHigh(actual: body.fee, maximum: MAX_TRANSACTION_FEE))
        }

        if !isCoinbase {
            let sender = body.signers.first ?? ""
            let confirmedNonce = stateStore?.getNonce(address: sender) ?? 0
            if body.nonce < confirmedNonce {
                return .failure(.nonceAlreadyUsed(nonce: body.nonce))
            }
            if body.nonce > confirmedNonce + MAX_NONCE_DRIFT {
                return .failure(.nonceFromFuture(nonce: body.nonce))
            }
        }

        let signerSetForSwaps = Set(body.signers)
        for swap in body.swapActions {
            if swap.amount == 0 { return .failure(.swapSignerMismatch) }
            if !signerSetForSwaps.contains(swap.sender) { return .failure(.swapSignerMismatch) }
        }
        for claim in body.swapClaimActions {
            if claim.amount == 0 { return .failure(.swapSignerMismatch) }
            if claim.isRefund {
                if !signerSetForSwaps.contains(claim.sender) { return .failure(.swapSignerMismatch) }
            } else {
                if !signerSetForSwaps.contains(claim.recipient) { return .failure(.swapSignerMismatch) }
            }
        }
        for settle in body.settleActions {
            if !signerSetForSwaps.contains(settle.senderA) { return .failure(.swapSignerMismatch) }
            if !signerSetForSwaps.contains(settle.senderB) { return .failure(.swapSignerMismatch) }
        }

        var seenOwners = Set<String>()
        for action in body.accountActions {
            if seenOwners.contains(action.owner) {
                return .failure(.duplicateAccountOwner(action.owner))
            }
            seenOwners.insert(action.owner)
        }

        guard let snapshot = await chainState.tipSnapshot else {
            return .failure(.noStateAvailable)
        }

        let state: LatticeState
        if let cached = await frontierCache?.get(frontierCID: snapshot.frontierCID) {
            state = cached
        } else {
            let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
            guard let resolved = try? await frontierHeader.resolve(fetcher: fetcher).node else {
                return .failure(.stateResolutionFailed)
            }
            state = resolved
            await frontierCache?.set(frontierCID: snapshot.frontierCID, state: state)
        }

        let ownerKeys = body.accountActions.map { $0.owner }
        var accountPaths = [[String]: ResolutionStrategy]()
        for key in ownerKeys { accountPaths[[key]] = .targeted }
        guard let accountDict = try? await state.accountState.resolve(paths: accountPaths, fetcher: fetcher).node else {
            return .failure(.stateResolutionFailed)
        }

        for action in body.accountActions {
            let actualBalance: UInt64
            if let balance = try? accountDict.get(key: action.owner) {
                actualBalance = balance
            } else {
                actualBalance = 0
            }

            if action.oldBalance != actualBalance {
                return .failure(.balanceMismatch(
                    owner: action.owner,
                    expected: actualBalance,
                    claimed: action.oldBalance
                ))
            }

            if action.newBalance < action.oldBalance {
                let debit = action.oldBalance - action.newBalance
                let totalNeeded = debit + body.fee
                if actualBalance < totalNeeded {
                    return .failure(.insufficientBalance(
                        owner: action.owner,
                        balance: actualBalance,
                        required: totalNeeded
                    ))
                }
            }
        }

        if !isCoinbase && body.fee > 0 && body.accountActions.isEmpty {
            return .failure(.balanceNotConserved(totalDebits: 0, totalCredits: 0, fee: body.fee))
        }

        if !isCoinbase && !body.accountActions.isEmpty {
            var totalDebits: UInt64 = 0
            var totalCredits: UInt64 = 0
            for action in body.accountActions {
                if action.newBalance < action.oldBalance {
                    let (newDebits, dOverflow) = totalDebits.addingReportingOverflow(action.oldBalance - action.newBalance)
                    if dOverflow { return .failure(.balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee)) }
                    totalDebits = newDebits
                } else if action.newBalance > action.oldBalance {
                    let (newCredits, cOverflow) = totalCredits.addingReportingOverflow(action.newBalance - action.oldBalance)
                    if cOverflow { return .failure(.balanceNotConserved(totalDebits: totalDebits, totalCredits: totalCredits, fee: body.fee)) }
                    totalCredits = newCredits
                }
            }
            let (creditsWithFee, feeOverflow) = totalCredits.addingReportingOverflow(body.fee)
            if feeOverflow || totalDebits != creditsWithFee {
                return .failure(.balanceNotConserved(
                    totalDebits: totalDebits,
                    totalCredits: totalCredits,
                    fee: body.fee
                ))
            }
        }

        return .success(())
    }
}
