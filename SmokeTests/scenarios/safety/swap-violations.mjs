// Swap protocol violation rejection. Exercises abuse vectors against the
// cross-chain swap protocol:
//   1. Withdraw with receipt but no deposit → cannot claim funds
//   2. Double-withdraw after a completed swap → deposit already consumed
//   3. Duplicate deposit nonce → collision rejected or ignored
// The receipt-without-deposit case is accepted by design (receipt is a
// cross-chain claim; the parent can't verify child state inline). The real
// enforcement boundary is the withdrawal step.
// Each violation uses a fresh user to avoid mempool nonce-space interference.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('swap-violations')
const [{ port, rpcPort }] = allocPorts(1, { seed: 27 })
const CHILD = 'SwapTest'
const FEE = 1

console.log('=== swap-violations smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)

const info = await chainInfo(node)
const nexusDir = info.nexus
await startMining(node, nexusDir)
await deployChild(node, { directory: CHILD, parentDirectory: nexusDir })
await stopMining(node, nexusDir)
await sleep(1000)
await startMining(node, nexusDir)
await waitForHeight(node, CHILD, 5, 60_000)

function swapNonce(prefix) {
  return prefix + Date.now().toString(16).padStart(30, '0').slice(-30)
}

async function fundOnChain(user, amount, chain, chainPath) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const base = await getNonce(node, minerAddr, chain)


    for (const n of [base, base + 1]) {
      const r = await submitTx(node, {
        chainPath, nonce: n, signers: [minerAddr], fee: FEE,
        accountActions: [
          { owner: minerAddr, delta: -(amount + FEE) },
          { owner: user.address, delta: amount },
        ],
      }, chain, minerKP)
      if (r.ok) {

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

async function fundUser(user, amount) {
  await stopMining(node, nexusDir)
  await awaitMiningQuiesced(node, nexusDir)
  console.log(`  funding ${user.address.slice(0, 20)}... on nexus...`)
  await fundOnChain(user, amount, nexusDir, [nexusDir])
  console.log(`  funding on ${CHILD}...`)
  await fundOnChain(user, amount, CHILD, [nexusDir, CHILD])
  console.log(`  resuming mining...`)
  await startMining(node, nexusDir)
  const preH = (await chainInfo(node)).chains.find(c => c.directory === CHILD)?.height ?? 0
  await waitForHeight(node, CHILD, preH + 2, 30_000)
  await waitFor(async () => (await getBalance(node, user.address, nexusDir)) >= amount,
    'user nexus funded', { timeoutMs: 60_000 })
  await waitFor(async () => (await getBalance(node, user.address, CHILD)) >= amount,
    'user child funded', { timeoutMs: 60_000 })
}

// ── Violation 1: Withdraw with receipt but no deposit ───────────────────
console.log(`\n[1] Withdraw with receipt but no deposit...`)
const u1 = genKeypair()
await fundUser(u1, 5000)
console.log(`  user1=${u1.address} nexus=${await getBalance(node, u1.address, nexusDir)} child=${await getBalance(node, u1.address, CHILD)}`)

const ghostNonce = swapNonce('f1')
const recN1 = await getNonce(node, u1.address, nexusDir)
const rec1 = await submitTx(node, {
  chainPath: [nexusDir], nonce: recN1, signers: [u1.address], fee: FEE,
  accountActions: [{ owner: u1.address, delta: -FEE }],
  receiptActions: [{ withdrawer: u1.address, nonce: ghostNonce, demander: u1.address, amountDemanded: 500, directory: CHILD }],
}, nexusDir, u1)
if (!rec1.ok) throw new Error(`receipt submit failed: ${JSON.stringify(rec1.submit)}`)
await waitFor(async () => {
  const r = await getReceipt(node, u1.address, 500, ghostNonce, CHILD)
  return r.exists ? r : null
}, 'ghost receipt visible', { timeoutMs: 30_000 })
console.log(`  receipt accepted (by design — cross-chain claim)`)

const childBal1Before = await getBalance(node, u1.address, CHILD)
const wdN1 = await getNonce(node, u1.address, CHILD)
const wd1 = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdN1, signers: [u1.address], fee: FEE,
  accountActions: [{ owner: u1.address, delta: 500 - FEE }],
  withdrawalActions: [{ withdrawer: u1.address, nonce: ghostNonce, demander: u1.address, amountDemanded: 500, amountWithdrawn: 500 }],
}, CHILD, u1)
if (wd1.ok) {
  await sleep(5000)
  const childBal1After = await getBalance(node, u1.address, CHILD)
  if (childBal1After > childBal1Before) {
    console.error(`  ✗ withdrawal without deposit credited funds! (${childBal1Before} → ${childBal1After})`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ submit accepted but withdrawal not applied at block level`)
} else {
  console.log(`  ✓ rejected at submit: ${(wd1.submit?.error ?? JSON.stringify(wd1.submit)).slice(0, 100)}`)
}

// Cycle mining to flush mempool state between violations
await stopMining(node, nexusDir)
await sleep(2000)
await startMining(node, nexusDir)
await sleep(2000)

// ── Violation 2: Double-withdraw after completed swap ───────────────────
console.log(`\n[2] Double-withdraw (complete a real swap, then try withdrawal again)...`)
const u2 = genKeypair()
await fundUser(u2, 5000)
console.log(`  user2=${u2.address}`)

const dblNonce = swapNonce('f2')
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const depN2 = await getNonce(node, u2.address, CHILD)
const dep2 = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depN2, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: -(300 + FEE) }],
  depositActions: [{ nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountDeposited: 300 }],
}, CHILD, u2)
if (!dep2.ok) throw new Error(`deposit failed: ${JSON.stringify(dep2.submit)}`)
await startMining(node, nexusDir)
await waitFor(async () => {
  const d = await getDeposit(node, u2.address, 300, dblNonce, CHILD)
  return d.exists ? d : null
}, 'deposit visible', { timeoutMs: 45_000 })

const recN2 = await getNonce(node, u2.address, nexusDir)
const rec2 = await submitTx(node, {
  chainPath: [nexusDir], nonce: recN2, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: -FEE }],
  receiptActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, directory: CHILD }],
}, nexusDir, u2)
if (!rec2.ok) throw new Error(`receipt failed: ${JSON.stringify(rec2.submit)}`)
await waitFor(async () => {
  const r = await getReceipt(node, u2.address, 300, dblNonce, CHILD)
  return r.exists ? r : null
}, 'receipt visible', { timeoutMs: 45_000 })

const wdN2 = await getNonce(node, u2.address, CHILD)
const wd2 = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdN2, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: 300 - FEE }],
  withdrawalActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountWithdrawn: 300 }],
}, CHILD, u2)
if (!wd2.ok) throw new Error(`first withdrawal failed: ${JSON.stringify(wd2.submit)}`)
await waitFor(async () => {
  const d = await getDeposit(node, u2.address, 300, dblNonce, CHILD)
  return !d.exists
}, 'deposit consumed', { timeoutMs: 45_000 })
console.log(`  legitimate swap completed`)

const childBal2Before = await getBalance(node, u2.address, CHILD)
const wdN2b = await getNonce(node, u2.address, CHILD)
const wd2b = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: wdN2b, signers: [u2.address], fee: FEE,
  accountActions: [{ owner: u2.address, delta: 300 - FEE }],
  withdrawalActions: [{ withdrawer: u2.address, nonce: dblNonce, demander: u2.address, amountDemanded: 300, amountWithdrawn: 300 }],
}, CHILD, u2)
if (wd2b.ok) {
  await sleep(5000)
  const childBal2After = await getBalance(node, u2.address, CHILD)
  if (childBal2After > childBal2Before) {
    console.error(`  ✗ double-withdraw credited funds! (${childBal2Before} → ${childBal2After})`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ submit accepted but second withdrawal not applied at block level`)
} else {
  console.log(`  ✓ rejected at submit: ${(wd2b.submit?.error ?? JSON.stringify(wd2b.submit)).slice(0, 100)}`)
}

// ── Violation 3: Duplicate deposit nonce ────────────────────────────────
console.log(`\n[3] Duplicate deposit nonce...`)
const u3 = genKeypair()
await fundUser(u3, 5000)
console.log(`  user3=${u3.address}`)

const dupNonce = swapNonce('f3')
await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)

const depN3a = await getNonce(node, u3.address, CHILD)
const dep3a = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depN3a, signers: [u3.address], fee: FEE,
  accountActions: [{ owner: u3.address, delta: -(200 + FEE) }],
  depositActions: [{ nonce: dupNonce, demander: u3.address, amountDemanded: 200, amountDeposited: 200 }],
}, CHILD, u3)
if (!dep3a.ok) throw new Error(`first deposit failed: ${JSON.stringify(dep3a.submit)}`)
await startMining(node, nexusDir)
await waitFor(async () => {
  const d = await getDeposit(node, u3.address, 200, dupNonce, CHILD)
  return d.exists ? d : null
}, 'first deposit confirmed', { timeoutMs: 30_000 })
console.log(`  first deposit confirmed`)

await stopMining(node, nexusDir)
await awaitMiningQuiesced(node, nexusDir)
const depN3b = await getNonce(node, u3.address, CHILD)
const dep3b = await submitTx(node, {
  chainPath: [nexusDir, CHILD], nonce: depN3b, signers: [u3.address], fee: FEE,
  accountActions: [{ owner: u3.address, delta: -(200 + FEE) }],
  depositActions: [{ nonce: dupNonce, demander: u3.address, amountDemanded: 200, amountDeposited: 200 }],
}, CHILD, u3)
await startMining(node, nexusDir)
if (dep3b.ok) {
  await sleep(5000)
  const d = await getDeposit(node, u3.address, 200, dupNonce, CHILD)
  if (Number(d.amountDeposited) > 200) {
    console.error(`  ✗ duplicate deposit doubled the amount!`)
    node.stop(); await sleep(500); process.exit(1)
  }
  console.log(`  ✓ submit accepted but duplicate ignored at block level`)
} else {
  console.log(`  ✓ rejected at submit: ${(dep3b.submit?.error ?? JSON.stringify(dep3b.submit)).slice(0, 100)}`)
}

console.log(`\n✓ swap-violations smoke test passed.`)
node.stop()
await sleep(500)
process.exit(0)
