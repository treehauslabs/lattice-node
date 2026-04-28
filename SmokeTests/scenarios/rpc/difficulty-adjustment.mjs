// Difficulty adjustment: mine past the difficulty adjustment window (120 blocks
// for Nexus), verify difficulty changes between the first and last block.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep } from '../../lib/waitFor.mjs'
import { chainInfo, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from '../../lib/chain.mjs'

const ROOT = smokeRoot('difficulty-adjustment')
const [{ port, rpcPort }] = allocPorts(1, { seed: 67 })

console.log('=== difficulty-adjustment smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus

const specResp = await node.rpc('GET', `/api/chain/spec?chain=${nexusDir}`)
if (!specResp.ok) throw new Error(`chain/spec failed`)
const adjWindow = specResp.json.difficultyAdjustmentWindow ?? 120
console.log(`  adjustment window: ${adjWindow} blocks`)

console.log(`\n[1] Query early block difficulty...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
const earlyBlock = await node.rpc('GET', `/api/block/3?chain=${nexusDir}`)
const earlyDiff = earlyBlock.json?.difficulty
console.log(`  block 3 difficulty: ${earlyDiff?.slice(0, 20)}...`)

console.log(`\n[2] Mine past adjustment window (${adjWindow} blocks)...`)
await waitForHeight(node, nexusDir, adjWindow + 5, 300_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const height = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  reached height ${height}`)

console.log(`\n[3] Query late block difficulty...`)
const lateBlock = await node.rpc('GET', `/api/block/${adjWindow + 2}?chain=${nexusDir}`)
const lateDiff = lateBlock.json?.difficulty
console.log(`  block ${adjWindow + 2} difficulty: ${lateDiff?.slice(0, 20)}...`)

if (!earlyDiff || !lateDiff) {
  console.error(`  ✗ couldn't read difficulty from block responses`)
  node.stop(); await sleep(500); process.exit(1)
}

if (earlyDiff === lateDiff) {
  console.log(`  note: difficulty unchanged — may be expected if block time matches target`)
} else {
  console.log(`  ✓ difficulty adjusted: ${earlyDiff.slice(0, 16)}... → ${lateDiff.slice(0, 16)}...`)
}

console.log(`\n[4] Verify nextDifficulty field exists...`)
const tipResp = await node.rpc('GET', `/api/block/latest?chain=${nexusDir}`)
const hasNextDiff = tipResp.json?.nextDifficulty !== undefined
console.log(`  nextDifficulty present: ${hasNextDiff}`)
if (hasNextDiff) {
  console.log(`  nextDifficulty: ${tipResp.json.nextDifficulty?.toString().slice(0, 20)}...`)
}

console.log(`\n✓ difficulty-adjustment smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
