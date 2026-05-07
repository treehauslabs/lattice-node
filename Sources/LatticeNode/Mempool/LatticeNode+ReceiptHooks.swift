import Lattice
import Foundation
import cashew

// Receipt promotion, deposit eviction, and child-reorg hooks removed as
// part of the v2 mempool simplification. With automatic receipts there is
// no pending pool, so cross-chain receipt lifecycle management is no longer
// needed. The three hooks that lived here were:
//   - runReceiptPromotionHook (promoted pending -> valid on receipt arrival)
//   - runDepositEvictionHook  (evicted entries whose deposits were consumed)
//   - runChildReorgHook       (demoted/re-probed entries after parent reorg)
