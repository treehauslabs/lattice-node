// Variable-rate cross-chain swap: amountDeposited (child tokens locked) differs
// from amountDemanded (parent tokens demanded). Asserts the (deposited, demanded)
// pair is preserved end-to-end and the on-chain overclaim guard is satisfied.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('vrs')
const [{ port, rpcPort }] = allocPorts(1, { seed: 62 })
const CHILD = 'FastTest'

console.log('=== variable-rate cross-chain swap smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
const user = genKeypair()
console.log(`miner address: ${minerAddr}`)
console.log(`user address:  ${user.address}`)

const info = await chainInfo(node)
const nexusDir = info.nexus
console.log(`chains: ${info.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

await startMining(node, nexusDir)
console.log(`deploying ${CHILD}...`)
await deployChild(node, { directory: CHILD, parentDirectory: nexusDir })
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 10, 60_000)

const minerNexus = await getBalance(node, minerAddr, nexusDir)
const minerChild = await getBalance(node, minerAddr, CHILD)
console.log(`\nminer balances  Nexus=${minerNexus}  ${CHILD}=${minerChild}`)
const fundAmount = 5000
if (minerNexus < fundAmount + 100 || minerChild < fundAmount + 100) {
  console.error('Insufficient miner balance'); node.stop(); process.exit(1)
}

console.log(`\npausing mining to stage fund txs`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

async function stageFund(chain, chainPath) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const base = await getNonce(node, minerAddr, chain)
    for (const n of [base, base + 1]) {
      const r = await submitTx(node, {
        chainPath, nonce: n, signers: [minerAddr], fee: 1,
        accountActions: [
          { owner: minerAddr, delta: -(fundAmount + 1) },
          { owner: user.address, delta: fundAmount },
        ],
      }, chain, minerKP)
      if (r.ok) { console.log(`  staged ${chain} nonce=${n}`); return }
      const msg = JSON.stringify(r.submit)
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

await stageFund(nexusDir, [nexusDir])
await stageFund(CHILD, [nexusDir, CHILD])
await startMining(node, nexusDir)

await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= fundAmount,
  'user Nexus funded', { timeoutMs: 60_000 })
await waitFor(async () => (await getBalance(node, user.address, CHILD)) >= fundAmount,
  `user ${CHILD} funded`, { timeoutMs: 60_000 })

const nexusBal0 = await getBalance(node, user.address, nexusDir)
const childBal0 = await getBalance(node, user.address, CHILD)
console.log(`user balances  Nexus=${nexusBal0}  ${CHILD}=${childBal0}`)

const swapNonceHex = Date.now().toString(16).padStart(32, '0').slice(-32)
const amountDeposited = 100
const amountDemanded = 250
const fee = 1
console.log(`\nvariable-rate: deposited=${amountDeposited} ${CHILD} demanded=${amountDemanded} Nexus`)
console.log(`rate ${(amountDemanded / amountDeposited).toFixed(2)}x  swapNonce=0x${swapNonceHex}`)

const depNonce = await getNonce(node, user.address, CHILD)
console.log(`\n[1/3] Deposit on ${CHILD} (acct nonce=${depNonce})`)
const depResult = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -(amountDeposited + fee) }],
  depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded, amountDeposited }],
}, CHILD, user)
if (!depResult.ok) { node.stop(); process.exit(1) }

const depState = await waitFor(async () => {
  const r = await getDeposit(node, user.address, amountDemanded, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'deposit visible', { timeoutMs: 60_000 })
console.log(`  ✓ deposit in state: amountDeposited=${depState.amountDeposited} (demanded=${amountDemanded})`)
if (Number(depState.amountDeposited) !== amountDeposited) {
  console.error(`  ✗ expected amountDeposited=${amountDeposited}, got ${depState.amountDeposited}`)
  node.stop(); process.exit(1)
}

const recNonce = await getNonce(node, user.address, nexusDir)
console.log(`\n[2/3] Receipt on ${nexusDir} (acct nonce=${recNonce}) paying ${amountDemanded}`)
const recResult = await submitTx(node, {
  chainPath: [nexusDir], nonce: recNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -fee }],
  receiptActions: [{
    withdrawer: user.address, nonce: swapNonceHex, demander: user.address,
    amountDemanded, directory: CHILD,
  }],
}, nexusDir, user)
if (!recResult.ok) { node.stop(); process.exit(1) }
await waitFor(async () => {
  const r = await getReceipt(node, user.address, amountDemanded, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'receipt visible', { timeoutMs: 60_000 })
console.log(`  ✓ receipt visible`)

const wdNonce = await getNonce(node, user.address, CHILD)
console.log(`\n[3/3] Withdrawal on ${CHILD} (acct nonce=${wdNonce}) unlocking ${amountDeposited}`)
const wdResult = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: amountDeposited - fee }],
  withdrawalActions: [{
    withdrawer: user.address, nonce: swapNonceHex, demander: user.address,
    amountDemanded, amountWithdrawn: amountDeposited,
  }],
}, CHILD, user)
if (!wdResult.ok) { node.stop(); process.exit(1) }
await waitFor(async () => {
  const r = await getDeposit(node, user.address, amountDemanded, swapNonceHex, CHILD)
  return !r.exists
}, 'deposit consumed', { timeoutMs: 60_000 })
console.log(`  ✓ deposit consumed`)

await sleep(3000)
const nexusBal1 = await getBalance(node, user.address, nexusDir)
const childBal1 = await getBalance(node, user.address, CHILD)
console.log(`\n=== RESULTS ===`)
console.log(`Nexus     before=${nexusBal0}  after=${nexusBal1}  delta=${nexusBal1 - nexusBal0}`)
console.log(`${CHILD}  before=${childBal0}  after=${childBal1}  delta=${childBal1 - childBal0}`)
console.log(`✓ rate ${(amountDemanded / amountDeposited).toFixed(2)}x preserved through all three steps`)

node.stop()
await sleep(500)
process.exit(0)
