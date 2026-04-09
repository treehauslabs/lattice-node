import Lattice
import Foundation

public struct MempoolEntry: Sendable {
    public let transaction: Transaction
    public let cid: String
    public let fee: UInt64
    public let sender: String
    public let nonce: UInt64
    public let addedAt: ContinuousClock.Instant
}

public struct AccountTxQueue: Sendable {
    public var txsByNonce: [UInt64: MempoolEntry] = [:]
    public var confirmedNonce: UInt64 = 0
}

public enum AddResult: Sendable {
    case added
    case replacedExisting(oldCID: String)
    case rejected(reason: String)
}

public actor NodeMempool {
    private var byCID: [String: MempoolEntry] = [:]
    private var byAccount: [String: AccountTxQueue] = [:]
    private var sortedEntries: [MempoolEntry] = []
    private let maxSize: Int
    private let maxPerAccount: Int

    public init(maxSize: Int = 10_000, maxPerAccount: Int = 64) {
        self.maxSize = maxSize
        self.maxPerAccount = maxPerAccount
    }

    public var count: Int { byCID.count }

    public func add(transaction: Transaction) -> Bool {
        switch addTransaction(transaction) {
        case .added, .replacedExisting:
            return true
        case .rejected:
            return false
        }
    }

    public func addTransaction(_ transaction: Transaction) -> AddResult {
        guard let body = transaction.body.node else {
            return .rejected(reason: "Missing transaction body")
        }

        let cid = transaction.body.rawCID
        let fee = body.fee
        let sender = body.signers.first ?? ""
        let nonce = body.nonce

        if byCID[cid] != nil {
            return .rejected(reason: "Duplicate transaction")
        }

        let accountQueue = byAccount[sender] ?? AccountTxQueue()
        if let existing = accountQueue.txsByNonce[nonce] {
            return tryReplace(existing: existing, transaction: transaction, cid: cid, fee: fee, sender: sender, nonce: nonce)
        }

        if accountQueue.txsByNonce.count >= maxPerAccount {
            return .rejected(reason: "Account transaction limit reached")
        }

        if byCID.count >= maxSize {
            guard let lowest = sortedEntries.last else {
                return .rejected(reason: "Mempool full")
            }
            if fee <= lowest.fee {
                return .rejected(reason: "Fee too low to enter mempool")
            }
            removeEntry(lowest)
        }

        let entry = MempoolEntry(
            transaction: transaction,
            cid: cid,
            fee: fee,
            sender: sender,
            nonce: nonce,
            addedAt: .now
        )
        insertEntry(entry)
        return .added
    }

    public func selectTransactions(maxCount: Int) -> [Transaction] {
        var selected: [Transaction] = []
        var selectedNonces: [String: UInt64] = [:]
        for entry in sortedEntries {
            if selected.count >= maxCount { break }
            let account = byAccount[entry.sender]
            let confirmedNonce = account?.confirmedNonce ?? 0
            let nextExpected = selectedNonces[entry.sender] ?? confirmedNonce
            if entry.nonce == nextExpected {
                selected.append(entry.transaction)
                selectedNonces[entry.sender] = nextExpected + 1
            }
        }
        return selected
    }

    /// Batch update confirmed nonces for multiple senders in one actor call.
    /// Avoids N individual actor hops from the block processing loop.
    public func batchUpdateConfirmedNonces(updates: [(sender: String, nonce: UInt64)]) {
        for update in updates {
            updateConfirmedNonce(sender: update.sender, nonce: update.nonce)
        }
    }

    public func updateConfirmedNonce(sender: String, nonce: UInt64) {
        byAccount[sender, default: AccountTxQueue()].confirmedNonce = nonce
        let confirmed = nonce
        if var queue = byAccount[sender] {
            let stale = queue.txsByNonce.filter { $0.key < confirmed }
            var staleCIDs = Set<String>()
            for (n, entry) in stale {
                byCID.removeValue(forKey: entry.cid)
                staleCIDs.insert(entry.cid)
                queue.txsByNonce.removeValue(forKey: n)
            }
            if !staleCIDs.isEmpty {
                sortedEntries.removeAll(where: { staleCIDs.contains($0.cid) })
            }
            byAccount[sender] = queue
        }
    }

    public func remove(txCID: String) {
        guard let entry = byCID[txCID] else { return }
        removeEntry(entry)
    }

    public func removeAll(txCIDs: Set<String>) {
        for cid in txCIDs {
            guard let entry = byCID.removeValue(forKey: cid) else { continue }
            if var accountQueue = byAccount[entry.sender] {
                accountQueue.txsByNonce.removeValue(forKey: entry.nonce)
                if accountQueue.txsByNonce.isEmpty && accountQueue.confirmedNonce == 0 {
                    byAccount.removeValue(forKey: entry.sender)
                } else {
                    byAccount[entry.sender] = accountQueue
                }
            }
        }
        sortedEntries.removeAll(where: { txCIDs.contains($0.cid) })
    }

    public func contains(txCID: String) -> Bool {
        byCID[txCID] != nil
    }

    public func allTransactions() -> [Transaction] {
        byCID.values.map { $0.transaction }
    }

    public func totalFees() -> UInt64 {
        byCID.values.reduce(0) { $0 + $1.fee }
    }

    public func pruneExpired(olderThan age: Duration) {
        let cutoff = ContinuousClock.Instant.now - age
        let expired = byCID.values.filter { $0.addedAt < cutoff }
        for entry in expired {
            removeEntry(entry)
        }
    }

    public func feeHistogram(bucketCount: Int = 10) -> [(minFee: UInt64, maxFee: UInt64, count: Int)] {
        guard !sortedEntries.isEmpty else { return [] }

        let fees = sortedEntries.map { $0.fee }.sorted()
        let minFee = fees.first!
        let maxFee = fees.last!

        if minFee == maxFee {
            return [(minFee: minFee, maxFee: maxFee, count: fees.count)]
        }

        let range = maxFee - minFee
        let bucketSize = max(range / UInt64(bucketCount), 1)
        var buckets: [(minFee: UInt64, maxFee: UInt64, count: Int)] = []

        for i in 0..<bucketCount {
            let lo = minFee + UInt64(i) * bucketSize
            let hi = (i == bucketCount - 1) ? maxFee : lo + bucketSize - 1
            let c = fees.filter { $0 >= lo && $0 <= hi }.count
            if c > 0 {
                buckets.append((minFee: lo, maxFee: hi, count: c))
            }
        }

        return buckets
    }

    // MARK: - Private

    private func tryReplace(
        existing: MempoolEntry,
        transaction: Transaction,
        cid: String,
        fee: UInt64,
        sender: String,
        nonce: UInt64
    ) -> AddResult {
        let bump = existing.fee / 10 + 1
        let (requiredFee, overflow) = existing.fee.addingReportingOverflow(bump)
        if overflow { return .rejected(reason: "RBF fee calculation overflow") }
        guard fee >= requiredFee else {
            return .rejected(reason: "RBF fee too low: need at least \(requiredFee), got \(fee)")
        }

        let oldCID = existing.cid
        removeEntry(existing)

        let entry = MempoolEntry(
            transaction: transaction,
            cid: cid,
            fee: fee,
            sender: sender,
            nonce: nonce,
            addedAt: .now
        )
        insertEntry(entry)
        return .replacedExisting(oldCID: oldCID)
    }

    private func insertEntry(_ entry: MempoolEntry) {
        byCID[entry.cid] = entry
        byAccount[entry.sender, default: AccountTxQueue()].txsByNonce[entry.nonce] = entry

        let insertIndex = sortedEntries.firstIndex { $0.fee < entry.fee } ?? sortedEntries.endIndex
        sortedEntries.insert(entry, at: insertIndex)
    }

    private func removeEntry(_ entry: MempoolEntry) {
        byCID.removeValue(forKey: entry.cid)

        if var accountQueue = byAccount[entry.sender] {
            accountQueue.txsByNonce.removeValue(forKey: entry.nonce)
            if accountQueue.txsByNonce.isEmpty && accountQueue.confirmedNonce == 0 {
                byAccount.removeValue(forKey: entry.sender)
            } else {
                byAccount[entry.sender] = accountQueue
            }
        }

        if let idx = sortedEntries.firstIndex(where: { $0.cid == entry.cid }) {
            sortedEntries.remove(at: idx)
        }
    }

}
