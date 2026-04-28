// Two-node sync: A (miner) deploys child chain "Payments" and mines both Nexus
// and Payments; B (follower) bootstraps from A and must converge on both tips.
// Exercises validated block-receive plus child-chain extraction from
// merged-mined Nexus blocks.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { chainInfo, chainOf, deployChild, startMining, stopMining } from '../../lib/chain.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('sync')
const [a, b] = allocPorts(2, { seed: 91 })
const CHILD = 'Payments'

console.log('=== two-node sync smoke test (Nexus + child) ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot node A (miner)...')
A.start()
const aBoot = await A.waitForRPC()
const nexusDir = aBoot.nexus
const aIdent = await A.readIdentity()
console.log(`  A pubkey: ${aIdent.publicKey.slice(0, 32)}...`)
console.log(`  nexus directory: ${nexusDir}`)

console.log(`\n[2] Boot node B with --peer <A> --subscribe Nexus/${CHILD}...`)
B.start({ peers: [A], subscribe: [`Nexus/${CHILD}`] })
await B.waitForRPC()

console.log('  letting peers connect...')
await waitFor(async () => (await peerCount(A)) >= 1 && (await peerCount(B)) >= 1,
  'peers connected', { timeoutMs: 15_000 })
console.log(`  peer counts: A=${await peerCount(A)} B=${await peerCount(B)}`)

console.log(`\n[3] Deploying child chain "${CHILD}" on A...`)
await deployChild(A, { directory: CHILD, parentDirectory: nexusDir, premine: 0 })

console.log(`\n[4] Ensure A is mining ${nexusDir}...`)
try { await startMining(A, nexusDir) } catch (e) { console.log(`  (${e.message})`) }

const TARGET = 5
console.log(`\n[5] Mining on A until both chains reach height ${TARGET}...`)
await waitFor(async () => {
  const info = await chainInfo(A)
  const nx = chainOf(info, nexusDir)
  const ch = chainOf(info, CHILD)
  return (nx?.height ?? 0) >= TARGET && (ch?.height ?? 0) >= TARGET ? info : null
}, `A heights ≥ ${TARGET}`, { timeoutMs: 30_000 })

console.log(`\n[6] Stopping A's mining to freeze the tip...`)
await stopMining(A, nexusDir)
await stopMining(A, CHILD)
await sleep(2000)
const aFrozen = await chainInfo(A)
const aNxF = chainOf(aFrozen, nexusDir)
const aChF = chainOf(aFrozen, CHILD)
console.log(`  A frozen: ${nexusDir}@${aNxF.height} tip=${aNxF.tip.slice(0, 20)}...`)
console.log(`  A frozen: ${CHILD}@${aChF.height} tip=${aChF.tip.slice(0, 20)}...`)

console.log(`\n[7] Waiting for B to converge on both chains...`)
await waitFor(async () => {
  const bInfo = await chainInfo(B)
  const bNx = chainOf(bInfo, nexusDir)
  const bCh = chainOf(bInfo, CHILD)
  return bNx?.tip === aNxF.tip && bCh?.tip === aChF.tip ? true : null
}, 'B converged on both tips', { timeoutMs: 30_000 })

console.log(`✓ B converged: ${nexusDir}@${aNxF.height}, ${CHILD}@${aChF.height}`)
console.log('✓ two-node sync smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
