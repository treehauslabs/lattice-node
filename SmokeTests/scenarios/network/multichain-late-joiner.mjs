// Multi-chain late joiner: A mines Nexus + 2 child chains to depth ≥ 30.
// B joins fresh, subscribes to both children, and must discover + sync
// all 3 chains. Follows the same frozen-tip pattern as late-joiner.mjs.
//
// GATED: requires SMOKE_MULTICHAIN_SYNC=1 — known issue with multi-child
// subscribe discovery on frozen peers (B syncs nexus but doesn't register
// child chains). See late-joiner.mjs for the single-child variant.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import {
  chainInfo, chainOf, deployChild, startMining, stopMining,
  waitForHeight,
} from '../../lib/chain.mjs'

const ROOT = smokeRoot('multichain-late-joiner')
const [a, b] = allocPorts(2, { seed: 93 })
const CHILD1 = 'Alpha'
const CHILD2 = 'Beta'
const TARGET = 30

console.log('=== multichain-late-joiner smoke test ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot A, deploy 2 child chains, mine to depth...')
A.start()
await A.waitForRPC()
await A.readIdentity()

const infoA = await chainInfo(A)
const nexusDir = infoA.nexus

await deployChild(A, { directory: CHILD1, parentDirectory: nexusDir, premine: 0 })
await deployChild(A, { directory: CHILD2, parentDirectory: nexusDir, premine: 0 })
await startMining(A, nexusDir)
await waitForHeight(A, nexusDir, TARGET, 120_000)
await waitForHeight(A, CHILD1, TARGET, 120_000)
await waitForHeight(A, CHILD2, TARGET, 120_000)

console.log('\n[2] Freeze A\'s tip...')
await stopMining(A, nexusDir)
await stopMining(A, CHILD1)
await stopMining(A, CHILD2)
await sleep(2500)

const aInfo = await chainInfo(A)
const aNx = chainOf(aInfo, nexusDir)
const aCh1 = chainOf(aInfo, CHILD1)
const aCh2 = chainOf(aInfo, CHILD2)
console.log(`  A frozen: ${nexusDir}@${aNx.height}, ${CHILD1}@${aCh1.height}, ${CHILD2}@${aCh2.height}`)

console.log('\n[3] Boot B with --subscribe for both children...')
B.start({ peers: [A], subscribe: [`${nexusDir}/${CHILD1}`, `${nexusDir}/${CHILD2}`] })
await B.waitForRPC()

console.log('\n[4] Wait for B to sync all chains...')
const bInfo = await waitFor(async () => {
  const bi = await chainInfo(B)
  if (!bi) return null
  const bNx = chainOf(bi, nexusDir)
  const bCh1 = chainOf(bi, CHILD1)
  const bCh2 = chainOf(bi, CHILD2)
  if (!bNx || bNx.tip !== aNx.tip) return null
  if (!bCh1 || bCh1.tip !== aCh1.tip) return null
  if (!bCh2 || bCh2.tip !== aCh2.tip) return null
  return bi
}, 'B converged on all tips', { timeoutMs: 120_000, intervalMs: 2000 })

console.log(`  B chains: ${bInfo.chains.map(c => `${c.directory}@${c.height}`).join(', ')}`)
console.log(`  ✓ B discovered and synced both child chains`)

console.log('\n✓ multichain-late-joiner smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
