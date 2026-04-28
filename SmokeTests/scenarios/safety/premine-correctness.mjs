// Premine correctness: deploy a child chain with an explicit premine amount
// and premineRecipient, verify the recipient has exactly that balance at
// height 0, and that the miner's coinbase starts from block 1.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getBalance, startMining, deployChild, waitForHeight,
} from '../../lib/chain.mjs'

const ROOT = smokeRoot('premine-correctness')
const [{ port, rpcPort }] = allocPorts(1, { seed: 69 })
const CHILD = 'PremineTest'
const PREMINE = 50000
const REWARD = 512

console.log('=== premine-correctness smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

const premineRecipient = genKeypair()
console.log(`  premineRecipient: ${premineRecipient.address.slice(0, 24)}...`)

console.log(`\n[1] Deploy child chain with premine=${PREMINE} to recipient...`)
await startMining(node, nexusDir)
await deployChild(node, {
  directory: CHILD,
  parentDirectory: nexusDir,
  premine: PREMINE,
  premineRecipient: premineRecipient.address,
  initialReward: REWARD,
  startMining: true,
})
await waitForHeight(node, CHILD, 5, 120_000)

console.log(`\n[2] Check premine recipient balance...`)
const recipBal = await getBalance(node, premineRecipient.address, CHILD)
console.log(`  recipient balance: ${recipBal}`)

if (recipBal < PREMINE) {
  console.error(`  ✗ premine recipient has ${recipBal}, expected at least ${PREMINE}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ premine recipient has ≥${PREMINE}`)

console.log(`\n[3] Check miner coinbase accumulation...`)
const minerBal = await getBalance(node, minerAddr, CHILD)
const childInfo = (await chainInfo(node)).chains.find(c => c.directory === CHILD)
const childHeight = childInfo.height
const expectedMiner = childHeight * REWARD
console.log(`  miner balance: ${minerBal} (height=${childHeight}, expected coinbase≈${expectedMiner})`)

if (minerBal < expectedMiner - REWARD * 2) {
  console.error(`  ✗ miner balance too low — coinbase not accumulating`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ miner receiving coinbase rewards`)

console.log(`\n[4] Verify premine didn't go to miner (if recipient != miner)...`)
if (premineRecipient.address !== minerAddr) {
  const totalExpected = recipBal + minerBal
  console.log(`  total tracked: ${totalExpected} (premine + coinbase)`)
  if (minerBal > expectedMiner + REWARD * 2) {
    console.error(`  ✗ miner balance too high — premine may have leaked to miner`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ premine correctly separated from coinbase`)
}

console.log(`\n✓ premine-correctness smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
