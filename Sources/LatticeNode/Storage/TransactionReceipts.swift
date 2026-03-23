import Foundation

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

    public init(store: StateStore) {
        self.store = store
    }

    public func saveReceipt(_ receipt: TransactionReceipt) async {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        await store.setGeneral(key: "receipt:\(receipt.txCID)", value: data, atHeight: receipt.blockHeight)
    }

    public func getReceipt(txCID: String) async -> TransactionReceipt? {
        guard let data = await store.getGeneral(key: "receipt:\(txCID)") else { return nil }
        return try? JSONDecoder().decode(TransactionReceipt.self, from: data)
    }

    public func saveReceipts(from block: BlockReceiptData) async {
        for receipt in block.receipts {
            await saveReceipt(receipt)
        }
    }
}

public struct BlockReceiptData: Sendable {
    public let blockHash: String
    public let blockHeight: UInt64
    public let timestamp: Int64
    public let receipts: [TransactionReceipt]
}
