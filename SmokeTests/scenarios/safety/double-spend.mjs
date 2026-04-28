// Double-spend rejection. Fund a user with N coins, then submit two txs at
// the same nonce sending to two different recipients, each draining most of
// the user's balance. Resume mining and assert:
//   - exactly one of the two recipients receives funds
//   - the user's balance reflects exactly one tx applied (not zero, not both)
// Catches the worst class of consensus bug: applying two conflicting state
// transitions from the same signer.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('double-spend')
const [{ port, rpcPort }] = allocPorts(1, { seed: 25 })

console.log('=== double-spend smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await sleep(2000)

const user = genKeypair()
const recipA = genKeypair()
const recipB = genKeypair()
console.log(`  user=${user.address}`)
console.log(`  recipA=${recipA.address}`)
console.log(`  recipB=${recipB.address}`)

const FUND = 5000
async function stageFund() {
  await stopMining(node, nexusDir)
  await awaitMiningQuiesced(node, nexusDir)
  for (let attempt = 0; attempt < 6; attempt++) {
    const base = await getNonce(node, minerAddr, nexusDir)
    for (const n of [base, base + 1]) {
      const r = await submitTx(node, {
        chainPath: [nexusDir], nonce: n, signers: [minerAddr], fee: 1,
        accountActions: [
          { owner: minerAddr, delta: -(FUND + 1) },
          { owner: user.address, delta: FUND },
        ],
      }, nexusDir, minerKP)
      if (r.ok) return
      const msg = JSON.stringify(r.submit)
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error('fund failed after retries')
}

await stageFund()
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= FUND,
  'user funded', { timeoutMs: 60_000 })
const userStart = await getBalance(node, user.address, nexusDir)
console.log(`  user funded with ${userStart}`)

await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const userNonce = await getNonce(node, user.address, nexusDir)
const SEND_A = 4000
const SEND_B = 3500
const FEE = 1

console.log(`\n[2] Submit two txs at nonce=${userNonce} (one to A=${SEND_A}, one to B=${SEND_B})...`)
const r1 = await submitTx(node, {
  chainPath: [nexusDir], nonce: userNonce, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(SEND_A + FEE) },
    { owner: recipA.address, delta: SEND_A },
  ],
}, nexusDir, user)
console.log(`  tx→A submit ok=${r1.ok}: ${JSON.stringify(r1.submit).slice(0, 120)}`)

const r2 = await submitTx(node, {
  chainPath: [nexusDir], nonce: userNonce, signers: [user.address], fee: FEE,
  accountActions: [
    { owner: user.address, delta: -(SEND_B + FEE) },
    { owner: recipB.address, delta: SEND_B },
  ],
}, nexusDir, user)
console.log(`  tx→B submit ok=${r2.ok}: ${JSON.stringify(r2.submit).slice(0, 120)}`)

if (!r1.ok && !r2.ok) {
  console.error(`  ✗ both submissions rejected — expected at least one to be accepted`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`\n[3] Resume mining; wait for next block to absorb at least one tx...`)
const startInfo = await chainInfo(node)
const startHeight = startInfo.chains.find((c) => c.directory === nexusDir).height
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, startHeight + 2, 30_000)

const balA = await getBalance(node, recipA.address, nexusDir)
const balB = await getBalance(node, recipB.address, nexusDir)
const balU = await getBalance(node, user.address, nexusDir)
console.log(`  balances: A=${balA} B=${balB} user=${balU} (was ${userStart})`)

const aFunded = balA === SEND_A
const bFunded = balB === SEND_B
if (aFunded && bFunded) {
  console.error(`  ✗ BOTH recipients funded — double-spend not prevented`)
  node.stop(); await sleep(500); process.exit(1)
}
if (!aFunded && !bFunded) {
  console.error(`  ✗ NEITHER recipient funded — both txs got dropped`)
  node.stop(); await sleep(500); process.exit(1)
}
const winner = aFunded ? 'A' : 'B'
const winnerAmount = aFunded ? SEND_A : SEND_B
const expectedUser = userStart - winnerAmount - FEE
if (balU !== expectedUser) {
  console.error(`  ✗ user balance ${balU} != expected ${expectedUser} (winner=${winner})`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`  ✓ exactly one tx applied (winner=${winner}); user debited by exactly one amount+fee`)

const finalNonce = await getNonce(node, user.address, nexusDir)
if (finalNonce !== userNonce + 1) {
  console.error(`  ✗ user nonce ${finalNonce} != ${userNonce + 1} (one tx should advance nonce by 1)`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ nonce advanced by exactly 1 (${userNonce} → ${finalNonce})`)

console.log(`\n✓ double-spend smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
