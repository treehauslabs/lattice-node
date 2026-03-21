import Lattice
import Foundation
import cashew
import UInt256

public enum TransactionValidationError: Error, Sendable {
    case missingBody
    case invalidSignatures
    case signerMismatch
    case duplicateAccountOwner(String)
    case balanceMismatch(owner: String, expected: UInt64, claimed: UInt64)
    case insufficientBalance(owner: String, balance: UInt64, required: UInt64)
    case noStateAvailable
    case disallowedDeposit
    case disallowedWithdrawal
    case stateResolutionFailed
}

public struct TransactionValidator: Sendable {
    private let fetcher: Fetcher
    private let chainState: ChainState

    public init(fetcher: Fetcher, chainState: ChainState) {
        self.fetcher = fetcher
        self.chainState = chainState
    }

    public func validate(_ transaction: Transaction) async -> Result<Void, TransactionValidationError> {
        guard let body = transaction.body.node else {
            return .failure(.missingBody)
        }

        if transaction.signatures.isEmpty {
            return .failure(.invalidSignatures)
        }
        for (publicKeyHex, signature) in transaction.signatures {
            if !CryptoUtils.verify(message: transaction.body.rawCID, signature: signature, publicKeyHex: publicKeyHex) {
                return .failure(.invalidSignatures)
            }
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

        if !body.depositActions.isEmpty {
            return .failure(.disallowedDeposit)
        }
        if !body.withdrawalActions.isEmpty {
            return .failure(.disallowedWithdrawal)
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

        let frontierHeader = LatticeStateHeader(rawCID: snapshot.frontierCID)
        guard let state = try? await frontierHeader.resolve(fetcher: fetcher).node else {
            return .failure(.stateResolutionFailed)
        }
        let accountHeader = state.accountState
        guard let accountDict = try? await accountHeader.resolve(fetcher: fetcher).node else {
            return .failure(.stateResolutionFailed)
        }

        for action in body.accountActions {
            let actualBalance: UInt64
            if let balanceStr = try? accountDict.get(key: action.owner) {
                actualBalance = UInt64(String(describing: balanceStr)) ?? 0
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

        return .success(())
    }
}
