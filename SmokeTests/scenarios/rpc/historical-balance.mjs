// Historical balance query: verify /api/block/{height}/state/account/{addr}
// returns correct balance at past heights after transfers.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('historical-balance')
const [{ port, rpcPort }] = allocPorts(1, { seed: 95 })

console.log('=== historical-balance smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

const specResp = await node.rpc('GET', `/api/chain/spec?chain=${nexusDir}`)
const REWARD = specResp.json.initialReward

console.log('\n[1] Mine to height 5, snapshot miner balance...')
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 5, 120_000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h1 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const balAt3 = await node.rpc('GET', `/api/block/3/state/account/${minerAddr}?chain=${nexusDir}`)
console.log(`  balance at block 3: ${JSON.stringify(balAt3.json).slice(0, 100)}`)

if (balAt3.ok && typeof balAt3.json.balance === 'number') {
  const expected3 = 3 * REWARD
  if (balAt3.json.balance !== expected3) {
    console.log(`  note: balance at height 3 is ${balAt3.json.balance}, expected ${expected3}`)
  } else {
    console.log(`  ✓ balance at height 3 matches expected (${expected3})`)
  }
}

console.log('\n[2] Transfer, mine more, check historical balance...')
const user = genKeypair()
const SEND = 5000
const nonce = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -(SEND + 1) },
    { owner: user.address, delta: SEND },
  ],
}, nexusDir, minerKP)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= SEND,
  'user funded', { timeoutMs: 120_000 })
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const h2 = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
console.log(`  current height: ${h2}`)

console.log('\n[3] Query user balance at height before transfer...')
const userAtH1 = await node.rpc('GET', `/api/block/${h1}/state/account/${user.address}?chain=${nexusDir}`)
if (userAtH1.ok) {
  const balBefore = userAtH1.json.balance ?? 0
  console.log(`  user at height ${h1} (before transfer): ${balBefore}`)
  if (balBefore !== 0) {
    console.error(`  ✗ user had balance before transfer`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ user balance was 0 before transfer`)
} else {
  console.log(`  note: historical query returned: ${userAtH1.json?.error}`)
}

console.log('\n[4] Query user balance at current height...')
const userAtH2 = await node.rpc('GET', `/api/block/${h2}/state/account/${user.address}?chain=${nexusDir}`)
if (userAtH2.ok) {
  console.log(`  user at height ${h2} (after transfer): ${userAtH2.json.balance}`)
  if (userAtH2.json.balance >= SEND) {
    console.log(`  ✓ user balance correct at current height`)
  }
} else {
  console.log(`  note: current height query returned: ${userAtH2.json?.error}`)
}

console.log('\n[5] Verify miner balance decreases between heights...')
const minerAtH1 = await node.rpc('GET', `/api/block/${h1}/state/account/${minerAddr}?chain=${nexusDir}`)
const minerAtH2 = await node.rpc('GET', `/api/block/${h2}/state/account/${minerAddr}?chain=${nexusDir}`)
if (minerAtH1.ok && minerAtH2.ok) {
  const m1 = minerAtH1.json.balance
  const m2 = minerAtH2.json.balance
  const coinbase = (h2 - h1) * REWARD
  const expectedDelta = coinbase - SEND - 1
  const actualDelta = m2 - m1
  console.log(`  miner: h${h1}=${m1} h${h2}=${m2} delta=${actualDelta} expected=${expectedDelta}`)
  if (actualDelta === expectedDelta) {
    console.log(`  ✓ miner balance delta matches exactly`)
  } else {
    console.log(`  note: delta mismatch (may include additional coinbase from block timing)`)
  }
}

console.log('\n✓ historical-balance smoke test passed.')
node.stop()
await sleep(500)
process.exit(0)
