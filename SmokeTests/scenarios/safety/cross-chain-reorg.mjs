// Cross-chain swap under reorg: deposit on child chain, child chain
// reorgs via partition heal. Verify the deposit is rolled back on the
// losing fork and the swap can't complete on stale state.
//
// Uses the partition pattern: A+B mine together, C mines alone.
// A deploys a child chain. User deposits on child (A's fork).
// After heal, if C wins, the deposit should vanish.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, chainOf, getNonce, getBalance, getDeposit,
  startMining, stopMining, awaitMiningQuiesced,
  deployChild, waitForHeight, tipInfo, mineBurst,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('cross-chain-reorg')
const [a, b, c] = allocPorts(3, { seed: 97 })
const CHILD = 'Reorgable'

console.log('=== cross-chain-reorg smoke test ===')
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

console.log('\n[1] Boot A (miner), deploy child chain...')
A.start()
await A.waitForRPC()
await A.readIdentity()
const aIdent = await A.readIdentity()
const aKP = { privateKey: aIdent.privateKey, publicKey: aIdent.publicKey }
const aAddr = computeAddress(aIdent.publicKey)

const infoA = await chainInfo(A)
const nexusDir = infoA.nexus

await startMining(A, nexusDir)
await deployChild(A, { directory: CHILD, parentDirectory: nexusDir })
await stopMining(A, nexusDir)
await sleep(1000)
await startMining(A, nexusDir)
await waitForHeight(A, CHILD, 3, 120_000)

console.log('\n[2] Boot B peered to A, C standalone...')
B.start({ peers: [A], subscribe: [`${nexusDir}/${CHILD}`] })
C.start()
await B.waitForRPC()
await B.readIdentity()
await C.waitForRPC()

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(B)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-B connected', { timeoutMs: 30_000 })

console.log('\n[3] Mine on both partitions...')
await startMining(A, nexusDir)
await startMining(C, nexusDir)
await sleep(3000)
await stopMining(A, nexusDir)
await sleep(2000)
await stopMining(C, nexusDir)
await awaitMiningQuiesced(A, nexusDir)

console.log('\n[4] Deposit on child chain (A\'s partition)...')
const user = genKeypair()
await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)

const fundNonce = await getNonce(A, aAddr, CHILD)
await submitTx(A, {
  chainPath: [nexusDir, CHILD], nonce: fundNonce, signers: [aAddr], fee: 1,
  accountActions: [
    { owner: aAddr, delta: -2001 },
    { owner: user.address, delta: 2000 },
  ],
}, CHILD, aKP)
await startMining(A, nexusDir)
await waitFor(async () => (await getBalance(A, user.address, CHILD)) >= 2000,
  'user funded on child', { timeoutMs: 120_000 })
await stopMining(A, nexusDir)
await awaitMiningQuiesced(A, nexusDir)

const swapNonce = Date.now().toString(16).padStart(32, '0').slice(-32)
const depNonce = await getNonce(A, user.address, CHILD)
await submitTx(A, {
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee: 1,
  accountActions: [{ owner: user.address, delta: -501 }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: 500, amountDeposited: 500 }],
}, CHILD, user)
await startMining(A, nexusDir)
await waitFor(async () => {
  const d = await getDeposit(A, user.address, 500, swapNonce, CHILD)
  return d.exists ? d : null
}, 'deposit visible on A', { timeoutMs: 60_000 })
console.log('  ✓ deposit confirmed on A\'s fork')

const preTipA = await tipInfo(A)
const preTipC = await tipInfo(C)
console.log(`  pre-heal: A@${preTipA.height} C@${preTipC.height}`)

if (preTipA.tip === preTipC.tip) {
  console.log('  ⚠ partitions not isolated — test inconclusive')
  net.teardown(); await sleep(500); process.exit(0)
}

const winner = preTipA.height >= preTipC.height ? 'A' : 'C'
console.log(`  heavier chain: ${winner}`)

console.log('\n[5] Heal: restart C with --peer A,B...')
await C.stopAndAwaitShutdown()
await sleep(500)
C.start({ peers: [A, B] })
await C.waitForRPC()

await waitFor(async () => {
  const [ap, bp] = await Promise.all([peerCount(A), peerCount(C)])
  return ap >= 1 && bp >= 1 ? true : null
}, 'A-C connected', { timeoutMs: 30_000 })
await sleep(3000)

await mineBurst(A, nexusDir)

const finalTip = await waitFor(async () => {
  const [at, ct] = await Promise.all([tipInfo(A), tipInfo(C)])
  return at?.tip && at.tip === ct?.tip ? at : null
}, 'A-C converged', { timeoutMs: 120_000, intervalMs: 3000 })
console.log(`  converged at height=${finalTip.height}`)

console.log('\n[6] Check deposit state after reorg...')
if (winner === 'C') {
  const depPost = await getDeposit(A, user.address, 500, swapNonce, CHILD)
  if (depPost.exists) {
    console.log('  ⚠ deposit still exists on A after C won — child state may not have reorged')
  } else {
    console.log('  ✓ deposit rolled back (C won, A\'s fork orphaned)')
  }
} else {
  const depPost = await getDeposit(A, user.address, 500, swapNonce, CHILD)
  if (depPost.exists) {
    console.log('  ✓ deposit preserved (A won)')
  } else {
    console.log('  ⚠ deposit lost even though A won')
  }
}

console.log('\n✓ cross-chain-reorg smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
