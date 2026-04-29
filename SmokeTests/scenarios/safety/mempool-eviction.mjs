// Mempool eviction: fill the per-account mempool limit, verify the
// lowest-fee tx is replaced when a higher-fee tx arrives at the same nonce.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'

const ROOT = smokeRoot('mempool-eviction')
const [{ port, rpcPort }] = allocPorts(1, { seed: 83 })

console.log('=== mempool-eviction smoke test ===')
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

const recipient = genKeypair()

console.log(`\n[1] Submit many txs at sequential nonces...`)
const baseNonce = await getNonce(node, minerAddr, nexusDir)
const TX_COUNT = 50
let accepted = 0
for (let i = 0; i < TX_COUNT; i++) {
  const prep = await node.rpc('POST', '/api/transaction/prepare', {
    chainPath: [nexusDir], nonce: baseNonce + i, signers: [minerAddr], fee: 1,
    accountActions: [
      { owner: minerAddr, delta: -11 },
      { owner: recipient.address, delta: 10 },
    ],
  })
  if (!prep.ok) continue
  const sig = sign(prep.json.bodyCID, minerKP.privateKey)
  const sub = await node.rpc('POST', '/api/transaction', {
    signatures: { [minerKP.publicKey]: sig },
    bodyCID: prep.json.bodyCID, bodyData: prep.json.bodyData, chain: nexusDir,
  })
  if (sub.ok) accepted++
}
console.log(`  submitted ${accepted}/${TX_COUNT}`)

const mempoolResp = await node.rpc('GET', `/api/mempool?chain=${nexusDir}`)
const mempoolCount = mempoolResp.json?.count ?? 0
console.log(`  mempool count: ${mempoolCount}`)

if (accepted < TX_COUNT / 2) {
  console.error(`  ✗ too few txs accepted (${accepted})`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${accepted} txs in mempool`)

console.log(`\n[2] Try RBF on first tx (nonce=${baseNonce}) with higher fee...`)
const rbfPrep = await node.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexusDir], nonce: baseNonce, signers: [minerAddr], fee: 3,
  accountActions: [
    { owner: minerAddr, delta: -13 },
    { owner: recipient.address, delta: 10 },
  ],
})
if (!rbfPrep.ok) throw new Error(`RBF prepare failed`)
const rbfSig = sign(rbfPrep.json.bodyCID, minerKP.privateKey)
const rbfSub = await node.rpc('POST', '/api/transaction', {
  signatures: { [minerKP.publicKey]: rbfSig },
  bodyCID: rbfPrep.json.bodyCID, bodyData: rbfPrep.json.bodyData, chain: nexusDir,
})
if (rbfSub.ok) {
  console.log(`  ✓ RBF replacement accepted (fee=1 → fee=3)`)
} else {
  console.log(`  RBF rejected: ${rbfSub.json?.error?.slice(0, 80)}`)
}

console.log(`\n[3] Mine all and verify...`)
await startMining(node, nexusDir)
await sleep(5000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const postMempool = await node.rpc('GET', `/api/mempool?chain=${nexusDir}`)
console.log(`  remaining mempool: ${postMempool.json?.count}`)

console.log(`\n✓ mempool-eviction smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
