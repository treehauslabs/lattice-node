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

    public func indexReceipt(txCID: String, blockHash: String, blockHeight: UInt64) async {
        guard let data = try? JSONEncoder().encode(ReceiptIndex(blockHash: blockHash, blockHeight: blockHeight)) else { return }
        await store.setGeneral(key: "receipt-idx:\(txCID)", value: data, atHeight: blockHeight)
    }

    public func getReceipt(txCID: String) async -> TransactionReceipt? {
        guard let indexData = await store.getGeneral(key: "receipt-idx:\(txCID)"),
              let index = try? JSONDecoder().decode(ReceiptIndex.self, from: indexData) else { return nil }

        guard let blockData = try? await fetcher.fetch(rawCid: index.blockHash),
              let block = Block(data: blockData),
              let txDict = try? await block.transactions.resolveRecursive(fetcher: fetcher).node,
              let txEntries = try? txDict.allKeysAndValues() else { return nil }

        for (cid, txHeader) in txEntries {
            guard cid == txCID, let tx = txHeader.node, let body = tx.body.node else { continue }
            let actions = body.accountActions.map {
                TransactionReceipt.ReceiptAction(owner: $0.owner, oldBalance: $0.oldBalance, newBalance: $0.newBalance)
            }
            return TransactionReceipt(
                txCID: cid, blockHash: index.blockHash, blockHeight: index.blockHeight,
                timestamp: block.timestamp, fee: body.fee,
                sender: body.signers.first ?? "", status: "confirmed",
                accountActions: actions
            )
        }
        return nil
    }
}

private struct ReceiptIndex: Codable {
    let blockHash: String
    let blockHeight: UInt64
}
