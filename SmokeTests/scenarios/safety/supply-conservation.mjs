// Supply conservation: verify that transfers don't create or destroy value.
// Phase 1: mine N blocks, record miner balance = baseline.
// Phase 2: mine M more blocks with NO txs, verify balance increased by exactly M*reward.
// Phase 3: transfer funds, verify sum(all known balances) == baseline + total_coinbase - fees.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('supply-conservation')
const [{ port, rpcPort }] = allocPorts(1, { seed: 33 })

console.log('=== supply-conservation smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

const specResp = await node.rpc('GET', `/api/chain/spec?chain=${nexusDir}`)
if (!specResp.ok) throw new Error(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const REWARD = specResp.json.initialReward
console.log(`  chain=${nexusDir} reward=${REWARD}`)

console.log(`\n[1] Establish baseline: mine to height 5, snapshot miner balance...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

await sleep(2000)
const h1 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const baselineBal = await getBalance(node, minerAddr, nexusDir)
console.log(`  height=${h1} minerBal=${baselineBal}`)

console.log(`\n[2] Mine 5 more blocks (no txs), verify exact reward accumulation...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, h1 + 3, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const bal2 = await getBalance(node, minerAddr, nexusDir)
const blocksMined = h2 - h1
const expectedIncrease = blocksMined * REWARD
const actualIncrease = bal2 - baselineBal
console.log(`  height=${h2} (+${blocksMined} blocks) bal=${bal2} increase=${actualIncrease} expected=${expectedIncrease}`)

if (actualIncrease !== expectedIncrease) {
  console.error(`  ✗ balance increased by ${actualIncrease}, expected ${expectedIncrease} (${blocksMined} blocks × ${REWARD})`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ exact reward accumulation: ${blocksMined} × ${REWARD} = ${expectedIncrease}`)

console.log(`\n[3] Transfer miner→user, verify conservation...`)
const user = genKeypair()
const FEE = 1
const SEND = 5000

const nonce = await getNonce(node, minerAddr, nexusDir)
const r = await submitTx(node, {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: FEE,
  accountActions: [
    { owner: minerAddr, delta: -(SEND + FEE) },
    { owner: user.address, delta: SEND },
  ],
}, nexusDir, minerKP)
if (!r.ok) throw new Error(`transfer failed: ${JSON.stringify(r.submit)}`)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= SEND,
  'user funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h3 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const minerBal3 = await getBalance(node, minerAddr, nexusDir)
const userBal3 = await getBalance(node, user.address, nexusDir)
const total3 = minerBal3 + userBal3
const coinbasesSince2 = (h3 - h2) * REWARD
const expectedTotal3 = bal2 + coinbasesSince2
console.log(`  height=${h3} miner=${minerBal3} user=${userBal3} total=${total3}`)
console.log(`  expected total (prev + coinbase - fee): ${expectedTotal3}`)

if (total3 !== expectedTotal3) {
  const diff = total3 - expectedTotal3
  console.error(`  ✗ off by ${diff} — supply not conserved`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ supply exactly conserved across transfer`)

console.log(`\n[4] Round-trip: user → user2, verify no drift...`)
const user2 = genKeypair()
const un = await getNonce(node, user.address, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce: un, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(2000 + FEE) },
    { owner: user2.address, delta: 2000 },
  ],
}, nexusDir, user)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user2.address, nexusDir)) > 0,
  'user2 funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h4 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const mb4 = await getBalance(node, minerAddr, nexusDir)
const ub4 = await getBalance(node, user.address, nexusDir)
const u2b4 = await getBalance(node, user2.address, nexusDir)
const total4 = mb4 + ub4 + u2b4
const coinbasesSince3 = (h4 - h3) * REWARD
const expectedTotal4 = total3 + coinbasesSince3
console.log(`  height=${h4} total=${total4} expected=${expectedTotal4}`)

if (total4 !== expectedTotal4) {
  console.error(`  ✗ off by ${total4 - expectedTotal4} — drift detected`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ supply conserved after round-trip`)

console.log(`\n✓ supply-conservation smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
