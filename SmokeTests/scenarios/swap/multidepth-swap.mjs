// Multi-depth cross-chain swap. Tree:
//
//     Nexus ─┬─ ChainB ── ChainD
//            └─ ChainC ── ChainE ── ChainG
//
// Runs swap cycles where the receipt chain is at depths 0, 1, and 2 — the
// deepest receipt chain (E for source G) exercises the recursive tree-walk in
// `withdrawalsAreValid` at depth-2 from the nexus.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitChainsQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('multidepth')
const [{ port, rpcPort }] = allocPorts(1, { seed: 72 })

console.log('=== multi-depth cross-chain swap smoke test ===')
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
const NEXUS = info.nexus
const B = 'ChainB', C = 'ChainC', D = 'ChainD', E = 'ChainE', G = 'ChainG'
const PATH = {
  [NEXUS]: [NEXUS],
  [B]: [NEXUS, B], [C]: [NEXUS, C],
  [D]: [NEXUS, B, D], [E]: [NEXUS, C, E],
  [G]: [NEXUS, C, E, G],
}
const PARENT = { [B]: NEXUS, [C]: NEXUS, [D]: B, [E]: C, [G]: E }

await startMining(node, NEXUS)

console.log(`\n[A] Deploying ${B}, ${C} as children of ${NEXUS}...`)
await deployChild(node, { directory: B, parentDirectory: NEXUS, premine: 100, premineRecipient: minerAddr })
await deployChild(node, { directory: C, parentDirectory: NEXUS, premine: 100, premineRecipient: minerAddr })

console.log(`\n[B] Deploying ${D} under ${B}, ${E} under ${C}...`)
await deployChild(node, { directory: D, parentDirectory: B, premine: 100, premineRecipient: minerAddr })
await deployChild(node, { directory: E, parentDirectory: C, premine: 100, premineRecipient: minerAddr })

console.log(`\n[C] Deploying ${G} under ${E}...`)
await deployChild(node, { directory: G, parentDirectory: E, premine: 100, premineRecipient: minerAddr })

console.log(`\n[D] Verifying chain topology...`)
const post = await chainInfo(node)
const byDir = Object.fromEntries(post.chains.map((c) => [c.directory, c]))
for (const [dir, expectedParent] of [[B, NEXUS], [C, NEXUS], [D, B], [E, C], [G, E]]) {
  if (!byDir[dir]) throw new Error(`chain ${dir} not present`)
  if (byDir[dir].parentDirectory !== expectedParent) {
    throw new Error(`${dir}: expected parent=${expectedParent} got ${byDir[dir].parentDirectory}`)
  }
  console.log(`  ✓ ${dir}.parentDirectory = ${byDir[dir].parentDirectory}`)
}

console.log(`\n[E] Waiting for chains to mine blocks...`)
for (const dir of [B, C, D, E, G]) await waitForHeight(node, dir, 3, 90_000)

const fundAmount = 5000
for (const dir of [NEXUS, B, C, D, E, G]) {
  const bal = await getBalance(node, minerAddr, dir)
  if (bal < fundAmount + 100) {
    console.error(`Insufficient miner balance on ${dir}: ${bal}`); node.stop(); process.exit(1)
  }
}

console.log(`\n[F] Pausing mining to stage fund txs...`)
await stopMining(node, NEXUS)
await awaitChainsQuiesced(node, [NEXUS, B, C, D, E, G])

async function stageFund(chain) {
  const chainPath = PATH[chain]
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

console.log(`\n[G] Funding user on all chains...`)
for (const dir of [NEXUS, B, C, D, E, G]) await stageFund(dir)

console.log(`\n[H] Resuming mining; waiting for fund inclusion...`)
await startMining(node, NEXUS)
for (const dir of [NEXUS, B, C, D, E, G]) {
  await waitFor(async () => (await getBalance(node, user.address, dir)) >= fundAmount,
    `user ${dir} funded`, { timeoutMs: 90_000 })
}

const before = {}
for (const dir of [NEXUS, B, C, D, E, G]) before[dir] = await getBalance(node, user.address, dir)
console.log(`  user balances: ${Object.entries(before).map(([k, v]) => `${k}=${v}`).join(' ')}`)

const nextNonce = { [NEXUS]: 0, [B]: 0, [C]: 0, [D]: 0, [E]: 0, [G]: 0 }

async function runCycle(source, label) {
  const receiptChain = PARENT[source]
  const swapNonceHex = (Date.now() + Math.floor(Math.random() * 1e9)).toString(16).padStart(32, '0').slice(-32)
  const amount = 500
  const fee = 1
  console.log(`  [${label}] source=${source} receiptChain=${receiptChain} amount=${amount}`)

  const depNonce = nextNonce[source]++
  const depResult = await submitTx(node, {
    chainPath: PATH[source], nonce: depNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -(amount + fee) }],
    depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
  }, source, user)
  if (!depResult.ok) throw new Error(`deposit on ${source} failed: ${JSON.stringify(depResult.submit)}`)
  await waitFor(async () => {
    const r = await getDeposit(node, user.address, amount, swapNonceHex, source)
    return r.exists ? r : null
  }, `deposit visible on ${source}`, { timeoutMs: 60_000 })

  const recNonce = nextNonce[receiptChain]++
  const recResult = await submitTx(node, {
    chainPath: PATH[receiptChain], nonce: recNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -fee }],
    receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: source }],
  }, receiptChain, user)
  if (!recResult.ok) throw new Error(`receipt on ${receiptChain} failed: ${JSON.stringify(recResult.submit)}`)
  await waitFor(async () => {
    const r = await getReceipt(node, user.address, amount, swapNonceHex, source)
    return r.exists ? r : null
  }, `receipt visible for ${source} on ${receiptChain}`, { timeoutMs: 60_000 })

  const wdNonce = nextNonce[source]++
  const wdResult = await submitTx(node, {
    chainPath: PATH[source], nonce: wdNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: amount - fee }],
    withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
  }, source, user)
  if (!wdResult.ok) throw new Error(`withdrawal on ${source} failed: ${JSON.stringify(wdResult.submit)}`)
  await waitFor(async () => {
    const r = await getDeposit(node, user.address, amount, swapNonceHex, source)
    return !r.exists
  }, `deposit consumed on ${source}`, { timeoutMs: 60_000 })

  console.log(`    ✓ cycle ${label} complete`)
}

const expectedSourceDelta = {}
const expectedReceiptDelta = {}
function recordCycle(source) {
  const receiptChain = PARENT[source]
  expectedSourceDelta[source] = (expectedSourceDelta[source] || 0) - 2
  expectedReceiptDelta[receiptChain] = (expectedReceiptDelta[receiptChain] || 0) - 1
}

console.log(`\n[I] Running swap cycles...`)
await runCycle(B, 'cycle-B-on-Nexus'); recordCycle(B)
await runCycle(C, 'cycle-C-on-Nexus'); recordCycle(C)
await runCycle(D, 'cycle-D-on-B'); recordCycle(D)
await runCycle(E, 'cycle-E-on-C'); recordCycle(E)
await runCycle(G, 'cycle-G-on-E'); recordCycle(G)
await runCycle(D, 'cycle-D-on-B-#2'); recordCycle(D)
await runCycle(G, 'cycle-G-on-E-#2'); recordCycle(G)

await sleep(4000)
const after = {}
for (const dir of [NEXUS, B, C, D, E, G]) after[dir] = await getBalance(node, user.address, dir)

console.log(`\n=== RESULTS ===`)
let failed = false
for (const dir of [NEXUS, B, C, D, E, G]) {
  const actual = after[dir] - before[dir]
  const expected = (expectedSourceDelta[dir] || 0) + (expectedReceiptDelta[dir] || 0)
  const ok = actual === expected
  if (!ok) failed = true
  console.log(`  ${dir.padEnd(8)} before=${before[dir]}  after=${after[dir]}  delta=${actual}  expected=${expected}  ${ok ? '✓' : '✗'}`)
}

if (failed) {
  console.error(`\n✗ Balance deltas did not match`)
  node.stop(); await sleep(500); process.exit(1)
}

console.log(`\n✓ Multi-depth cross-chain swap cycles succeeded`)
node.stop()
await sleep(500)
process.exit(0)
