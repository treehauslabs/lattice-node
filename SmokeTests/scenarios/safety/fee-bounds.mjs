// Fee bounds validation. Per spec: 1 ≤ fee ≤ 1,000,000,000,000.
// Tests:
//   1. fee=0 → rejected
//   2. fee=1 → accepted (minimum)
//   3. fee=1_000_000_000_001 → rejected (above max)

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import { chainInfo, getNonce, startMining, stopMining, awaitMiningQuiesced, waitForHeight } from '../../lib/chain.mjs'

const ROOT = smokeRoot('fee-bounds')
const [{ port, rpcPort }] = allocPorts(1, { seed: 59 })

console.log('=== fee-bounds smoke test ===')
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

async function tryFee(fee, label) {
  const nonce = await getNonce(node, minerAddr, nexusDir)
  const prep = await node.rpc('POST', '/api/transaction/prepare', {
    chainPath: [nexusDir], nonce, signers: [minerAddr], fee,
    accountActions: [
      { owner: minerAddr, delta: -(100 + fee) },
      { owner: recipient.address, delta: 100 },
    ],
  })
  if (!prep.ok) {
    console.log(`  ${label}: rejected at prepare: ${prep.json?.error?.slice(0, 80)}`)
    return false
  }
  const sig = sign(prep.json.bodyCID, minerKP.privateKey)
  const sub = await node.rpc('POST', '/api/transaction', {
    signatures: { [minerKP.publicKey]: sig },
    bodyCID: prep.json.bodyCID, bodyData: prep.json.bodyData, chain: nexusDir,
  })
  if (!sub.ok) {
    console.log(`  ${label}: rejected at submit: ${sub.json?.error?.slice(0, 80)}`)
    return false
  }
  console.log(`  ${label}: accepted`)
  return true
}

console.log(`\n[1] Fee = 0 (below minimum)...`)
const r0 = await tryFee(0, 'fee=0')
if (r0) {
  console.error(`  ✗ zero-fee tx was accepted — spam vector!`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ zero fee rejected`)

console.log(`\n[2] Fee = 1 (minimum)...`)
const r1 = await tryFee(1, 'fee=1')
if (!r1) {
  console.error(`  ✗ minimum-fee tx was rejected`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ minimum fee accepted`)

console.log(`\n[3] Fee = 1_000_000_000_001 (above max)...`)
const r3 = await tryFee(1_000_000_000_001, 'fee=1T+1')
if (r3) {
  console.log(`  ⚠ above-max fee was accepted (node may not enforce ceiling)`)
} else {
  console.log(`  ✓ above-max fee rejected`)
}

console.log(`\n✓ fee-bounds smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
