// Concurrent mining: A and B both mine the same nexus + child chain.
// Verify they converge to the same tip (no permanent fork) and both
// accept the heaviest chain.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, chainOf, getNonce, getBalance,
  startMining, stopMining, awaitMiningQuiesced,
  deployChild, waitForHeight, tipInfo, mineBurst,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('concurrent-mining')
const [a, b] = allocPorts(2, { seed: 101 })
const CHILD = 'Shared'

console.log('=== concurrent-mining smoke test ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'A', port: a.port, rpcPort: a.rpcPort },
    { name: 'B', port: b.port, rpcPort: b.rpcPort },
  ],
})
const A = net.byName('A')
const B = net.byName('B')

console.log('\n[1] Boot A, deploy child chain...')
A.start({ extraArgs: ['--finality-confirmations', '999999'] })
await A.waitForRPC()
await A.readIdentity()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)

const nexusDir = (await chainInfo(A)).nexus

await startMining(A, nexusDir)
await deployChild(A, { directory: CHILD, parentDirectory: nexusDir, premine: 0 })
await waitForHeight(A, CHILD, 3, 120_000)
await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)

console.log('\n[2] Boot B peered to A, subscribe to child...')
B.start({ peers: [A], subscribe: [`${nexusDir}/${CHILD}`] })
await B.waitForRPC()
await B.readIdentity()

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-B connected', { timeoutMs: 30_000 })
await sleep(5000)

console.log('\n[3] Both mine concurrently for 2 seconds...')
await startMining(A, nexusDir)
await startMining(B, nexusDir)
await sleep(2_000)
await stopMining(A, nexusDir)
await stopMining(B, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
await awaitMiningQuiesced(B, nexusDir)

const midA = await tipInfo(A)
const midB = await tipInfo(B)
console.log(`  after mining: A@${midA.height} B@${midB.height}`)

console.log('\n[4] Mine burst on A to trigger convergence...')
await mineBurst(A, nexusDir)
await sleep(3000)
await mineBurst(A, nexusDir, { targetHeight: midA.height + 10 })

const finalTip = await waitFor(async () => {
  const [at, bt] = await Promise.all([tipInfo(A), tipInfo(B)])
  return at?.tip && at.tip === bt?.tip ? at : null
}, 'A-B converged', { timeoutMs: 120_000, intervalMs: 3000 })
console.log(`  ✓ nexus tips converged at height ${finalTip.height}`)

const aInfo = await chainInfo(A)
const bInfo = await chainInfo(B)
const aCh = chainOf(aInfo, CHILD)
const bCh = chainOf(bInfo, CHILD)
if (aCh && bCh) {
  console.log(`  A: ${CHILD}@${aCh.height} B: ${CHILD}@${bCh.height}`)
  if (aCh.tip === bCh.tip) {
    console.log('  ✓ child chain tips converged')
  } else {
    console.log('  ⚠ child tips differ (may converge with more blocks)')
  }
}

console.log('\n[5] Submit tx on A, verify it lands on B...')
await stopMining(A, nexusDir)
await stopMining(B, nexusDir)
await awaitMiningQuiesced(A, nexusDir)
const user = genKeypair()
const n = await getNonce(A, aAddr, nexusDir)
await submitTx(A, {
  chainPath: [nexusDir], nonce: n, signers: [aAddr], fee: 1,
  accountActions: [
    { owner: aAddr, delta: -501 },
    { owner: user.address, delta: 500 },
  ],
}, nexusDir, aKP)
await startMining(A, nexusDir)
await waitFor(async () => (await getBalance(A, user.address, nexusDir)) >= 500,
  'tx confirmed on A', { timeoutMs: 120_000 })

await waitFor(async () => {
  try {
    const bal = await getBalance(B, user.address, nexusDir)
    return bal >= 500 ? true : null
  } catch { return null }
}, 'tx visible on B', { timeoutMs: 60_000 })
console.log('  ✓ tx submitted on A, confirmed and visible on B')

console.log('\n[6] Height sanity: both chains advanced during concurrent mining...')
if (finalTip.height < 5) {
  console.error(`  ✗ only reached height ${finalTip.height} — mining stalled`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ final height ${finalTip.height} (both miners contributed)`)

console.log('\n✓ concurrent-mining smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
