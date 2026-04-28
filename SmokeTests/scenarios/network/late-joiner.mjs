// Late-joiner: A mines Nexus + child chain to depth ≥ 30, then B boots fresh
// with --subscribe Nexus/Payments. Exercises the parent-anchored bootstrap
// path: B walks A's parent history backwards, derives every embedded child
// block's anchor, validates the child chain, then registers and backfills.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { chainInfo, chainOf, deployChild, startMining, stopMining } from '../../lib/chain.mjs'

const ROOT = smokeRoot('late-joiner')
const [a, b] = allocPorts(2, { seed: 21 })
const CHILD = 'Payments'
const TARGET_HEIGHT = 30

console.log('=== late-joiner smoke (deep parent history before B joins) ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot A solo...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
await A.readIdentity()

console.log(`\n[2] Deploy ${CHILD} + mine both chains...`)
await deployChild(A, { directory: CHILD, parentDirectory: nexusDir, premine: 0 })
await startMining(A, nexusDir)

console.log(`\n[3] Mine until both chains reach height ≥ ${TARGET_HEIGHT}...`)
await waitFor(async () => {
  const info = await chainInfo(A)
  const nx = chainOf(info, nexusDir)
  const ch = chainOf(info, CHILD)
  return (nx?.height ?? 0) >= TARGET_HEIGHT && (ch?.height ?? 0) >= TARGET_HEIGHT ? info : null
}, `A heights ≥ ${TARGET_HEIGHT}`, { timeoutMs: 120_000, intervalMs: 1000 })

console.log(`\n[4] Freeze A's tip...`)
await stopMining(A, nexusDir)
await stopMining(A, CHILD)
await sleep(2500)
const aFrozen = await chainInfo(A)
const aNx = chainOf(aFrozen, nexusDir)
const aCh = chainOf(aFrozen, CHILD)
console.log(`  A frozen: ${nexusDir}@${aNx.height} tip=${aNx.tip.slice(0, 20)}...`)
console.log(`  A frozen: ${CHILD}@${aCh.height} tip=${aCh.tip.slice(0, 20)}...`)

console.log(`\n[5] Boot B fresh with --peer <A> --subscribe Nexus/${CHILD}...`)
B.start({ peers: [A], subscribe: [`Nexus/${CHILD}`] })
await B.waitForRPC()

console.log(`\n[6] Waiting for B to bootstrap + converge (up to 90s)...`)
await waitFor(async () => {
  const bInfo = await chainInfo(B)
  const bNx = chainOf(bInfo, nexusDir)
  const bCh = chainOf(bInfo, CHILD)
  return bNx?.tip === aNx.tip && bCh?.tip === aCh.tip ? true : null
}, 'B converged on both tips', { timeoutMs: 90_000, intervalMs: 1000 })

console.log(`✓ B late-joined and converged at ${nexusDir}@${aNx.height}, ${CHILD}@${aCh.height}`)
console.log('✓ late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
