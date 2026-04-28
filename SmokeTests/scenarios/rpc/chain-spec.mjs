// Chain spec + deployment test. Verifies:
//   1. /api/chain/spec returns expected Nexus parameters
//   2. Deploying a child chain with custom config succeeds
//   3. The deployed child's spec matches what was requested
//   4. Child chain appears in /api/chain/info

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { chainInfo, deployChild, startMining, stopMining, waitForHeight } from '../../lib/chain.mjs'

const ROOT = smokeRoot('chain-spec')
const [{ port, rpcPort }] = allocPorts(1, { seed: 55 })

console.log('=== chain-spec smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()

const info = await chainInfo(node)
const nexusDir = info.nexus
console.log(`  nexus=${nexusDir} genesis=${info.genesisHash.slice(0, 24)}...`)

console.log(`\n[1] Query Nexus chain spec...`)
const specResp = await node.rpc('GET', `/api/chain/spec?chain=${nexusDir}`)
if (!specResp.ok) throw new Error(`chain/spec failed: ${JSON.stringify(specResp.json)}`)
const spec = specResp.json
console.log(`  directory: ${spec.directory}`)
console.log(`  targetBlockTime: ${spec.targetBlockTime}`)
console.log(`  initialReward: ${spec.initialReward}`)
console.log(`  halvingInterval: ${spec.halvingInterval}`)
console.log(`  maxTransactionsPerBlock: ${spec.maxTransactionsPerBlock}`)

if (spec.directory !== nexusDir) {
  console.error(`  ✗ spec directory "${spec.directory}" != "${nexusDir}"`)
  node.stop(); await sleep(500); process.exit(1)
}
if (typeof spec.initialReward !== 'number' || spec.initialReward <= 0) {
  console.error(`  ✗ invalid initialReward: ${spec.initialReward}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ Nexus spec is well-formed`)

console.log(`\n[2] Deploy child chain with custom parameters...`)
await startMining(node, nexusDir)
const CHILD = 'CustomChild'
const customOpts = {
  directory: CHILD,
  parentDirectory: nexusDir,
  targetBlockTime: 2000,
  initialReward: 512,
  halvingInterval: 100000,
  maxTransactionsPerBlock: 50,
  premine: 0,
}
await deployChild(node, customOpts)
await waitForHeight(node, CHILD, 3, 120_000)
console.log(`  ✓ child chain deployed and mining`)

console.log(`\n[3] Verify child spec matches requested params...`)
const childSpec = await node.rpc('GET', `/api/chain/spec?chain=${CHILD}`)
if (!childSpec.ok) throw new Error(`child spec failed: ${JSON.stringify(childSpec.json)}`)
const cs = childSpec.json
console.log(`  child spec: reward=${cs.initialReward} halving=${cs.halvingInterval} maxTx=${cs.maxTransactionsPerBlock}`)

if (cs.initialReward !== customOpts.initialReward) {
  console.error(`  ✗ reward mismatch: ${cs.initialReward} != ${customOpts.initialReward}`)
  node.stop(); await sleep(500); process.exit(1)
}
if (cs.halvingInterval !== customOpts.halvingInterval) {
  console.error(`  ✗ halving mismatch: ${cs.halvingInterval} != ${customOpts.halvingInterval}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ child spec matches requested parameters`)

console.log(`\n[4] Child appears in chain/info...`)
const postInfo = await chainInfo(node)
const childEntry = postInfo.chains.find(c => c.directory === CHILD)
if (!childEntry) {
  console.error(`  ✗ child "${CHILD}" not found in chain/info`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ${CHILD}@${childEntry.height} mining=${childEntry.mining}`)
if (childEntry.parentDirectory !== nexusDir) {
  console.error(`  ✗ parent mismatch: ${childEntry.parentDirectory} != ${nexusDir}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ child listed with correct parent`)

console.log(`\n✓ chain-spec smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
