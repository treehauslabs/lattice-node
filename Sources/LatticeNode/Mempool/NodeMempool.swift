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
        return s
    }

    public func isDisjoint(with other: StateKeySet) -> Bool {
        // accounts excluded: delta model aggregates per owner, so
        // multiple transactions touching the same account are safe
        deposits.isDisjoint(with: other.deposits) &&
        receipts.isDisjoint(with: other.receipts) &&
        general.isDisjoint(with: other.general) &&
        genesis.isDisjoint(with: other.genesis)
    }

    public mutating func formUnion(_ other: StateKeySet) {
        accounts.formUnion(other.accounts)
        deposits.formUnion(other.deposits)
        receipts.formUnion(other.receipts)
        general.formUnion(other.general)
        genesis.formUnion(other.genesis)
    }
}

/// Whether an entry is selectable now (`valid`) or held back waiting on
/// cross-chain receipt arrival (`pending`). Pending entries claim their
/// nonce slot in `byAccount.txsByNonce` so a same-sender higher-nonce tx
/// can't squeak past, but stay out of `sortedEntries` so they're never
/// picked by `selectTransactions` (neither as leader nor as nonce
/// continuation).
public enum MempoolValidity: Sendable, Equatable {
    case valid
    case pending
}

public struct MempoolEntry: Sendable {
    public let transaction: Transaction
    public let cid: String
    public let fee: UInt64
    public let sender: String
    public let nonce: UInt64
    public let addedAt: ContinuousClock.Instant
    public let stateKeys: StateKeySet
    public var validity: MempoolValidity
    /// Parent-chain receipt requirements this entry needs satisfied. Empty
    /// for valid entries (none outstanding) and for non-withdrawal entries.
    /// Stored on the entry so recheck has full (key, expectedWithdrawer)
    /// pairs without needing to re-derive them from the tx body.
    public let receiptRequirements: Set<ReceiptRequirement>

    public init(
        transaction: Transaction,
        cid: String,
        fee: UInt64,
        sender: String,
        nonce: UInt64,
        addedAt: ContinuousClock.Instant,
        stateKeys: StateKeySet,
        validity: MempoolValidity = .valid,
        receiptRequirements: Set<ReceiptRequirement> = []
    ) {
        self.transaction = transaction
        self.cid = cid
        self.fee = fee
        self.sender = sender
        self.nonce = nonce
        self.addedAt = addedAt
        self.stateKeys = stateKeys
        self.validity = validity
        self.receiptRequirements = receiptRequirements
    }
}

public struct AccountTxQueue: Sendable {
    public var txsByNonce: [UInt64: MempoolEntry] = [:]
    public var confirmedNonce: UInt64 = 0
}

public enum AddResult: Sendable {
    case added
    case addedPending
    case replacedExisting(oldCID: String)
    case rejected(reason: String)
}

/// One (receiptKey, expectedWithdrawer) pair a tx needs to satisfy before
/// it can be selected. A withdrawal-bearing tx with N withdrawals has N
/// requirements; all must hold for the tx to be valid. Stored on the
/// entry so recheck can compare stored-on-chain withdrawer vs claimed
/// without re-deriving keys per action.
public struct ReceiptRequirement: Sendable, Hashable {
    public let receiptKey: String
    public let expectedWithdrawer: String

    public init(receiptKey: String, expectedWithdrawer: String) {
        self.receiptKey = receiptKey
        self.expectedWithdrawer = expectedWithdrawer
    }
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

    /// Independent ceilings for the pending pool so a flood of
    /// receipt-blocked withdrawals can't squeeze valid txs out. Pending
    /// entries are admission-checked against this chain's depositState
    /// so each one is backed by a real local deposit (which costs funds
    /// to create); these caps are belt-and-suspenders for the legitimate-
    /// but-receipt-never-arrives case.
    private let maxPendingSize: Int
    private let maxPendingPerAccount: Int
    /// Reverse index: receiptKey → CIDs of pending entries waiting on it.
    /// Lets the chain-accept hook walk only affected pending entries
    /// instead of scanning every pending entry per accepted block.
    private var pendingByReceiptKey: [String: Set<String>] = [:]
    private var pendingCount: Int = 0
    private var pendingPerAccount: [String: Int] = [:]

    public init(
        maxSize: Int = 10_000,
        maxPerAccount: Int = 64,
        maxNonceGap: UInt64 = 64,
        minFeeFloor: UInt64 = 0,
        maxPendingSize: Int = 1_000,
        maxPendingPerAccount: Int = 8
    ) {
        self.maxSize = maxSize
        self.maxPerAccount = maxPerAccount
        self.maxNonceGap = maxNonceGap
        self.minFeeFloor = minFeeFloor
        self.maxPendingSize = maxPendingSize
        self.maxPendingPerAccount = maxPendingPerAccount
    }

    public var count: Int { byCID.count }

    public func add(transaction: Transaction) -> Bool {
        switch addTransaction(transaction) {
        case .added, .replacedExisting:
            return true
        case .addedPending:
            // addTransaction never returns .addedPending; only addPendingTransaction does.
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

    /// Admit a withdrawal-bearing tx whose required parent-chain receipts
    /// haven't all arrived yet. Same admission gates as `addTransaction`
    /// (dup, fee floor, nonce gap, RBF replace) but the entry stays out
    /// of `sortedEntries` so it can't be selected, and counts against
    /// independent pending caps.
    ///
    /// The caller (LatticeNode admission helper) is responsible for
    /// running this chain's local depositState hard checks before calling
    /// — those failures are permanent and shouldn't enter pending. The
    /// caller is also responsible for resolving the parent chain's
    /// receiptState to determine which receipt keys are missing; the
    /// mempool just trusts the supplied requirements.
    public func addPendingTransaction(
        _ transaction: Transaction,
        receiptRequirements: Set<ReceiptRequirement>
    ) -> AddResult {
        guard let body = transaction.body.node else {
            return .rejected(reason: "Missing transaction body")
        }
        guard !receiptRequirements.isEmpty else {
            return .rejected(reason: "addPending called with no receipt requirements")
        }

        let cid = transaction.body.rawCID
        let fee = body.fee
        let sender = body.signers.first ?? ""
        let nonce = body.nonce
        let stateKeys = StateKeySet.from(body)

        if byCID[cid] != nil { return .rejected(reason: "Duplicate transaction") }
        if fee < minFeeFloor {
            return .rejected(reason: "Fee below floor: \(fee) < \(minFeeFloor)")
        }

        let accountQueue = byAccount[sender] ?? AccountTxQueue()
        if nonce < accountQueue.confirmedNonce {
            return .rejected(reason: "Nonce already confirmed: \(nonce) < \(accountQueue.confirmedNonce)")
        }
        let (gapLimit, gapOverflow) = accountQueue.confirmedNonce.addingReportingOverflow(maxNonceGap)
        if !gapOverflow && nonce > gapLimit {
            return .rejected(reason: "Nonce gap exceeds limit: \(nonce) > \(gapLimit)")
        }
        if let existing = accountQueue.txsByNonce[nonce] {
            return tryReplace(
                existing: existing,
                transaction: transaction,
                cid: cid,
                fee: fee,
                sender: sender,
                nonce: nonce,
                stateKeys: stateKeys,
                validity: .pending,
                receiptRequirements: receiptRequirements
            )
        }
        if accountQueue.txsByNonce.count >= maxPerAccount {
            return .rejected(reason: "Account transaction limit reached")
        }
        if (pendingPerAccount[sender] ?? 0) >= maxPendingPerAccount {
            return .rejected(reason: "Pending per-account limit reached")
        }
        if pendingCount >= maxPendingSize {
            return .rejected(reason: "Pending mempool full")
        }

        let entry = MempoolEntry(
            transaction: transaction,
            cid: cid,
            fee: fee,
            sender: sender,
            nonce: nonce,
            addedAt: .now,
            stateKeys: stateKeys,
            validity: .pending,
            receiptRequirements: receiptRequirements
        )
        insertEntry(entry)
        return .addedPending
    }

    /// Re-evaluate pending entries after a parent chain accepts a block
    /// that adds receipts (or after a reorg that may both add and remove
    /// receipts on the parent chain).
    ///
    /// `probe(receiptKey)` returns:
    ///   - nil: receipt absent in the parent's new state
    ///   - non-nil: receipt present, value = stored withdrawer
    ///
    /// For each affected pending entry the mempool aggregates per-requirement
    /// status and transitions:
    ///   - all stored == expected → promote to valid
    ///   - any stored != expected → permanent eviction (wrong-owner)
    ///   - any absent (no mismatch) → leave pending
    ///
    /// The caller picks `affectedReceiptKeys`. For a forward accept, that's
    /// the set of receipt keys the new block adds — fast path. For a reorg,
    /// pass the union of `pendingByReceiptKey.keys` snapshot (call
    /// `pendingReceiptKeys()`) so every pending entry is re-probed against
    /// the new tip.
    public func recheckPending(
        affectedReceiptKeys: Set<String>,
        probe: (_ receiptKey: String) async -> String?
    ) async -> (promoted: Set<String>, evicted: Set<String>) {
        var affectedCIDs = Set<String>()
        for key in affectedReceiptKeys {
            if let cids = pendingByReceiptKey[key] { affectedCIDs.formUnion(cids) }
        }
        if affectedCIDs.isEmpty { return ([], []) }

        var promoted = Set<String>()
        var evicted = Set<String>()
        for cid in affectedCIDs {
            guard let entry = byCID[cid], entry.validity == .pending else { continue }
            let outcome = await evaluateRequirements(entry.receiptRequirements, probe: probe)
            switch outcome {
            case .allSatisfied:
                guard let stillThere = byCID[cid], stillThere.validity == .pending else { continue }
                removeEntry(stillThere)
                insertEntry(MempoolEntry(
                    transaction: stillThere.transaction,
                    cid: stillThere.cid,
                    fee: stillThere.fee,
                    sender: stillThere.sender,
                    nonce: stillThere.nonce,
                    addedAt: stillThere.addedAt,
                    stateKeys: stillThere.stateKeys,
                    validity: .valid,
                    receiptRequirements: []
                ))
                promoted.insert(cid)
            case .mismatch:
                if let stillThere = byCID[cid] { removeEntry(stillThere) }
                evicted.insert(cid)
            case .stillWaiting:
                continue
            }
        }
        return (promoted, evicted)
    }

    /// Demote valid withdrawal-bearing entries whose receipt is no longer
    /// canonical after a reorg. Caller supplies (cid → receiptRequirements)
    /// reconstructed from the entries' withdrawal actions + this chain's
    /// directory. Symmetric to `recheckPending`.
    public func demoteValidWithdrawals(
        candidates: [(cid: String, requirements: Set<ReceiptRequirement>)],
        probe: (_ receiptKey: String) async -> String?
    ) async -> (demoted: Set<String>, evicted: Set<String>) {
        var demoted = Set<String>()
        var evicted = Set<String>()
        for cand in candidates {
            guard let entry = byCID[cand.cid], entry.validity == .valid else { continue }
            let outcome = await evaluateRequirements(cand.requirements, probe: probe)
            switch outcome {
            case .allSatisfied:
                continue
            case .mismatch:
                if let stillThere = byCID[cand.cid] { removeEntry(stillThere) }
                evicted.insert(cand.cid)
            case .stillWaiting:
                guard let stillThere = byCID[cand.cid], stillThere.validity == .valid else { continue }
                removeEntry(stillThere)
                insertEntry(MempoolEntry(
                    transaction: stillThere.transaction,
                    cid: stillThere.cid,
                    fee: stillThere.fee,
                    sender: stillThere.sender,
                    nonce: stillThere.nonce,
                    addedAt: stillThere.addedAt,
                    stateKeys: stillThere.stateKeys,
                    validity: .pending,
                    receiptRequirements: cand.requirements
                ))
                demoted.insert(cand.cid)
            }
        }
        return (demoted, evicted)
    }

    /// Snapshot of all receipt keys any pending entry is currently waiting
    /// on. Used by callers driving a reorg-time recheck so they can
    /// re-probe the new tip even for receipts not in the new block's adds.
    public func pendingReceiptKeys() -> Set<String> {
        Set(pendingByReceiptKey.keys)
    }

    /// Snapshot of valid withdrawal-bearing entries — used by the
    /// reorg-demotion driver, which re-derives receipt keys for these
    /// (it has the chain directory) and feeds them to `demoteValidWithdrawals`.
    public func validWithdrawalEntries() -> [(cid: String, body: TransactionBody)] {
        var out: [(String, TransactionBody)] = []
        for entry in sortedEntries {
            guard let body = entry.transaction.body.node else { continue }
            if !body.withdrawalActions.isEmpty {
                out.append((entry.cid, body))
            }
        }
        return out
    }

    /// Evict any mempool entry whose deposit-key set intersects `consumed`.
    /// Called after the local chain accepts a block whose withdrawal txs
    /// drained those deposits. The same deposit can't be withdrawn twice,
    /// so any other mempool entry referencing one of these deposits is
    /// permanently invalid. Catches cross-pool conflicts where a pending
    /// entry holds a deposit consumed by a different valid withdrawal that
    /// won inclusion.
    public func evictByDepositKeys(_ consumed: Set<String>) -> Set<String> {
        guard !consumed.isEmpty else { return [] }
        var toRemove: [MempoolEntry] = []
        for entry in byCID.values where !entry.stateKeys.deposits.isDisjoint(with: consumed) {
            toRemove.append(entry)
        }
        for entry in toRemove { removeEntry(entry) }
        return Set(toRemove.map { $0.cid })
    }

    private enum RequirementOutcome { case allSatisfied, mismatch, stillWaiting }

    private func evaluateRequirements(
        _ requirements: Set<ReceiptRequirement>,
        probe: (_ receiptKey: String) async -> String?
    ) async -> RequirementOutcome {
        var anyAbsent = false
        for req in requirements {
            let stored = await probe(req.receiptKey)
            guard let stored else { anyAbsent = true; continue }
            if stored != req.expectedWithdrawer { return .mismatch }
        }
        return anyAbsent ? .stillWaiting : .allSatisfied
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
                  // Pending entries claim their nonce slot but cannot be
                  // selected; encountering one halts the continuation so
                  // we don't emit a nonce gap into the block.
                  nextEntry.validity == .valid,
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
        // Collect stale entries first so confirmedNonce updates and entry
        // removals are batched (single sortedEntries pass; pending indexes
        // updated via removeEntry).
        var staleEntries: [MempoolEntry] = []
        for update in updates {
            var queue = byAccount[update.sender] ?? AccountTxQueue()
            queue.confirmedNonce = update.nonce
            for (n, entry) in queue.txsByNonce where n < update.nonce {
                staleEntries.append(entry)
            }
            byAccount[update.sender] = queue
        }
        guard !staleEntries.isEmpty else { return }
        let staleValidCIDs: Set<String> = Set(staleEntries.compactMap { $0.validity == .valid ? $0.cid : nil })
        for entry in staleEntries {
            byCID.removeValue(forKey: entry.cid)
            if var queue = byAccount[entry.sender] {
                queue.txsByNonce.removeValue(forKey: entry.nonce)
                byAccount[entry.sender] = queue
            }
            // Update pending bookkeeping for stale pending entries; valid
            // entries handled below in the single sortedEntries sweep.
            if entry.validity == .pending {
                pendingCount = max(0, pendingCount - 1)
                if let n = pendingPerAccount[entry.sender] {
                    if n <= 1 { pendingPerAccount.removeValue(forKey: entry.sender) }
                    else { pendingPerAccount[entry.sender] = n - 1 }
                }
                for req in entry.receiptRequirements {
                    if var cids = pendingByReceiptKey[req.receiptKey] {
                        cids.remove(entry.cid)
                        if cids.isEmpty { pendingByReceiptKey.removeValue(forKey: req.receiptKey) }
                        else { pendingByReceiptKey[req.receiptKey] = cids }
                    }
                }
            }
            removeFetcherEntries(for: entry)
        }
        if !staleValidCIDs.isEmpty {
            sortedEntries.removeAll(where: { staleValidCIDs.contains($0.cid) })
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
        var validCIDsToDrop = Set<String>()
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
            switch entry.validity {
            case .valid:
                validCIDsToDrop.insert(entry.cid)
            case .pending:
                pendingCount = max(0, pendingCount - 1)
                if let n = pendingPerAccount[entry.sender] {
                    if n <= 1 { pendingPerAccount.removeValue(forKey: entry.sender) }
                    else { pendingPerAccount[entry.sender] = n - 1 }
                }
                for req in entry.receiptRequirements {
                    if var cids = pendingByReceiptKey[req.receiptKey] {
                        cids.remove(entry.cid)
                        if cids.isEmpty { pendingByReceiptKey.removeValue(forKey: req.receiptKey) }
                        else { pendingByReceiptKey[req.receiptKey] = cids }
                    }
                }
            }
            removeFetcherEntries(for: entry)
        }
        if !validCIDsToDrop.isEmpty {
            sortedEntries.removeAll(where: { validCIDsToDrop.contains($0.cid) })
        }
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
        stateKeys: StateKeySet,
        validity: MempoolValidity = .valid,
        receiptRequirements: Set<ReceiptRequirement> = []
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
            stateKeys: stateKeys,
            validity: validity,
            receiptRequirements: receiptRequirements
        )
        insertEntry(entry)
        return .replacedExisting(oldCID: oldCID)
    }

    private func insertEntry(_ entry: MempoolEntry) {
        byCID[entry.cid] = entry
        byAccount[entry.sender, default: AccountTxQueue()].txsByNonce[entry.nonce] = entry

        switch entry.validity {
        case .valid:
            // Binary search for insertion point in descending-fee array: O(log n)
            let insertIndex = sortedEntries.binarySearchDescending { $0.fee >= entry.fee }
            sortedEntries.insert(entry, at: insertIndex)
        case .pending:
            pendingCount += 1
            pendingPerAccount[entry.sender, default: 0] += 1
            for req in entry.receiptRequirements {
                pendingByReceiptKey[req.receiptKey, default: []].insert(entry.cid)
            }
        }

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

        switch entry.validity {
        case .valid:
            // Binary search to fee range, then linear scan within that range
            let feeIdx = sortedEntries.binarySearchDescending { $0.fee > entry.fee }
            for i in feeIdx..<sortedEntries.count {
                if sortedEntries[i].fee < entry.fee { break }
                if sortedEntries[i].cid == entry.cid {
                    sortedEntries.remove(at: i)
                    break
                }
            }
        case .pending:
            pendingCount = max(0, pendingCount - 1)
            if let n = pendingPerAccount[entry.sender] {
                if n <= 1 { pendingPerAccount.removeValue(forKey: entry.sender) }
                else { pendingPerAccount[entry.sender] = n - 1 }
            }
            for req in entry.receiptRequirements {
                if var cids = pendingByReceiptKey[req.receiptKey] {
                    cids.remove(entry.cid)
                    if cids.isEmpty { pendingByReceiptKey.removeValue(forKey: req.receiptKey) }
                    else { pendingByReceiptKey[req.receiptKey] = cids }
                }
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
