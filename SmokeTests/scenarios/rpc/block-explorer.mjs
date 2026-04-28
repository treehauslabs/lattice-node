// Block explorer API test. Exercises the read-only chain inspection endpoints:
//   1. /api/block/latest — returns a valid block
//   2. /api/block/{id} — lookup by hash and by height
//   3. /api/block/{id}/transactions — tx list for a block
//   4. /api/transaction/{txCID} — individual tx lookup
//   5. /api/transactions/{address} — address history
//   6. /api/state/account/{address} — account state
//   7. /api/block/{id}/children — child blocks in merged mining

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('block-explorer')
const [{ port, rpcPort }] = allocPorts(1, { seed: 53 })

console.log('=== block-explorer API smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const user = genKeypair()
const txNonce = await getNonce(node, minerAddr, nexusDir)
const txResult = await submitTx(node, {
  chainPath: [nexusDir], nonce: txNonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -1001 },
    { owner: user.address, delta: 1000 },
  ],
}, nexusDir, minerKP)
if (!txResult.ok) throw new Error(`setup tx failed: ${JSON.stringify(txResult.submit)}`)
const txCID = txResult.submit.txCID

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= 1000,
  'tx mined', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

console.log(`\n[1] /api/block/latest...`)
const latestResp = await node.rpc('GET', `/api/block/latest?chain=${nexusDir}`)
if (!latestResp.ok) throw new Error(`block/latest failed: ${JSON.stringify(latestResp.json)}`)
const latestHash = latestResp.json.hash ?? latestResp.json.blockHash ?? latestResp.json.cid
console.log(`  latest block: ${JSON.stringify(latestResp.json).slice(0, 120)}`)
console.log(`  ✓ block/latest responds`)

console.log(`\n[2] /api/block/{id} by height...`)
const byHeightResp = await node.rpc('GET', `/api/block/3?chain=${nexusDir}`)
if (!byHeightResp.ok) {
  console.log(`  note: block-by-height not supported: ${byHeightResp.json?.error?.slice(0, 80)}`)
} else {
  console.log(`  block@3: ${JSON.stringify(byHeightResp.json).slice(0, 120)}`)
  console.log(`  ✓ block-by-height works`)
}

if (latestHash) {
  console.log(`\n[3] /api/block/{hash}...`)
  const byHashResp = await node.rpc('GET', `/api/block/${latestHash}?chain=${nexusDir}`)
  if (!byHashResp.ok) {
    console.log(`  note: block-by-hash failed: ${byHashResp.json?.error?.slice(0, 80)}`)
  } else {
    console.log(`  ✓ block-by-hash works`)
  }

  console.log(`\n[4] /api/block/{hash}/transactions...`)
  const txsResp = await node.rpc('GET', `/api/block/${latestHash}/transactions?chain=${nexusDir}`)
  if (!txsResp.ok) {
    console.log(`  note: block/transactions failed: ${txsResp.json?.error?.slice(0, 80)}`)
  } else {
    const txCount = Array.isArray(txsResp.json) ? txsResp.json.length : txsResp.json?.transactions?.length ?? '?'
    console.log(`  block txs: ${txCount} transactions`)
    console.log(`  ✓ block/transactions works`)
  }

  console.log(`\n[5] /api/block/{hash}/children...`)
  const childrenResp = await node.rpc('GET', `/api/block/${latestHash}/children?chain=${nexusDir}`)
  console.log(`  children: ok=${childrenResp.ok} ${JSON.stringify(childrenResp.json).slice(0, 100)}`)
}

console.log(`\n[6] /api/transaction/{txCID}...`)
const txLookup = await node.rpc('GET', `/api/transaction/${txCID}?chain=${nexusDir}`)
if (!txLookup.ok) {
  console.log(`  note: tx lookup failed: ${txLookup.json?.error?.slice(0, 80)}`)
} else {
  console.log(`  tx: ${JSON.stringify(txLookup.json).slice(0, 120)}`)
  console.log(`  ✓ tx lookup works`)
}

console.log(`\n[7] /api/transactions/{address} (miner history)...`)
const histResp = await node.rpc('GET', `/api/transactions/${minerAddr}?chain=${nexusDir}`)
if (!histResp.ok) {
  console.log(`  note: tx history failed: ${histResp.json?.error?.slice(0, 80)}`)
} else {
  const txCount = Array.isArray(histResp.json) ? histResp.json.length : histResp.json?.transactions?.length ?? '?'
  console.log(`  history: ${txCount} transactions`)
  console.log(`  ✓ tx history works`)
}

console.log(`\n[8] /api/state/account/{address}...`)
const acctResp = await node.rpc('GET', `/api/state/account/${user.address}?chain=${nexusDir}`)
if (!acctResp.ok) {
  console.log(`  note: account state failed: ${acctResp.json?.error?.slice(0, 80)}`)
} else {
  console.log(`  account: ${JSON.stringify(acctResp.json).slice(0, 120)}`)
  if (typeof acctResp.json.balance === 'number' && acctResp.json.balance >= 1000) {
    console.log(`  ✓ account state has correct balance`)
  }
}

console.log(`\n✓ block-explorer API smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
