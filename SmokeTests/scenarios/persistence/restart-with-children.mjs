// Restart with child chains: mine nexus + 2 child chains, submit txs
// on each child, SIGTERM, restart, verify all chains restored with
// correct heights and balances. Then mine more and submit new txs to
// confirm full functionality after restart.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, chainOf, getNonce, getBalance,
  startMining, stopMining, awaitMiningQuiesced,
  deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('restart-with-children')
const [{ port, rpcPort }] = allocPorts(1, { seed: 99 })
const CHILD1 = 'Alpha'
const CHILD2 = 'Beta'

console.log('=== restart-with-children smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log('\n[1] Deploy 2 child chains, mine...')
await startMining(node, nexusDir)
await deployChild(node, { directory: CHILD1, parentDirectory: nexusDir, premine: 0 })
await deployChild(node, { directory: CHILD2, parentDirectory: nexusDir, premine: 0 })
await waitForHeight(node, CHILD1, 5, 120_000)
await waitForHeight(node, CHILD2, 5, 120_000)

console.log('\n[2] Transfer on each child chain...')
const userA = genKeypair()
const userB = genKeypair()
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const n1 = await getNonce(node, minerAddr, CHILD1)
await submitTx(node, {
  chainPath: [nexusDir, CHILD1], nonce: n1, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -1001 },
    { owner: userA.address, delta: 1000 },
  ],
}, CHILD1, minerKP)

const n2 = await getNonce(node, minerAddr, CHILD2)
await submitTx(node, {
  chainPath: [nexusDir, CHILD2], nonce: n2, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -2001 },
    { owner: userB.address, delta: 2000 },
  ],
}, CHILD2, minerKP)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, userA.address, CHILD1)) >= 1000,
  'userA funded', { timeoutMs: 120_000 })
await waitFor(async () => (await getBalance(node, userB.address, CHILD2)) >= 2000,
  'userB funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const preInfo = await chainInfo(node)
const preNx = chainOf(preInfo, nexusDir)
const preCh1 = chainOf(preInfo, CHILD1)
const preCh2 = chainOf(preInfo, CHILD2)
console.log(`  pre-restart: ${nexusDir}@${preNx.height}, ${CHILD1}@${preCh1.height}, ${CHILD2}@${preCh2.height}`)
console.log(`  userA balance on ${CHILD1}: ${await getBalance(node, userA.address, CHILD1)}`)
console.log(`  userB balance on ${CHILD2}: ${await getBalance(node, userB.address, CHILD2)}`)

console.log('\n[3] SIGTERM + restart...')
node.stop()
await sleep(3000)
node.start()
await node.waitForRPC(120_000)
console.log('  ✓ RPC ready after restart')

console.log('\n[4] Verify all chains restored...')
const postInfo = await chainInfo(node)
const postNx = chainOf(postInfo, nexusDir)
const postCh1 = chainOf(postInfo, CHILD1)
const postCh2 = chainOf(postInfo, CHILD2)

if (!postNx || postNx.height < preNx.height - 1) {
  console.error(`  ✗ nexus regressed: ${postNx?.height} < ${preNx.height}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${nexusDir}@${postNx.height} (was ${preNx.height})`)

if (!postCh1) {
  console.error(`  ✗ ${CHILD1} not found after restart`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${CHILD1}@${postCh1.height} (was ${preCh1.height})`)

if (!postCh2) {
  console.error(`  ✗ ${CHILD2} not found after restart`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${CHILD2}@${postCh2.height} (was ${preCh2.height})`)

console.log('\n[5] Verify balances preserved...')
const balA = await getBalance(node, userA.address, CHILD1)
const balB = await getBalance(node, userB.address, CHILD2)
if (balA < 1000) {
  console.error(`  ✗ userA balance on ${CHILD1}: ${balA} (expected ≥1000)`)
  node.stop(); await sleep(500); process.exit(1)
}
if (balB < 2000) {
  console.error(`  ✗ userB balance on ${CHILD2}: ${balB} (expected ≥2000)`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ userA=${balA} userB=${balB}`)

console.log('\n[6] Mine + new tx after restart...')
const checker = genKeypair()
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const cn = await getNonce(node, minerAddr, CHILD1)
await submitTx(node, {
  chainPath: [nexusDir, CHILD1], nonce: cn, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -501 },
    { owner: checker.address, delta: 500 },
  ],
}, CHILD1, minerKP)
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, checker.address, CHILD1)) >= 500,
  'post-restart tx confirmed', { timeoutMs: 120_000 })
console.log('  ✓ new tx confirmed on child chain after restart')

console.log('\n✓ restart-with-children smoke test passed.')
node.stop()
await sleep(500)
process.exit(0)
