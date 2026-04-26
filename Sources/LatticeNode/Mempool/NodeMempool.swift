import Lattice
import Foundation
import cashew

/// Per-trie key sets tracking which state keys a transaction touches.
/// Separate sets per state trie — no prefix disambiguation needed.
public struct StateKeySet: Sendable {
    public var accounts: Set<String> = []
    public var deposits: Set<String> = []
    public var receipts: Set<String> = []
    public var general: Set<String> = []
    public var genesis: Set<String> = []
    public var peers: Set<String> = []

    public static func from(_ body: TransactionBody) -> StateKeySet {
        var s = StateKeySet()
        for a in body.accountActions { s.accounts.insert(a.owner) }
        for a in body.depositActions { s.deposits.insert(DepositKey(depositAction: a).description) }
        for a in body.withdrawalActions { s.deposits.insert(DepositKey(withdrawalAction: a).description) }
        for a in body.receiptActions {
            s.receipts.insert(ReceiptKey(receiptAction: a).description)
        }
        for a in body.actions { s.general.insert(a.key) }
        for a in body.genesisActions { s.genesis.insert(a.directory) }
        for a in body.peerActions { s.peers.insert(a.owner) }
        return s
    }

    public func isDisjoint(with other: StateKeySet) -> Bool {
        // accounts excluded: delta model aggregates per owner, so
        // multiple transactions touching the same account are safe
        deposits.isDisjoint(with: other.deposits) &&
        receipts.isDisjoint(with: other.receipts) &&
        general.isDisjoint(with: other.general) &&
        genesis.isDisjoint(with: other.genesis) &&
        peers.isDisjoint(with: other.peers)
    }

    public mutating func formUnion(_ other: StateKeySet) {
        accounts.formUnion(other.accounts)
        deposits.formUnion(other.deposits)
        receipts.formUnion(other.receipts)
        general.formUnion(other.general)
        genesis.formUnion(other.genesis)
        peers.formUnion(other.peers)
    }
}

public struct MempoolEntry: Sendable {
    public let transaction: Transaction
    public let cid: String
    public let fee: UInt64
    public let sender: String
    public let nonce: UInt64
    public let addedAt: ContinuousClock.Instant
    public let stateKeys: StateKeySet
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
    /// CID→Data view served to MempoolAwareFetcher. Maintained incrementally
    /// on insert/remove so `fetcherCache()` is O(1); the previous build-on-call
    /// approach re-serialized every transaction and body on every miner round
    /// (P1 #6).
    private var cachedFetcherData: [String: Data] = [:]
    private let maxSize: Int
    private let maxPerAccount: Int
    /// Largest permitted distance between an admitted tx's nonce and the
    /// sender's currently-confirmed nonce. Caps how far into the future a
    /// sender can reserve slots — a sender submitting `confirmedNonce +
    /// 100_000` would otherwise squat slots that can never clear until
    /// 99_999 earlier nonces arrive.
    private let maxNonceGap: UInt64
    /// Absolute minimum fee for admission, independent of mempool fullness.
    /// Defaults to 0 to preserve existing behavior; raise to impose a spam tax.
    private let minFeeFloor: UInt64

    public init(
        maxSize: Int = 10_000,
        maxPerAccount: Int = 64,
        maxNonceGap: UInt64 = 64,
        minFeeFloor: UInt64 = 0
    ) {
        self.maxSize = maxSize
        self.maxPerAccount = maxPerAccount
        self.maxNonceGap = maxNonceGap
        self.minFeeFloor = minFeeFloor
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
        let stateKeys = StateKeySet.from(body)

        if byCID[cid] != nil {
            return .rejected(reason: "Duplicate transaction")
        }

        if fee < minFeeFloor {
            return .rejected(reason: "Fee below floor: \(fee) < \(minFeeFloor)")
        }

        let accountQueue = byAccount[sender] ?? AccountTxQueue()
        if nonce < accountQueue.confirmedNonce {
            return .rejected(reason: "Nonce already confirmed: \(nonce) < \(accountQueue.confirmedNonce)")
        }
        // Reject far-future nonces before allocating a slot. A sender at
        // confirmedNonce=5 with maxNonceGap=64 may submit nonces 5..69; a
        // submission at nonce=100_005 would pin a slot that can never clear
        // until 99_999 other txs from the same sender arrive first.
        let (gapLimit, gapOverflow) = accountQueue.confirmedNonce.addingReportingOverflow(maxNonceGap)
        if !gapOverflow && nonce > gapLimit {
            return .rejected(reason: "Nonce gap exceeds limit: \(nonce) > \(gapLimit)")
        }
        if let existing = accountQueue.txsByNonce[nonce] {
            return tryReplace(existing: existing, transaction: transaction, cid: cid, fee: fee, sender: sender, nonce: nonce, stateKeys: stateKeys)
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
            addedAt: .now,
            stateKeys: stateKeys
        )
        insertEntry(entry)
        return .added
    }

    public func selectTransactions(maxCount: Int) -> [Transaction] {
        var selected: [Transaction] = []
        var selectedNonces: [String: UInt64] = [:]
        var claimedKeys = StateKeySet()
        for entry in sortedEntries {
            if selected.count >= maxCount { break }
            guard let account = byAccount[entry.sender] else { continue }
            let nextExpected = selectedNonces[entry.sender] ?? account.confirmedNonce
            guard entry.nonce == nextExpected else { continue }
            guard claimedKeys.isDisjoint(with: entry.stateKeys) else { continue }
            selected.append(entry.transaction)
            claimedKeys.formUnion(entry.stateKeys)
            // Opportunistically include consecutive higher-nonce txs from the
            // same sender. sortedEntries is fee-descending, so a sender's
            // higher-nonce tx with a higher fee would be iterated BEFORE its
            // lower-nonce tx and skipped (nonce mismatch) — without this, it
            // would stay stuck until the next block even though it's now valid.
            var next = nextExpected + 1
            while selected.count < maxCount,
                  let nextEntry = account.txsByNonce[next],
                  claimedKeys.isDisjoint(with: nextEntry.stateKeys) {
                selected.append(nextEntry.transaction)
                claimedKeys.formUnion(nextEntry.stateKeys)
                next += 1
            }
            selectedNonces[entry.sender] = next
        }
        return selected
    }

    /// Batch update confirmed nonces for multiple senders in one actor call.
    /// Collects all stale CIDs across senders, then does a single O(n) pass
    /// over sortedEntries instead of N separate full scans.
    public func batchUpdateConfirmedNonces(updates: [(sender: String, nonce: UInt64)]) {
        var allStaleCIDs = Set<String>()
        var staleEntries: [MempoolEntry] = []
        for update in updates {
            var queue = byAccount[update.sender] ?? AccountTxQueue()
            queue.confirmedNonce = update.nonce
            let staleKeys = queue.txsByNonce.keys.filter { $0 < update.nonce }
            for n in staleKeys {
                if let entry = queue.txsByNonce.removeValue(forKey: n) {
                    byCID.removeValue(forKey: entry.cid)
                    allStaleCIDs.insert(entry.cid)
                    staleEntries.append(entry)
                }
            }
            byAccount[update.sender] = queue
        }
        if !allStaleCIDs.isEmpty {
            sortedEntries.removeAll(where: { allStaleCIDs.contains($0.cid) })
            for entry in staleEntries {
                removeFetcherEntries(for: entry)
            }
        }
    }

    public func updateConfirmedNonce(sender: String, nonce: UInt64) {
        batchUpdateConfirmedNonces(updates: [(sender: sender, nonce: nonce)])
    }

    /// Seed the mempool's confirmedNonce for a sender from persisted state if
    /// it hasn't been set this session. Without this, a sender whose most
    /// recent tx predates the current node session has confirmedNonce=0 (the
    /// default) but submits body.nonce=N>0, so selectTransactions' equality
    /// check never matches and the tx sits invisible until the expiry pruner
    /// evicts it. batchUpdateConfirmedNonces is only fired on block-apply, so
    /// it never covers the first-submit-after-restart case.
    public func seedConfirmedNonceIfUnset(sender: String, nonce: UInt64) {
        guard !sender.isEmpty, nonce > 0 else { return }
        var queue = byAccount[sender] ?? AccountTxQueue()
        guard queue.confirmedNonce == 0 else { return }
        queue.confirmedNonce = nonce
        byAccount[sender] = queue
    }

    public func remove(txCID: String) {
        guard let entry = byCID[txCID] else { return }
        removeEntry(entry)
    }

    public func removeAll(txCIDs: Set<String>) {
        for cid in txCIDs {
            guard let entry = byCID.removeValue(forKey: cid) else { continue }
            if var queue = byAccount[entry.sender] {
                queue.txsByNonce.removeValue(forKey: entry.nonce)
                if queue.txsByNonce.isEmpty && queue.confirmedNonce == 0 {
                    byAccount.removeValue(forKey: entry.sender)
                } else {
                    byAccount[entry.sender] = queue
                }
            }
            removeFetcherEntries(for: entry)
        }
        sortedEntries.removeAll(where: { txCIDs.contains($0.cid) })
    }

    public func contains(txCID: String) -> Bool {
        byCID[txCID] != nil
    }

    public func allTransactions() -> [Transaction] {
        byCID.values.map { $0.transaction }
    }

    /// CID→Data view of admitted transactions, served to MempoolAwareFetcher.
    /// Maintained incrementally by insertEntry/removeEntry; returning the
    /// stored dict is O(1) per miner round instead of O(n·serialize) on every
    /// call.
    public func fetcherCache() -> [String: Data] {
        return cachedFetcherData
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

        // sortedEntries is descending by fee — last is min, first is max
        let maxFee = sortedEntries.first!.fee
        let minFee = sortedEntries.last!.fee

        if minFee == maxFee {
            return [(minFee: minFee, maxFee: maxFee, count: sortedEntries.count)]
        }

        let range = maxFee - minFee
        let bucketSize = max(range / UInt64(bucketCount), 1)
        var buckets: [(minFee: UInt64, maxFee: UInt64, count: Int)] = []

        for i in 0..<bucketCount {
            let lo = minFee + UInt64(i) * bucketSize
            let hi = (i == bucketCount - 1) ? maxFee : lo + bucketSize - 1
            // Binary search in descending array: count entries with fee in [lo, hi]
            let hiIdx = sortedEntries.binarySearchDescending { $0.fee > hi }
            let loIdx = sortedEntries.binarySearchDescending { $0.fee >= lo }
            let c = loIdx - hiIdx
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
        nonce: UInt64,
        stateKeys: StateKeySet
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
            addedAt: .now,
            stateKeys: stateKeys
        )
        insertEntry(entry)
        return .replacedExisting(oldCID: oldCID)
    }

    private func insertEntry(_ entry: MempoolEntry) {
        byCID[entry.cid] = entry
        byAccount[entry.sender, default: AccountTxQueue()].txsByNonce[entry.nonce] = entry

        // Binary search for insertion point in descending-fee array: O(log n)
        let insertIndex = sortedEntries.binarySearchDescending { $0.fee >= entry.fee }
        sortedEntries.insert(entry, at: insertIndex)

        addFetcherEntries(for: entry)
    }

    private func removeEntry(_ entry: MempoolEntry) {
        byCID.removeValue(forKey: entry.cid)

        if var queue = byAccount[entry.sender] {
            queue.txsByNonce.removeValue(forKey: entry.nonce)
            if queue.txsByNonce.isEmpty && queue.confirmedNonce == 0 {
                byAccount.removeValue(forKey: entry.sender)
            } else {
                byAccount[entry.sender] = queue
            }
        }

        // Binary search to fee range, then linear scan within that range
        let feeIdx = sortedEntries.binarySearchDescending { $0.fee > entry.fee }
        for i in feeIdx..<sortedEntries.count {
            if sortedEntries[i].fee < entry.fee { break }
            if sortedEntries[i].cid == entry.cid {
                sortedEntries.remove(at: i)
                break
            }
        }

        removeFetcherEntries(for: entry)
    }

    private func addFetcherEntries(for entry: MempoolEntry) {
        let tx = entry.transaction
        if let data = tx.toData() {
            cachedFetcherData[VolumeImpl<Transaction>(node: tx).rawCID] = data
        }
        if let bodyNode = tx.body.node, let bodyData = bodyNode.toData() {
            cachedFetcherData[tx.body.rawCID] = bodyData
        }
    }

    private func removeFetcherEntries(for entry: MempoolEntry) {
        let tx = entry.transaction
        cachedFetcherData.removeValue(forKey: VolumeImpl<Transaction>(node: tx).rawCID)
        if tx.body.node != nil {
            cachedFetcherData.removeValue(forKey: tx.body.rawCID)
        }
    }

}

extension Array {
    /// Binary search on a descending-sorted array.
    /// Returns the index of the first element where `predicate` returns false.
    func binarySearchDescending(predicate: (Element) -> Bool) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(self[mid]) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

extension Array where Element: Comparable {
    /// Binary search on an ascending-sorted array.
    /// Returns the insertion index for `value` (first position where element >= value).
    func ascendingInsertionIndex(for value: Element) -> Int {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if self[mid] < value {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
