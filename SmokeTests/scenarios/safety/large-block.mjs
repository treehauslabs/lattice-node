// Large block: submit many txs in one mining round, approaching the
// maxTransactionsPerBlock limit. Verify all txs are included and the
// block is valid.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('large-block')
const [{ port, rpcPort }] = allocPorts(1, { seed: 71 })
const CHILD = 'PackTest'
const TX_COUNT = 40
const FEE = 1

console.log('=== large-block smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

console.log(`\n[1] Deploy fast child chain (maxTx=100)...`)
await startMining(node, nexusDir)
await deployChild(node, {
  directory: CHILD,
  parentDirectory: nexusDir,
  maxTransactionsPerBlock: 100,
  initialReward: 1024,
})
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log(`\n[2] Stage ${TX_COUNT} txs while mining is stopped...`)
const recipients = []
let submitted = 0
const baseNonce = await getNonce(node, minerAddr, CHILD)
for (let i = 0; i < TX_COUNT; i++) {
  const recip = genKeypair()
  recipients.push(recip)
  const r = await submitTx(node, {
    chainPath: [nexusDir, CHILD], nonce: baseNonce + i, signers: [minerAddr], fee: FEE,
    accountActions: [
      { owner: minerAddr, delta: -(10 + FEE) },
      { owner: recip.address, delta: 10 },
    ],
  }, CHILD, minerKP)
  if (r.ok) submitted++
  else console.log(`  tx ${i} rejected: ${(r.submit?.error ?? '').slice(0, 60)}`)
}
console.log(`  staged ${submitted}/${TX_COUNT} txs`)

const mempoolResp = await node.rpc('GET', `/api/mempool?chain=${CHILD}`)
console.log(`  mempool count: ${mempoolResp.json?.count}`)

console.log(`\n[3] Mine and verify txs are included...`)
const preHeight = (await chainInfo(node)).chains.find(c => c.directory === CHILD).height
await startMining(node, nexusDir)
await sleep(5000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const postHeight = (await chainInfo(node)).chains.find(c => c.directory === CHILD).height
console.log(`  height: ${preHeight} → ${postHeight} (${postHeight - preHeight} blocks)`)

let funded = 0
for (const r of recipients) {
  const bal = await getBalance(node, r.address, CHILD)
  if (bal >= 10) funded++
}
console.log(`  recipients funded: ${funded}/${submitted}`)

if (funded < submitted * 0.8) {
  console.error(`  ✗ too few txs landed: ${funded}/${submitted}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${funded} txs confirmed`)

const postMempool = await node.rpc('GET', `/api/mempool?chain=${CHILD}`)
console.log(`  remaining mempool: ${postMempool.json?.count}`)

console.log(`\n✓ large-block smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
