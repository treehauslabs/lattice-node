// Cross-chain conservation: run a full swap cycle and verify no value
// is created or destroyed across the chain boundary. Sum of all balances
// on both chains must equal premine + coinbase rewards.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('cross-chain-conservation')
const [{ port, rpcPort }] = allocPorts(1, { seed: 79 })
const CHILD = 'XChain'
const FEE = 1

console.log('=== cross-chain conservation smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus

const specResp = await node.rpc('GET', `/api/chain/spec?chain=${nexusDir}`)
const NEXUS_REWARD = specResp.json.initialReward

await startMining(node, nexusDir)
await deployChild(node, { directory: CHILD, parentDirectory: nexusDir, initialReward: 512 })
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 5, 120_000)

console.log(`\n[1] Snapshot pre-swap balances...`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const preNexusHeight = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const preChildHeight = (await chainInfo(node)).chains.find(c => c.directory === CHILD).height
const preMinerNexus = await getBalance(node, minerAddr, nexusDir)
const preMinerChild = await getBalance(node, minerAddr, CHILD)
console.log(`  nexus: h=${preNexusHeight} miner=${preMinerNexus}`)
console.log(`  child:  h=${preChildHeight} miner=${preMinerChild}`)

console.log(`\n[2] Fund user on both chains...`)
const user = genKeypair()
const FUND = 2000

const mn = await getNonce(node, minerAddr, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce: mn, signers: [minerAddr], fee: FEE,
  accountActions: [
    { owner: minerAddr, delta: -(FUND + FEE) },
    { owner: user.address, delta: FUND },
  ],
}, nexusDir, minerKP)

const mc = await getNonce(node, minerAddr, CHILD)
await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: mc, signers: [minerAddr], fee: FEE,
  accountActions: [
    { owner: minerAddr, delta: -(FUND + FEE) },
    { owner: user.address, delta: FUND },
  ],
}, CHILD, minerKP)

await startMining(node, nexusDir)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= FUND,
  'nexus funded', { timeoutMs: 120_000 })
await waitFor(async () => (await getBalance(node, user.address, CHILD)) >= FUND,
  'child funded', { timeoutMs: 120_000 })

console.log(`\n[3] Run swap: deposit on child, receipt on nexus, withdraw on child...`)
const swapNonce = 'cc' + Date.now().toString(16).padStart(30, '0').slice(-30)
const SWAP_AMOUNT = 500

await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const depN = await getNonce(node, user.address, CHILD)
await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: -(SWAP_AMOUNT + FEE) }],
  depositActions: [{ nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, amountDeposited: SWAP_AMOUNT }],
}, CHILD, user)

await startMining(node, nexusDir)
await waitFor(async () => {
  const d = await getDeposit(node, user.address, SWAP_AMOUNT, swapNonce, CHILD)
  return d.exists ? d : null
}, 'deposit visible', { timeoutMs: 60_000 })

const recN = await getNonce(node, user.address, nexusDir)
await submitTx(node, {
  chainPath: [nexusDir], nonce: recN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: -FEE }],
  receiptActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, directory: CHILD }],
}, nexusDir, user)
await waitFor(async () => {
  const r = await getReceipt(node, user.address, SWAP_AMOUNT, swapNonce, CHILD)
  return r.exists ? r : null
}, 'receipt visible', { timeoutMs: 60_000 })

const wdN = await getNonce(node, user.address, CHILD)
await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdN, signers: [user.address], fee: FEE,
  accountActions: [{ owner: user.address, delta: SWAP_AMOUNT - FEE }],
  withdrawalActions: [{ withdrawer: user.address, nonce: swapNonce, demander: user.address, amountDemanded: SWAP_AMOUNT, amountWithdrawn: SWAP_AMOUNT }],
}, CHILD, user)
await waitFor(async () => {
  const d = await getDeposit(node, user.address, SWAP_AMOUNT, swapNonce, CHILD)
  return !d.exists
}, 'deposit consumed', { timeoutMs: 60_000 })
console.log('  swap complete')

console.log(`\n[4] Verify cross-chain conservation...`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const postNexusHeight = (await chainInfo(node)).chains.find(c => c.directory === nexusDir).height
const postChildHeight = (await chainInfo(node)).chains.find(c => c.directory === CHILD).height
const postMinerNexus = await getBalance(node, minerAddr, nexusDir)
const postMinerChild = await getBalance(node, minerAddr, CHILD)
const postUserNexus = await getBalance(node, user.address, nexusDir)
const postUserChild = await getBalance(node, user.address, CHILD)

const nexusCoinbase = (postNexusHeight - preNexusHeight) * NEXUS_REWARD
const childCoinbase = (postChildHeight - preChildHeight) * 512

const totalNexus = postMinerNexus + postUserNexus
const totalChild = postMinerChild + postUserChild
const expectedNexus = preMinerNexus + nexusCoinbase
const expectedChild = preMinerChild + childCoinbase

console.log(`  nexus: total=${totalNexus} expected=${expectedNexus}`)
console.log(`  child:  total=${totalChild} expected=${expectedChild}`)

if (totalNexus > expectedNexus) {
  console.error(`  ✗ nexus: value created (${totalNexus - expectedNexus} extra)`)
  node.stop(); await sleep(500); process.exit(1)
}
if (totalChild > expectedChild) {
  console.error(`  ✗ child: value created (${totalChild - expectedChild} extra)`)
  node.stop(); await sleep(500); process.exit(1)
}
console.log('  ✓ no value created on either chain')
console.log('  ✓ cross-chain swap conserves total supply')

console.log(`\n✓ cross-chain conservation smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
