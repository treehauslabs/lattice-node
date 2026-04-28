// Cross-chain swap: deposit (child) → receipt (parent) → withdrawal (child).
//
// Self-contained: spawns its own LatticeNode under SMOKE_ROOT, deploys a fast
// child chain, funds a fresh keypair on both chains (avoiding the miner's
// coinbase-nonce race), then runs the full swap and asserts state transitions.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('swap')
const [{ port, rpcPort }] = allocPorts(1, { seed: 51 })
const CHILD = 'FastTest'

console.log('=== cross-chain swap smoke test ===')
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
// Restart Nexus mining so merged-mining picks up the child chain.
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 10, 60_000)
console.log(`${CHILD} deployed and mining`)

const minerNexusBal = await getBalance(node, minerAddr, nexusDir)
const minerChildBal = await getBalance(node, minerAddr, CHILD)
console.log(`\nminer balances  Nexus=${minerNexusBal}  ${CHILD}=${minerChildBal}`)

const fundAmount = 5000
if (minerChildBal < fundAmount + 100 || minerNexusBal < fundAmount + 100) {
  console.error(`Insufficient miner balance to fund test`)
  node.stop(); process.exit(1)
}

// Pause merged mining (child chains ride along Nexus) so staged fund txs
// don't race with the miner's per-block coinbase nonce advance.
console.log(`\npausing mining to stage fund txs (avoids coinbase nonce race)`)
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

async function stageFund(chain, chainPath) {
  // /api/nonce returns "last used" — ambiguous for the miner whose coinbase
  // tx may have already advanced. Try base and base+1 with retries.
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
      if (r.ok) {
        console.log(`  staged ${chain}: tx=${r.submit.txCID.slice(0, 20)}... nonce=${n}`)
        return
      }
      const msg = JSON.stringify(r.submit)
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

console.log(`staging fund txs (${fundAmount} on each chain)...`)
await stageFund(nexusDir, [nexusDir])
await stageFund(CHILD, [nexusDir, CHILD])

console.log(`resuming mining`)
await startMining(node, nexusDir)

console.log(`waiting for fund inclusion...`)
await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= fundAmount,
  'user Nexus balance funded', { timeoutMs: 60_000, intervalMs: 1_000 })
await waitFor(async () => (await getBalance(node, user.address, CHILD)) >= fundAmount,
  `user ${CHILD} balance funded`, { timeoutMs: 60_000, intervalMs: 1_000 })

const nexusBal0 = await getBalance(node, user.address, nexusDir)
const childBal0 = await getBalance(node, user.address, CHILD)
console.log(`user balances  Nexus=${nexusBal0}  ${CHILD}=${childBal0}`)

const swapNonceHex = Date.now().toString(16).padStart(32, '0').slice(-32)
const amount = 500
const fee = 1
console.log(`\nswap: amount=${amount} swapNonce=0x${swapNonceHex} fee=${fee}/tx`)

// [1/3] Deposit on child.
const depNonce = await getNonce(node, user.address, CHILD)
console.log(`\n[1/3] Deposit on ${CHILD} (acct nonce=${depNonce})`)
const depResult = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -(amount + fee) }],
  depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
}, CHILD, user)
console.log('  submit:', depResult.submit)
if (!depResult.ok) { node.stop(); process.exit(1) }

console.log(`  waiting for deposit state...`)
const depState = await waitFor(async () => {
  const r = await getDeposit(node, user.address, amount, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'deposit state visible', { timeoutMs: 60_000, intervalMs: 1_000 })
console.log(`  ✓ deposit in state: amountDeposited=${depState.amountDeposited}`)

// [2/3] Receipt on parent.
const recNonce = await getNonce(node, user.address, nexusDir)
console.log(`\n[2/3] Receipt on ${nexusDir} (acct nonce=${recNonce})`)
const recResult = await submitTx(node, {
  chainPath: [nexusDir], nonce: recNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: -fee }],
  receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: CHILD }],
}, nexusDir, user)
console.log('  submit:', recResult.submit)
if (!recResult.ok) { node.stop(); process.exit(1) }

console.log(`  waiting for receipt state...`)
const recState = await waitFor(async () => {
  const r = await getReceipt(node, user.address, amount, swapNonceHex, CHILD)
  return r.exists ? r : null
}, 'receipt state visible', { timeoutMs: 60_000, intervalMs: 1_000 })
console.log(`  ✓ receipt in state: withdrawer=${recState.withdrawer?.slice(0, 20)}...`)

// [3/3] Withdrawal on child.
const wdNonce = await getNonce(node, user.address, CHILD)
console.log(`\n[3/3] Withdrawal on ${CHILD} (acct nonce=${wdNonce})`)
const wdResult = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdNonce, signers: [user.address], fee,
  accountActions: [{ owner: user.address, delta: amount - fee }],
  withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
}, CHILD, user)
console.log('  submit:', wdResult.submit)
if (!wdResult.ok) { node.stop(); process.exit(1) }

console.log(`  waiting for deposit to be consumed...`)
await waitFor(async () => {
  const r = await getDeposit(node, user.address, amount, swapNonceHex, CHILD)
  return !r.exists
}, 'deposit consumed', { timeoutMs: 60_000, intervalMs: 1_000 })
console.log(`  ✓ deposit consumed (withdrawal settled)`)

await sleep(3000)
const nexusBal1 = await getBalance(node, user.address, nexusDir)
const childBal1 = await getBalance(node, user.address, CHILD)

console.log(`\n=== RESULTS ===`)
console.log(`Nexus     before=${nexusBal0}  after=${nexusBal1}  delta=${nexusBal1 - nexusBal0}`)
console.log(`${CHILD}  before=${childBal0}  after=${childBal1}  delta=${childBal1 - childBal0}`)
console.log(`\n✓ Full deposit -> receipt -> withdrawal cycle completed`)

node.stop()
await sleep(500)
process.exit(0)
