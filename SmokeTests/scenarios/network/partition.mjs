// Network partition: A+B mutually peered, C standalone (forms its own
// partition from genesis). Both A and C mine, then heal by restarting C with
// --peer A,B. Asserts:
//   - A and C diverge during the partition window.
//   - All three converge after heal.
//   - Final height ≥ max pre-heal height (heaviest-chain rule).
//   - At least one miner's tip changed (reorg fired).

import { readFileSync } from 'node:fs'
import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { startMining, stopMining, tipInfo } from '../../lib/chain.mjs'

const ROOT = smokeRoot('partition')
const [a, b, c] = allocPorts(3, { seed: 41 })
const PARTITION_MS = 5_000

console.log('=== partition smoke (3 nodes, two partitions, heal & converge) ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
    { name: 'C', port: c.port, rpcPort: c.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')
const C = net.byName('C')

console.log('\n[1] Boot A (alone)...')
A.start()
await A.waitForRPC()
await A.readIdentity()

console.log(`\n[2] Boot B peered to A; boot C standalone (partition)...`)
B.start({ peers: [A] })
C.start()
await B.waitForRPC()
await C.waitForRPC()
await B.readIdentity()

console.log(`\n[3] Mine in two partitions ({A,B} and {C})...`)
const ax = await tipInfo(A)
await startMining(A, ax.nexus)
await startMining(C, ax.nexus)

await sleep(PARTITION_MS)
await stopMining(A, ax.nexus)
console.log(`  A stopped; let C run 2s longer to break the tie...`)
await sleep(2000)
await stopMining(C, ax.nexus)
await sleep(2000)

const preA = await tipInfo(A)
const preB = await tipInfo(B)
const preC = await tipInfo(C)
console.log(`  pre-heal: A=${preA.height}/${preA.tip.slice(0, 16)} B=${preB.height}/${preB.tip.slice(0, 16)} C=${preC.height}/${preC.tip.slice(0, 16)}`)

if (preA.tip === preC.tip) {
  console.error(`  ✗ A and C share a tip — partition didn't isolate.`)
  net.teardown(); await sleep(500); process.exit(1)
}
const maxPre = Math.max(preA.height, preC.height)
console.log(`  partition isolated. Heaviest pre-heal: ${preA.height >= preC.height ? '{A,B}' : '{C}'}@${maxPre}`)

console.log(`\n[4] Heal: restart C with --peer A,B...`)
await C.stopAndAwaitShutdown()
await sleep(500)
C.start({ peers: [A, B] })
await C.waitForRPC()

console.log(`\n[5] Waiting for full-mesh convergence (up to 60s)...`)
const finalTip = await waitFor(async () => {
  const [aT, bT, cT] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  return aT?.tip && aT.tip === bT?.tip && aT.tip === cT?.tip ? aT : null
}, 'three-node converged after heal', { timeoutMs: 60_000, intervalMs: 1000 })

console.log(`  ✓ converged at height=${finalTip.height} tip=${finalTip.tip.slice(0, 20)}...`)

if (finalTip.height < maxPre) {
  console.error(`  ✗ converged at height ${finalTip.height} but max pre-heal was ${maxPre} — heaviest-chain rule violated`)
  net.teardown(); await sleep(500); process.exit(1)
}

const reorgedSides = []
if (preA.tip !== finalTip.tip) reorgedSides.push('A')
if (preC.tip !== finalTip.tip) reorgedSides.push('C')
if (reorgedSides.length === 0) {
  console.error(`  ✗ neither miner's tip changed — partition may not have produced divergent chains`)
  net.teardown(); await sleep(500); process.exit(1)
}

let reorgLogSeen = false
for (const side of reorgedSides) {
  try {
    const log = readFileSync(`${ROOT}/${side}.log`, 'utf8')
    if (/\bReorg:\s/.test(log) || /\[reorg\]/i.test(log)) { reorgLogSeen = true; break }
  } catch {}
}
console.log(`  reorg observed on: ${reorgedSides.join(', ')} (log signal: ${reorgLogSeen ? 'yes' : 'tip-swap only'})`)

console.log(`\n✓ partition smoke test passed (final height ${finalTip.height}, max pre-heal ${maxPre}).`)
net.teardown()
await sleep(500)
process.exit(0)
