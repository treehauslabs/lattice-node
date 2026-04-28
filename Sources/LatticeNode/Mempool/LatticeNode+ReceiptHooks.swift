import Lattice
import Foundation
import cashew

extension LatticeNode {

    /// Direct children of `directory` (one hop deeper in the chain tree).
    /// Derived from `parentDirectoryByChain`'s reverse direction. A receipt-
    /// state change on `directory` can only affect mempools at this level.
    private func directChildren(of directory: String) -> [String] {
        parentDirectoryByChain.compactMap { (child, parent) in
            parent == directory ? child : nil
        }
    }

    /// Look up the stored withdrawer for a parsed receipt key on the chain
    /// it addresses. Used as the probe closure for `recheckPending` and
    /// `demoteValidWithdrawals` so the mempool stays oblivious to chain
    /// state — it only knows (key → withdrawer?).
    private func probeReceipt(receiptKey: String) async -> String? {
        guard let parsed = ReceiptKey(receiptKey) else { return nil }
        let result: String?
        do {
            result = try await getReceipt(
                demander: parsed.demander,
                amountDemanded: parsed.amountDemanded,
                nonce: parsed.nonce,
                directory: parsed.directory
            )
        } catch {
            result = nil
        }
        return result
    }

    /// After a block accepts on `parentDirectory`, walk its receipt actions
    /// and ask each addressed child mempool to promote any pending entries
    /// whose required receipt now exists. Wrong-owner mismatches evict
    /// permanently. The block's txEntries already classify each receipt
    /// action's target child (`ra.directory`); we just group + dispatch.
    func runReceiptPromotionHook(
        txEntries: [String: VolumeImpl<Transaction>],
        parentDirectory: String
    ) async {
        var keysByChild: [String: Set<String>] = [:]
        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            for ra in body.receiptActions {
                let key = ReceiptKey(receiptAction: ra).description
                keysByChild[ra.directory, default: []].insert(key)
            }
        }
        guard !keysByChild.isEmpty else { return }

        for (childDir, keys) in keysByChild {
            // Only honor receipts whose addressed directory is a direct
            // child of the chain that just accepted — guards against a
            // receipt action that names a misaligned directory.
            guard parentDirectoryByChain[childDir] == parentDirectory else { continue }
            guard let childNetwork = networks[childDir] else { continue }
            let probe: @Sendable (String) async -> String? = { [weak self] key in
                await self?.probeReceipt(receiptKey: key) ?? nil
            }
            _ = await childNetwork.nodeMempool.recheckPending(
                affectedReceiptKeys: keys,
                probe: probe
            )
        }
    }

    /// After a block accepts on `directory`, evict any other mempool entry
    /// whose deposit-key set intersects the deposits drained by this block's
    /// withdrawals. Catches the cross-pool conflict where a pending
    /// withdrawal holds a deposit that a different valid withdrawal just
    /// consumed. The included tx itself has already been removed by
    /// `batchUpdateConfirmedNonces` (nonce < confirmedNonce), so this only
    /// targets sibling entries holding the same deposit.
    func runDepositEvictionHook(
        txEntries: [String: VolumeImpl<Transaction>],
        directory: String
    ) async {
        guard let network = networks[directory] else { return }
        var consumed = Set<String>()
        for (_, txHeader) in txEntries {
            guard let body = txHeader.node?.body.node else { continue }
            for wa in body.withdrawalActions {
                consumed.insert(DepositKey(withdrawalAction: wa).description)
            }
        }
        guard !consumed.isEmpty else { return }
        _ = await network.nodeMempool.evictByDepositKeys(consumed)
    }

    /// After `parentDirectory` reorgs, re-evaluate every direct child's
    /// mempool against the new parent tip. A receipt that was canonical on
    /// the old chain may have been rolled back, demoting a previously-valid
    /// withdrawal to pending; a wrong-owner that now appears evicts.
    /// Also re-probes every pending entry — receipts may have appeared on
    /// the new chain that aren't tracked by the latest block alone.
    func runChildReorgHook(parentDirectory: String) async {
        let probe: @Sendable (String) async -> String? = { [weak self] key in
            await self?.probeReceipt(receiptKey: key) ?? nil
        }
        for childDir in directChildren(of: parentDirectory) {
            guard let childNetwork = networks[childDir] else { continue }
            let mempool = childNetwork.nodeMempool

            // Demote: walk valid withdrawal-bearing entries; any whose
            // required receipt is no longer canonical at parent tip moves
            // back to pending (or evicts on wrong-owner).
            let validEntries = await mempool.validWithdrawalEntries()
            var demotionCandidates: [(cid: String, requirements: Set<ReceiptRequirement>)] = []
            demotionCandidates.reserveCapacity(validEntries.count)
            for entry in validEntries {
                var reqs: Set<ReceiptRequirement> = []
                for wa in entry.body.withdrawalActions {
                    let key = ReceiptKey(withdrawalAction: wa, directory: childDir).description
                    reqs.insert(ReceiptRequirement(
                        receiptKey: key,
                        expectedWithdrawer: wa.withdrawer
                    ))
                }
                if !reqs.isEmpty {
                    demotionCandidates.append((cid: entry.cid, requirements: reqs))
                }
            }
            if !demotionCandidates.isEmpty {
                _ = await mempool.demoteValidWithdrawals(
                    candidates: demotionCandidates,
                    probe: probe
                )
            }

            // Re-probe pending: receipts may have appeared in the new
            // chain that no specific block-accept hook covered.
            let pendingKeys = await mempool.pendingReceiptKeys()
            if !pendingKeys.isEmpty {
                _ = await mempool.recheckPending(
                    affectedReceiptKeys: pendingKeys,
                    probe: probe
                )
            }
        }
    }
}
