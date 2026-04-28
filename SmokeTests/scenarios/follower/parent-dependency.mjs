// Parent-dependency: subscription-to-child implies subscription to every
// ancestor, and a node cannot mine a chain it hasn't subscribed to.
//
// Topology: Nexus -> Mid -> Stable.
//
// Phase 1: B with `--subscribe Nexus/Mid/Stable` (single deepest path).
//   Pass: B registers + converges Nexus, Mid, AND Stable.
//
// Phase 2: C with default subscription (Nexus only).
//   Pass: /api/mining/start chain=Stable is a no-op; C never registers
//   Mid/Stable (subscription gate enforces).

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { chainInfo, chainOf, deployChild, startMining, stopMining } from '../../lib/chain.mjs'

const ROOT = smokeRoot('parent-dependency')
const [a, b, c] = allocPorts(3, { seed: 11 })
const MID = 'Mid', STABLE = 'Stable'
const TARGET_HEIGHT = 20
const C_OBSERVE_MS = 15_000

console.log('=== parent-dependency smoke (subscribe-implies-ancestor + mining gate) ===')
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

console.log('\n[1] Boot A solo...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
await A.readIdentity()

console.log(`\n[2] Deploy ${MID} (parent=${nexusDir}) + ${STABLE} (parent=${MID}) on A...`)
await deployChild(A, { directory: MID, parentDirectory: nexusDir, premine: 0 })
await deployChild(A, { directory: STABLE, parentDirectory: MID, premine: 0 })
await startMining(A, nexusDir)

console.log(`\n[3] Mine until all three chains reach height ≥ ${TARGET_HEIGHT}...`)
await waitFor(async () => {
  const info = await chainInfo(A)
  const nx = chainOf(info, nexusDir)
  const m = chainOf(info, MID)
  const s = chainOf(info, STABLE)
  return (nx?.height ?? 0) >= TARGET_HEIGHT
    && (m?.height ?? 0) >= TARGET_HEIGHT
    && (s?.height ?? 0) >= TARGET_HEIGHT ? info : null
}, `A heights ≥ ${TARGET_HEIGHT}`, { timeoutMs: 180_000, intervalMs: 1000 })

console.log(`\n[4] Freeze A's tips...`)
await stopMining(A, nexusDir)
await stopMining(A, MID)
await stopMining(A, STABLE)
await sleep(2500)
const aFrozen = await chainInfo(A)
const aNxF = chainOf(aFrozen, nexusDir)
const aMidF = chainOf(aFrozen, MID)
const aStF = chainOf(aFrozen, STABLE)
console.log(`  A frozen: ${nexusDir}@${aNxF.height} ${MID}@${aMidF.height} ${STABLE}@${aStF.height}`)

console.log(`\n[5] Phase 1: boot B with --subscribe ${nexusDir}/${MID}/${STABLE} (deepest path)...`)
B.start({ peers: [A], subscribe: [`${nexusDir}/${MID}/${STABLE}`] })
await B.waitForRPC()

console.log(`\n[6] Wait for B to register + converge all three chains (up to 90s)...`)
await waitFor(async () => {
  const bInfo = await chainInfo(B)
  const bNx = chainOf(bInfo, nexusDir)
  const bMid = chainOf(bInfo, MID)
  const bSt = chainOf(bInfo, STABLE)
  return bNx?.tip === aNxF.tip && bMid?.tip === aMidF.tip && bSt?.tip === aStF.tip ? true : null
}, 'B converged on all three tips', { timeoutMs: 90_000, intervalMs: 1000 })
console.log(`  ✓ Phase 1 passed: B registered + converged all three chains from single deepest --subscribe.`)

console.log(`\n[7] Phase 2: boot C with default subscription (Nexus only)...`)
C.start({ peers: [A] })
await C.waitForRPC()
await sleep(5000)

console.log(`\n[8] POST /api/mining/start chain=${STABLE} on C — must be a no-op...`)
const startRes = await C.rpc('POST', '/api/mining/start', { chain: STABLE })
console.log(`  RPC returned: ${JSON.stringify(startRes.json)} (observable side effects are what we test)`)

console.log(`\n[9] Observe C for ${C_OBSERVE_MS / 1000}s — Mid/Stable must NOT appear...`)
const obsDeadline = Date.now() + C_OBSERVE_MS
let cMidEverSeen = false, cStableEverSeen = false
while (Date.now() < obsDeadline) {
  const cInfo = await chainInfo(C)
  if (chainOf(cInfo, MID)) cMidEverSeen = true
  if (chainOf(cInfo, STABLE)) cStableEverSeen = true
  await sleep(1000)
}
if (cMidEverSeen || cStableEverSeen) {
  console.error(`  ✗ Phase 2 failed: C registered an unsubscribed chain (Mid=${cMidEverSeen}, Stable=${cStableEverSeen})`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ Phase 2 passed: mining/start on unsubscribed chain was a no-op; no auto-registration.`)

console.log(`\n✓ parent-dependency smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
