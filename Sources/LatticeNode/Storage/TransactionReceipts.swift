import Foundation
import Lattice
import cashew

public struct TransactionReceipt: Codable, Sendable {
    public let txCID: String
    public let blockHash: String
    public let blockHeight: UInt64
    public let timestamp: Int64
    public let fee: UInt64
    public let sender: String
    public let status: String
    public let accountActions: [ReceiptAction]

    public struct ReceiptAction: Codable, Sendable {
        public let owner: String
        public let oldBalance: UInt64
        public let newBalance: UInt64
    }
}

public actor TransactionReceiptStore {
    private let store: StateStore
    private let fetcher: Fetcher

    public init(store: StateStore, fetcher: Fetcher) {
        self.store = store
        self.fetcher = fetcher
    }

    public func saveReceipt(_ receipt: TransactionReceipt) async {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        await store.setGeneral(key: "receipt:\(receipt.txCID)", value: data, atHeight: receipt.blockHeight)
    }

    public func getReceipt(txCID: String) async -> TransactionReceipt? {
        if let data = store.getGeneral(key: "receipt:\(txCID)"),
           let receipt = try? JSONDecoder().decode(TransactionReceipt.self, from: data) {
            return receipt
        }

        guard let indexData = store.getGeneral(key: "receipt-idx:\(txCID)"),
              let index = try? JSONDecoder().decode(ReceiptIndex.self, from: indexData) else { return nil }

        return await deriveFromCAS(txCID: txCID, index: index)
    }

    public func indexReceipt(txCID: String, blockHash: String, blockHeight: UInt64) async {
        guard let data = try? JSONEncoder().encode(ReceiptIndex(blockHash: blockHash, blockHeight: blockHeight)) else { return }
        await store.setGeneral(key: "receipt-idx:\(txCID)", value: data, atHeight: blockHeight)
    }

    private func deriveFromCAS(txCID: String, index: ReceiptIndex) async -> TransactionReceipt? {
        guard let blockData = try? await fetcher.fetch(rawCid: index.blockHash),
              let block = Block(data: blockData) else { return nil }

        // Targeted resolve: load only the radix path to this one transaction
        guard let txDict = try? await block.transactions.resolve(
            paths: [[txCID]: .targeted], fetcher: fetcher
        ).node else { return nil }

        guard let txHeader: HeaderImpl<Transaction> = try? txDict.get(key: txCID) else { return nil }

        // The transaction value may need resolution after targeted dict resolve
        let tx: Transaction
        if let n = txHeader.node {
            tx = n
        } else {
            guard let resolved = try? await txHeader.resolve(fetcher: fetcher).node else { return nil }
            tx = resolved
        }

        let body: TransactionBody
        if let n = tx.body.node {
            body = n
        } else if let resolved = try? await tx.body.resolve(fetcher: fetcher).node {
            body = resolved
        } else {
            return nil
        }

        let actions = body.accountActions.map {
            TransactionReceipt.ReceiptAction(owner: $0.owner, oldBalance: $0.oldBalance, newBalance: $0.newBalance)
        }
        return TransactionReceipt(
            txCID: txCID, blockHash: index.blockHash, blockHeight: index.blockHeight,
            timestamp: block.timestamp, fee: body.fee,
            sender: body.signers.first ?? "", status: "confirmed",
            accountActions: actions
        )
    }
}

private struct ReceiptIndex: Codable {
    let blockHash: String
    let blockHeight: UInt64
}
