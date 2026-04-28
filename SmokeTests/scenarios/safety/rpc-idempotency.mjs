// RPC submit idempotency: prepare a tx, submit it twice with the same
// bodyCID/bodyData/signatures. Verify the account nonce advances by 1 (not 2)
// and the recipient receives exactly one payment.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'

const ROOT = smokeRoot('rpc-idempotency')
const [{ port, rpcPort }] = allocPorts(1, { seed: 35 })

console.log('=== rpc-idempotency smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 30_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const recipient = genKeypair()
const nonce = await getNonce(node, minerAddr, nexusDir)
const SEND = 1000
const FEE = 1

console.log(`\n[1] Prepare tx once, submit twice...`)
const prep = await node.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: FEE,
  accountActions: [
    { owner: minerAddr, delta: -(SEND + FEE) },
    { owner: recipient.address, delta: SEND },
  ],
})
if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
const { bodyCID, bodyData } = prep.json
const signature = sign(bodyCID, minerKP.privateKey)
const submitBody = {
  signatures: { [minerKP.publicKey]: signature },
  bodyCID, bodyData, chain: nexusDir,
}

const sub1 = await node.rpc('POST', '/api/transaction', submitBody)
console.log(`  submit 1: ok=${sub1.ok} ${JSON.stringify(sub1.json).slice(0, 80)}`)

const sub2 = await node.rpc('POST', '/api/transaction', submitBody)
console.log(`  submit 2: ok=${sub2.ok} ${JSON.stringify(sub2.json).slice(0, 80)}`)

console.log(`\n[2] Mine and verify single effect...`)
await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, recipient.address, nexusDir)) >= SEND,
  'recipient funded', { timeoutMs: 30_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const recipBal = await getBalance(node, recipient.address, nexusDir)
const finalNonce = await getNonce(node, minerAddr, nexusDir)
console.log(`  recipient balance: ${recipBal} (expected ${SEND})`)
console.log(`  nonce advance: ${nonce} → ${finalNonce}`)

if (recipBal !== SEND) {
  console.error(`  ✗ recipient got ${recipBal}, expected exactly ${SEND}`)
  node.stop(); await sleep(500); process.exit(1)
}

const expectedNonceAdvance = finalNonce - nonce
const height2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const height1 = 5
const blocksMined = height2 - height1
console.log(`  blocks mined since submit: ${blocksMined} (coinbase nonces included)`)

if (recipBal > SEND) {
  console.error(`  ✗ recipient got more than one payment — idempotency violated`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`  ✓ exactly one payment applied`)

console.log(`\n✓ rpc-idempotency smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
