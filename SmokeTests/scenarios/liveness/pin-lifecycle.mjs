// Pin lifecycle: verify that a node retains state across restart and
// reannounces pinned data. Uses configurable short intervals.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { tipInfo, mineBurst } from '../../lib/chain.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('pin-lifecycle')
const [a, b] = allocPorts(2, { seed: 77 })
const PIN_EXPIRY = 120
const REANNOUNCE = 120
const EVICTION = 30

const pinEnv = {
  PIN_ANNOUNCE_EXPIRY: String(PIN_EXPIRY),
  REANNOUNCE_INTERVAL: String(REANNOUNCE),
  EVICTION_INTERVAL: String(EVICTION),
}

console.log('=== pin-lifecycle smoke test ===')

const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot A and B, wait for connection, mine...')
A.start({ env: pinEnv })
await A.waitForRPC()
await A.readIdentity()

B.start({ peers: [A], env: pinEnv })
await B.waitForRPC()

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-B connected', { timeoutMs: 30_000 })

const aTip = await mineBurst(A, 'Nexus')
console.log(`  A@${aTip.height}`)

const bTip = await waitFor(async () => {
  const bt = await tipInfo(B)
  return bt && bt.tip === aTip.tip ? bt : null
}, 'B converged', { timeoutMs: 60_000, intervalMs: 2000 })
console.log(`  ✓ B synced to height=${bTip.height}`)

console.log('\n[2] Stop B, wait past eviction cycle...')
await B.stopAndAwaitShutdown()
const evictWait = EVICTION + 5
console.log(`  waiting ${evictWait}s...`)
await sleep(evictWait * 1000)

console.log('\n[3] Restart B — should retain state...')
B.start({ peers: [A], env: pinEnv })
await B.waitForRPC()

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-B reconnected', { timeoutMs: 30_000 })

const bTip2 = await tipInfo(B)
if (bTip2.height < bTip.height) {
  console.error(`  ✗ B lost state: was ${bTip.height}, now ${bTip2.height}`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ B retained state (height ${bTip2.height})`)

console.log('\n[4] Mine more, verify B still syncs...')
const aFinal = await mineBurst(A, 'Nexus', { targetHeight: bTip2.height + 3 })
const bFinal = await waitFor(async () => {
  const bt = await tipInfo(B)
  return bt && bt.tip === aFinal.tip ? bt : null
}, 'B converged post-restart', { timeoutMs: 60_000, intervalMs: 2000 })
console.log(`  ✓ B synced post-restart to height=${bFinal.height}`)

console.log('\n✓ pin-lifecycle smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
