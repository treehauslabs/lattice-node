// Deploy child chain under live mining: verify dynamic chain registration
// works mid-operation. The new chain must appear in chainInfo, start mining,
// and accept transactions.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, chainOf, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('deploy-under-load')
const [{ port, rpcPort }] = allocPorts(1, { seed: 73 })

console.log('=== deploy-under-load smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
const initialChains = info.chains.length

console.log(`\n[1] Start mining on Nexus...`)
await startMining(node, nexusDir)
await waitForHeight(node, nexusDir, 3, 120_000)

console.log(`\n[2] Deploy child chain while mining is active...`)
const CHILD = 'HotDeploy'
await deployChild(node, {
  directory: CHILD,
  parentDirectory: nexusDir,
  initialReward: 256,
})

const postDeploy = await chainInfo(node)
const childEntry = chainOf(postDeploy, CHILD)
if (!childEntry) {
  console.error(`  ✗ ${CHILD} not found in chainInfo after deploy`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ ${CHILD} visible in chainInfo (height=${childEntry.height})`)
console.log(`  total chains: ${postDeploy.chains.length} (was ${initialChains})`)

console.log(`\n[3] Wait for child chain to mine blocks...`)
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 5, 120_000)
const childHeight = chainOf(await chainInfo(node), CHILD).height
console.log(`  ✓ ${CHILD} mining at height ${childHeight}`)

console.log(`\n[4] Submit tx on the new child chain...`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const user = genKeypair()
const nonce = await getNonce(node, minerAddr, CHILD)
const r = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -501 },
    { owner: user.address, delta: 500 },
  ],
}, CHILD, minerKP)
if (!r.ok) throw new Error(`tx on new child failed: ${JSON.stringify(r.submit)}`)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, CHILD)) >= 500,
  'user funded on child', { timeoutMs: 120_000 })
console.log(`  ✓ tx confirmed on dynamically deployed chain`)

console.log(`\n[5] Deploy a second child chain...`)
const CHILD2 = 'HotDeploy2'
await deployChild(node, {
  directory: CHILD2,
  parentDirectory: nexusDir,
  initialReward: 128,
})
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD2, 3, 120_000)
const finalInfo = await chainInfo(node)
console.log(`  chains: ${finalInfo.chains.map(c => `${c.directory}@${c.height}`).join(', ')}`)
console.log(`  ✓ second child deployed and mining`)

console.log(`\n✓ deploy-under-load smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
