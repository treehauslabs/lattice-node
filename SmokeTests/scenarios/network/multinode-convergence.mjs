// Three-node mesh: A mines, B and C bootstrap from A and must converge to A's
// tip after mining stops. Validates merged-mining + gossip follow-up routing.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { startMining, stopMining, tipInfo } from '../../lib/chain.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('multinode')
const [a, b, c] = allocPorts(3, { seed: 31 })

console.log('=== multi-node mesh smoke test ===')
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

console.log('\n[1] Boot node A (will mine)...')
A.start()
await A.waitForRPC()
const aIdent = await A.readIdentity()
console.log(`  A pubkey: ${aIdent.publicKey.slice(0, 32)}...`)

console.log(`\n[2] Boot B and C with --peer <A>...`)
B.start({ peers: [A] })
C.start({ peers: [A] })
await B.waitForRPC()
await C.waitForRPC()

console.log('  letting peers connect...')
await waitFor(async () => (await peerCount(A)) >= 2,
  'A sees ≥2 peers', { timeoutMs: 10_000 })
await sleep(1000)

console.log('\n[3] Checking peer connectivity...')
const peers = [await peerCount(A), await peerCount(B), await peerCount(C)]
console.log(`  peer counts: A=${peers[0]} B=${peers[1]} C=${peers[2]}`)
if (peers[1] < 1 || peers[2] < 1) {
  console.error('  ✗ B and/or C have no peers'); net.teardown(); process.exit(1)
}

console.log('\n[4] Start mining on A...')
await startMining(A, 'Nexus')
const TARGET_HEIGHT = 10
const MINE_WINDOW_MS = 8000
const mineStart = Date.now()
while (Date.now() - mineStart < MINE_WINDOW_MS) {
  const t = await tipInfo(A)
  if (t && t.height >= TARGET_HEIGHT) break
  await sleep(500)
}
await stopMining(A, 'Nexus')
const aTip = await tipInfo(A)
console.log(`  ✓ mining stopped; A tip height=${aTip.height}`)
if (aTip.height < 2) {
  console.error('  ✗ A failed to mine any blocks'); net.teardown(); process.exit(1)
}

console.log('\n[5] Checking for convergence (up to 60s)...')
await waitFor(async () => {
  const [aT, bT, cT] = await Promise.all([tipInfo(A), tipInfo(B), tipInfo(C)])
  if (aT?.height) process.stdout.write(`\r  A@${aT.height} B@${bT?.height ?? '?'} C@${cT?.height ?? '?'}   `)
  return aT?.tip && aT.tip === bT?.tip && aT.tip === cT?.tip ? aT : null
}, 'three-node mesh converged', { timeoutMs: 60_000, intervalMs: 2000 })

const finalTip = await tipInfo(A)
console.log(`  ✓ converged at height=${finalTip.height} tip=${finalTip.tip.slice(0, 20)}...`)
console.log('\n✓ three-node mesh smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
