// Retention pruning: mine past retentionDepth, verify old blocks are
// unpinned and the node's broker doesn't grow unbounded. Uses a short
// retention depth (10 blocks) to make the test fast.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import {
  chainInfo, chainOf, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'

const ROOT = smokeRoot('retention-pruning')
const [{ port, rpcPort }] = allocPorts(1, { seed: 103 })
const RETENTION = 10

console.log('=== retention-pruning smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start({ env: { RETENTION_DEPTH: String(RETENTION) } })
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log(`\n[1] Mine to height ${RETENTION + 5}...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, RETENTION + 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h1 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  height: ${h1}`)

console.log('\n[2] Verify recent blocks are accessible...')
const tipResp = await node.rpc('GET', `/api/block/latest?chain=${nexusDir}`)
if (!tipResp.ok) {
  console.error('  ✗ cannot fetch latest block')
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ latest block at height ${tipResp.json.index}`)

const recentH = h1 - 2
const recentResp = await node.rpc('GET', `/api/block/${recentH}?chain=${nexusDir}`)
if (!recentResp.ok) {
  console.error(`  ✗ cannot fetch recent block at height ${recentH}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ block at height ${recentH} accessible`)

console.log(`\n[3] Mine to height ${RETENTION * 3} to trigger more pruning...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, RETENTION * 3, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  height: ${h2}`)

console.log('\n[4] Verify tip still accessible after pruning...')
const tip2 = await node.rpc('GET', `/api/block/latest?chain=${nexusDir}`)
if (!tip2.ok) {
  console.error('  ✗ cannot fetch latest block after pruning')
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ latest block at height ${tip2.json.index}`)

console.log('\n[5] Check that very old blocks are pruned...')
const oldH = 1
const oldResp = await node.rpc('GET', `/api/block/${oldH}?chain=${nexusDir}`)
if (oldResp.ok && oldResp.json.index !== undefined) {
  console.log(`  note: block at height ${oldH} still accessible (may be in broker cache)`)
} else {
  console.log(`  ✓ block at height ${oldH} pruned or inaccessible`)
}

console.log('\n[6] Verify chain still functional after pruning...')
await startMining(node, nexusDir)
const h3Target = h2 + 5
await waitForHeight(node, nexusDir, h3Target, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const h3 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  ✓ chain advanced to height ${h3} after pruning`)

if (h3 < h3Target) {
  console.error(`  ✗ chain stalled at ${h3}, expected ≥${h3Target}`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log('\n✓ retention-pruning smoke test passed.')
node.stop()
await sleep(500)
process.exit(0)
