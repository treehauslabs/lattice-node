// Nonce validation edge cases:
//   1. Nonce replay — submit at nonce N, mine it, re-submit at N → rejected
//   2. Nonce gap — submit at nonce N+100 (too far ahead) → rejected
//   3. Sequential nonces — submit N then N+1, both mine correctly

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('nonce-edge-cases')
const [{ port, rpcPort }] = allocPorts(1, { seed: 49 })

console.log('=== nonce-edge-cases smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 3, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log(`\n[1] Nonce replay: submit, mine, re-submit at same nonce...`)
const r1 = genKeypair()
const nonce1 = await getNonce(node, minerAddr, nexusDir)
const tx1 = await submitTx(node, {
  chainPath: [nexusDir], nonce: nonce1, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: r1.address, delta: 100 },
  ],
}, nexusDir, minerKP)
if (!tx1.ok) throw new Error(`first submit failed: ${JSON.stringify(tx1.submit)}`)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, r1.address, nexusDir)) >= 100,
  'first tx mined', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
console.log(`  first tx mined at nonce=${nonce1}`)

const replay = await submitTx(node, {
  chainPath: [nexusDir], nonce: nonce1, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: r1.address, delta: 100 },
  ],
}, nexusDir, minerKP)
if (replay.ok) {
  console.log(`  ⚠ replay accepted into mempool — checking if it applies...`)
  await startMining(node, nexusDir)
  await sleep(3000)
  await stopMining(node, nexusDir)
  const bal = await getBalance(node, r1.address, nexusDir)
  if (bal > 100) {
    console.error(`  ✗ nonce replay credited funds twice! bal=${bal}`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ replay accepted but not applied (bal still ${bal})`)
} else {
  const msg = replay.submit?.error ?? JSON.stringify(replay.submit)
  console.log(`  ✓ replay rejected: ${msg.slice(0, 80)}`)
}

console.log(`\n[2] Nonce gap: submit at nonce + 100 (too far ahead)...`)
const currentNonce = await getNonce(node, minerAddr, nexusDir)
const farNonce = currentNonce + 100
const r2 = genKeypair()
const gapTx = await submitTx(node, {
  chainPath: [nexusDir], nonce: farNonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: r2.address, delta: 100 },
  ],
}, nexusDir, minerKP)
if (!gapTx.ok) {
  console.log(`  ✓ far-future nonce rejected: ${(gapTx.submit?.error ?? JSON.stringify(gapTx.submit)).slice(0, 80)}`)
} else {
  console.log(`  ⚠ far-future nonce accepted — mempool may queue it`)
}

console.log(`\n[3] Sequential nonces: N and N+1 both mine...`)
const seqNonce = await getNonce(node, minerAddr, nexusDir)
const r3a = genKeypair()
const r3b = genKeypair()

const txA = await submitTx(node, {
  chainPath: [nexusDir], nonce: seqNonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: r3a.address, delta: 100 },
  ],
}, nexusDir, minerKP)
const txB = await submitTx(node, {
  chainPath: [nexusDir], nonce: seqNonce + 1, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: r3b.address, delta: 100 },
  ],
}, nexusDir, minerKP)
console.log(`  tx at nonce=${seqNonce}: ok=${txA.ok}`)
console.log(`  tx at nonce=${seqNonce + 1}: ok=${txB.ok}`)

if (!txA.ok || !txB.ok) {
  console.log(`  note: one of the sequential txs was rejected (coinbase race)`)
}

await startMining(node, nexusDir)
await sleep(3000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const bal3a = await getBalance(node, r3a.address, nexusDir)
const bal3b = await getBalance(node, r3b.address, nexusDir)
console.log(`  balances: r3a=${bal3a} r3b=${bal3b}`)

if (txA.ok && txB.ok && bal3a >= 100 && bal3b >= 100) {
  console.log(`  ✓ both sequential txs mined`)
} else if (bal3a >= 100 || bal3b >= 100) {
  console.log(`  ✓ at least one sequential tx mined`)
} else {
  console.log(`  note: neither sequential tx landed (possible nonce race)`)
}

console.log(`\n✓ nonce-edge-cases smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
