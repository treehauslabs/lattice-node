// Mempool propagation: prepare a tx on the miner (full state), submit the
// signed body via the follower's RPC, verify the miner includes it in a block.
// Tests p2p tx relay — the follower receives the tx and gossips it to the miner.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { Network } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, sign, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, startMining, stopMining,
  awaitMiningQuiesced,
} from '../../lib/chain.mjs'
import { peerCount } from '../../lib/probe.mjs'

const ROOT = smokeRoot('mempool-propagation')
const [a, b] = allocPorts(2, { seed: 29 })

console.log('=== mempool-propagation smoke test ===')
const net = Network.fresh({
  root: ROOT,
  nodes: [
    { name: 'miner', port: a.port, rpcPort: a.rpcPort },
    { name: 'relay', port: b.port, rpcPort: b.rpcPort },
  ],
})
const M = net.byName('miner')
const R = net.byName('relay')

M.start()
await M.waitForRPC()
await M.readIdentity()
const minerIdent = await M.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

R.start({ peers: [M] })
await R.waitForRPC()

const info = await chainInfo(M)
const nexusDir = info.nexus

console.log(`\n[1] Wait for peers to connect...`)
await waitFor(async () => (await peerCount(M)) >= 1 && (await peerCount(R)) >= 1,
  'peers connected', { timeoutMs: 15_000 })
console.log(`  peers connected`)

console.log(`\n[2] Mine brief burst, wait for relay to sync...`)
await startMining(M, nexusDir)
await sleep(200)
await stopMining(M, nexusDir)
await awaitMiningQuiesced(M, nexusDir)
const mInfo = await chainInfo(M)
const mHeight = mInfo.chains.find(c => c.directory === nexusDir)?.height ?? 0
console.log(`  miner height: ${mHeight}`)

await waitFor(async () => {
  const ri = await chainInfo(R)
  const rc = ri?.chains?.find(c => c.directory === nexusDir)
  return rc && rc.height >= mHeight ? rc.height : null
}, 'relay synced to miner height', { timeoutMs: 60_000 })
console.log(`  relay synced`)
const minerBal = await getBalance(M, minerAddr, nexusDir)
console.log(`  miner balance: ${minerBal}`)

console.log(`\n[3] Prepare tx on miner, submit via relay node...`)
const recipient = genKeypair()
const nonce = await getNonce(M, minerAddr, nexusDir)

const prep = await M.rpc('POST', '/api/transaction/prepare', {
  chainPath: [nexusDir], nonce, signers: [minerAddr], fee: 1,
  accountActions: [
    { owner: minerAddr, delta: -1001 },
    { owner: recipient.address, delta: 1000 },
  ],
})
if (!prep.ok) throw new Error(`prepare failed: ${JSON.stringify(prep.json)}`)
const { bodyCID, bodyData } = prep.json
const signature = sign(bodyCID, minerKP.privateKey)

const relaySubmit = await R.rpc('POST', '/api/transaction', {
  signatures: { [minerKP.publicKey]: signature },
  bodyCID, bodyData, chain: nexusDir,
})
console.log(`  relay submit: ok=${relaySubmit.ok} ${JSON.stringify(relaySubmit.json).slice(0, 80)}`)
if (!relaySubmit.ok) {
  console.error(`  ✗ submit via relay rejected: ${JSON.stringify(relaySubmit.json)}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`\n[4] Mine on miner, verify tx was included...`)
await startMining(M, nexusDir)
const recvBal = await waitFor(
  async () => {
    const b = await getBalance(M, recipient.address, nexusDir)
    return b >= 1000 ? b : null
  },
  'recipient funded on miner', { timeoutMs: 60_000 },
)
console.log(`  ✓ recipient balance on miner: ${recvBal}`)
console.log(`  tx submitted to relay → relayed to miner → mined into block`)

console.log(`\n✓ mempool-propagation smoke test passed.`)
net.teardown()
await sleep(500)
process.exit(0)
