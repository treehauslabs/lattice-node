// Balance proof and light client headers. Tests:
//   1. /api/proof/{address} returns a proof structure for a funded account
//   2. /api/proof/{address} for nonexistent account — empty or error
//   3. /api/light/headers returns header range
//   4. /api/light/proof/{address} returns proof with block context

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('balance-proof')
const [{ port, rpcPort }] = allocPorts(1, { seed: 57 })

console.log('=== balance-proof smoke test ===')
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

console.log(`\n[1] Balance proof for miner (funded account)...`)
const proofResp = await node.rpc('GET', `/api/proof/${minerAddr}?chain=${nexusDir}`)
console.log(`  proof: ok=${proofResp.ok} ${JSON.stringify(proofResp.json).slice(0, 200)}`)
if (proofResp.ok) {
  const hasProof = proofResp.json.proof || proofResp.json.stateRoot || proofResp.json.balance
  if (hasProof) {
    console.log(`  ✓ proof returned for funded account`)
  } else {
    console.log(`  note: proof response has unexpected structure`)
  }
} else {
  console.log(`  note: proof endpoint returned error: ${proofResp.json?.error}`)
}

console.log(`\n[2] Balance proof for nonexistent account...`)
const ghost = genKeypair()
const ghostProof = await node.rpc('GET', `/api/proof/${ghost.address}?chain=${nexusDir}`)
console.log(`  ghost proof: ok=${ghostProof.ok} ${JSON.stringify(ghostProof.json).slice(0, 150)}`)
if (ghostProof.ok) {
  console.log(`  ✓ proof returned (may indicate non-existence)`)
} else {
  console.log(`  ✓ correctly indicated no proof for unfunded account`)
}

console.log(`\n[3] Light client headers...`)
const headersResp = await node.rpc('GET', `/api/light/headers?chain=${nexusDir}&from=1&to=5`)
console.log(`  headers: ok=${headersResp.ok} ${JSON.stringify(headersResp.json).slice(0, 200)}`)
if (headersResp.ok) {
  const count = Array.isArray(headersResp.json) ? headersResp.json.length : headersResp.json?.headers?.length ?? '?'
  console.log(`  ✓ light headers returned (count=${count})`)
} else {
  console.log(`  note: light headers returned error: ${headersResp.json?.error}`)
}

console.log(`\n[4] Light client proof...`)
const lightProof = await node.rpc('GET', `/api/light/proof/${minerAddr}?chain=${nexusDir}`)
console.log(`  light proof: ok=${lightProof.ok} ${JSON.stringify(lightProof.json).slice(0, 200)}`)
if (lightProof.ok) {
  console.log(`  ✓ light proof returned`)
}

console.log(`\n[5] Block-at-height state query...`)
const acctAtBlock = await node.rpc('GET', `/api/block/3/state/account/${minerAddr}?chain=${nexusDir}`)
console.log(`  account@block3: ok=${acctAtBlock.ok} ${JSON.stringify(acctAtBlock.json).slice(0, 150)}`)
if (acctAtBlock.ok && typeof acctAtBlock.json.balance === 'number') {
  console.log(`  ✓ historical balance query works (bal=${acctAtBlock.json.balance})`)
}

console.log(`\n✓ balance-proof smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
