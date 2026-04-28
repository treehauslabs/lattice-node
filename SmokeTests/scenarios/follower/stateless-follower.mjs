// Stateless-follower: A mines Nexus + Payments to height ≥ 50, B follows with
// `--stateless --subscribe Nexus/Payments`. Asserts B converges on both tips
// AND its data dir stays under 10 MB (no per-chain CAS accumulation).

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { chainInfo, chainOf, deployChild, startMining, stopMining } from '../../lib/chain.mjs'
import { dirSizeBytes } from '../../lib/probe.mjs'

const ROOT = smokeRoot('stateless-follower')
const [a, b] = allocPorts(2, { seed: 13 })
const CHILD = 'Payments'
const TARGET_HEIGHT = 50
const DISK_BUDGET_MB = 10

console.log('=== stateless-follower smoke (deep parent history; B follows with no disk) ===')
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

console.log(`\n[2] Deploy ${CHILD} + start mining both chains...`)
await deployChild(A, { directory: CHILD, parentDirectory: nexusDir, premine: 0 })
await startMining(A, nexusDir)

console.log(`\n[3] Mine until both chains reach height ≥ ${TARGET_HEIGHT}...`)
await waitFor(async () => {
  const info = await chainInfo(A)
  const nx = chainOf(info, nexusDir)
  const ch = chainOf(info, CHILD)
  return (nx?.height ?? 0) >= TARGET_HEIGHT && (ch?.height ?? 0) >= TARGET_HEIGHT ? info : null
}, `A heights ≥ ${TARGET_HEIGHT}`, { timeoutMs: 240_000, intervalMs: 1000 })

console.log(`\n[4] Freeze A's tips...`)
await stopMining(A, nexusDir)
await stopMining(A, CHILD)
await sleep(2500)
const aFrozen = await chainInfo(A)
const aNx = chainOf(aFrozen, nexusDir)
const aCh = chainOf(aFrozen, CHILD)
console.log(`  A frozen: ${nexusDir}@${aNx.height} ${CHILD}@${aCh.height}`)

console.log(`\n[5] Boot B fresh with --stateless --subscribe ${nexusDir}/${CHILD}...`)
B.start({ peers: [A], subscribe: [`${nexusDir}/${CHILD}`], extraArgs: ['--stateless'] })
await B.waitForRPC()

console.log(`\n[6] Waiting for B to converge on both chains...`)
await waitFor(async () => {
  const bInfo = await chainInfo(B)
  const bNx = chainOf(bInfo, nexusDir)
  const bCh = chainOf(bInfo, CHILD)
  return bNx?.tip === aNx.tip && bCh?.tip === aCh.tip ? true : null
}, 'B converged on both tips', { timeoutMs: 90_000, intervalMs: 1000 })

const bSize = dirSizeBytes(B.dir)
const bSizeMB = (bSize / (1024 * 1024)).toFixed(2)
console.log(`\n[7] B data-dir size: ${bSizeMB} MB (budget ${DISK_BUDGET_MB} MB)`)
if (bSize > DISK_BUDGET_MB * 1024 * 1024) {
  console.error(`  ✗ B exceeded disk budget — stateless mode is leaking pins`)
  console.error(`    inspect: du -sh ${B.dir}/*`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ B stayed under disk budget`)

console.log(`\n✓ B converged at ${nexusDir}@${aNx.height}, ${CHILD}@${aCh.height} with ${bSizeMB}MB on disk`)
console.log('✓ stateless-follower smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
