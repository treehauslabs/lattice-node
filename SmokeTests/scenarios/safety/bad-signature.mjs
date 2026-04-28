// Bad-signature rejection. Prepare a real transaction, then submit it with:
//   1. a flipped-byte signature  → reject
//   2. a signature from the wrong keypair → reject
//   3. an empty signatures map → reject
// And finally a clean re-submit with the correct signature → accept.
// Asserts the node refuses to apply unauthorized state transitions even when
// the bodyCID/bodyData are perfectly well-formed.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import { chainInfo, getNonce, startMining, stopMining, awaitMiningQuiesced } from '../../lib/chain.mjs'

const ROOT = smokeRoot('bad-signature')
const [{ port, rpcPort }] = allocPorts(1, { seed: 23 })

console.log('=== bad-signature smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await sleep(2000)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const recipient = genKeypair()
const stranger = genKeypair()
const nonce = await getNonce(node, minerAddr, nexusDir)

const prep = await node.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -101 },
    { owner: recipient.address, delta: 100 },
  ],
})
if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
const { bodyCID, bodyData } = prep.json
console.log(`  prepared bodyCID=${bodyCID.slice(0, 24)}...`)

async function expectReject(label, signatures) {
  const r = await node.rpc('POST', '/api/transaction', {
    signatures, bodyCID, bodyData, chain: nexusDir,
  })
  if (r.ok) {
    console.error(`  ✗ ${label}: expected rejection but submit accepted`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ ${label} rejected: ${(r.json?.error ?? JSON.stringify(r.json)).toString().slice(0, 90)}`)
}

// 1. Flip a byte in the real signature.
const realSig = sign(bodyCID, minerKP.privateKey)
const flipped = realSig.slice(0, 4) + (realSig[4] === '0' ? '1' : '0') + realSig.slice(5)
await expectReject('flipped-byte signature', { [minerKP.publicKey]: flipped })

// 2. Sign with stranger's key — body says minerAddr is signer, sig says stranger.
const wrongSig = sign(bodyCID, stranger.privateKey)
await expectReject('wrong-key signature', { [stranger.publicKey]: wrongSig })

// 3. No signatures at all.
await expectReject('empty signatures', {})

// 4. Sanity: real signature is accepted.
const goodSig = sign(bodyCID, minerKP.privateKey)
const okSubmit = await node.rpc('POST', '/api/transaction', {
  signatures: { [minerKP.publicKey]: goodSig }, bodyCID, bodyData, chain: nexusDir,
})
if (!okSubmit.ok) {
  console.error(`  ✗ correctly-signed tx was rejected: ${JSON.stringify(okSubmit.json)}`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log(`  ✓ correctly-signed tx accepted`)

console.log(`\n✓ bad-signature smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
