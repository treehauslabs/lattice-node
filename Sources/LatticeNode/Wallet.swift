import Lattice
import Foundation
import Crypto
import cashew

public struct Wallet: Sendable {
    public let privateKeyHex: String
    public let publicKeyHex: String
    public let address: String

    public init(privateKeyHex: String, publicKeyHex: String) {
        self.privateKeyHex = privateKeyHex
        self.publicKeyHex = publicKeyHex
        self.address = HeaderImpl<PublicKey>(node: PublicKey(key: publicKeyHex)).rawCID
    }

    public static func create() -> Wallet {
        let keys = CryptoUtils.generateKeyPair()
        return Wallet(privateKeyHex: keys.privateKey, publicKeyHex: keys.publicKey)
    }

    public static func fromPrivateKey(_ hex: String) -> Wallet? {
        guard let data = Data(hex: hex),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        let pubHex = key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        return Wallet(privateKeyHex: hex, publicKeyHex: pubHex)
    }

    public func sign(message: String) -> String? {
        CryptoUtils.sign(message: message, privateKeyHex: privateKeyHex)
    }

    public func buildTransfer(
        to recipient: String,
        amount: UInt64,
        senderOldBalance: UInt64,
        recipientOldBalance: UInt64,
        fee: UInt64 = 0,
        nonce: UInt64 = 0
    ) -> Transaction? {
        guard senderOldBalance >= amount + fee else { return nil }

        let senderAction = AccountAction(
            owner: address,
            oldBalance: senderOldBalance,
            newBalance: senderOldBalance - amount - fee
        )
        let recipientAction = AccountAction(
            owner: recipient,
            oldBalance: recipientOldBalance,
            newBalance: recipientOldBalance + amount
        )

        let body = TransactionBody(
            accountActions: [senderAction, recipientAction],
            actions: [],
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: fee,
            nonce: nonce
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = sign(message: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [publicKeyHex: signature],
            body: bodyHeader
        )
    }

    public func buildActionTransaction(
        actions: [Action],
        fee: UInt64 = 0,
        senderOldBalance: UInt64 = 0,
        nonce: UInt64 = 0
    ) -> Transaction? {
        var accountActions: [AccountAction] = []
        if fee > 0 {
            guard senderOldBalance >= fee else { return nil }
            accountActions.append(AccountAction(
                owner: address,
                oldBalance: senderOldBalance,
                newBalance: senderOldBalance - fee
            ))
        }

        let body = TransactionBody(
            accountActions: accountActions,
            actions: actions,
            depositActions: [],
            genesisActions: [],
            peerActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: fee,
            nonce: nonce
        )

        let bodyHeader = HeaderImpl<TransactionBody>(node: body)
        guard let signature = sign(message: bodyHeader.rawCID) else { return nil }

        return Transaction(
            signatures: [publicKeyHex: signature],
            body: bodyHeader
        )
    }
}
