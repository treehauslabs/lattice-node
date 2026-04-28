// Restart resilience: run a variable-rate swap A, hard-restart the node
// against the SAME data-dir, then run a swap B with an inverse rate. Asserts
// swap A's deposit stays consumed across the restart, and the chain still
// settles new swaps.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitMiningQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('restart-resilience')
const [{ port, rpcPort }] = allocPorts(1, { seed: 19 })
const CHILD = 'FastTest'

console.log('=== restart-resilience variable-rate swap smoke test ===')
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
await node.waitForRPC()
const minerIdent = await node.readIdentity()
const minerKP = { privateKey: minerIdent.privateKey, publicKey: minerIdent.publicKey }
const minerAddr = computeAddress(minerIdent.publicKey)
console.log(`miner address: ${minerAddr}`)

const initial = await chainInfo(node)
const nexusDir = initial.nexus
console.log(`  nexus=${nexusDir} chains=${initial.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

await startMining(node, nexusDir)
const hasChild = initial.chains?.some((c) => c.directory === CHILD)
if (!hasChild) {
  console.log(`  deploying ${CHILD}...`)
  await deployChild(node, { directory: CHILD, parentDirectory: nexusDir })
  await stopMining(node, nexusDir)
  await sleep(1000)
  await startMining(node, nexusDir)
}
await waitForHeight(node, CHILD, 5, 60_000)

async function stageFund(addr, fundAmount, chain, chainPath) {
  for (let attempt = 0; attempt < 6; attempt++) {
    const base = await getNonce(node, minerAddr, chain)
    for (const n of [base, base + 1]) {
      const r = await submitTx(node, {
        chainPath, nonce: n, signers: [minerAddr], fee: 1,
        accountActions: [
          { owner: minerAddr, delta: -(fundAmount + 1) },
          { owner: addr, delta: fundAmount },
        ],
      }, chain, minerKP)
      if (r.ok) return
      const msg = JSON.stringify(r.submit)
      if (!msg.includes('Nonce already used') && !msg.includes('future')) {
        throw new Error(`fund ${chain} failed: ${msg}`)
      }
    }
    await sleep(500)
  }
  throw new Error(`fund ${chain} failed after retries`)
}

async function fundAccount(addr, fundAmount) {
  await stopMining(node, nexusDir)
  await awaitMiningQuiesced(node, nexusDir)
  await stageFund(addr, fundAmount, nexusDir, [nexusDir])
  await stageFund(addr, fundAmount, CHILD, [nexusDir, CHILD])
  await startMining(node, nexusDir)
  await waitFor(async () => (await getBalance(node, addr, nexusDir)) >= fundAmount,
    'nexus balance funded', { timeoutMs: 60_000 })
  await waitFor(async () => (await getBalance(node, addr, CHILD)) >= fundAmount,
    `${CHILD} balance funded`, { timeoutMs: 60_000 })
}

async function runSwap({ label, user, amountDeposited, amountDemanded, swapNonceHex }) {
  console.log(`\n--- ${label}: deposited=${amountDeposited} ${CHILD} demanded=${amountDemanded} Nexus (rate ${(amountDemanded / amountDeposited).toFixed(2)}x) ---`)
  const fee = 1

  const depNonce = await getNonce(node, user.address, CHILD)
  const depResult = await submitTx(node, {
    chainPath: [nexusDir, CHILD], nonce: depNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -(amountDeposited + fee) }],
    depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded, amountDeposited }],
  }, CHILD, user)
  if (!depResult.ok) throw new Error(`deposit failed: ${JSON.stringify(depResult.submit)}`)
  console.log(`  [1/3] deposit accepted`)

  const depState = await waitFor(async () => {
    const r = await getDeposit(node, user.address, amountDemanded, swapNonceHex, CHILD)
    return r.exists ? r : null
  }, 'deposit visible', { timeoutMs: 45_000 })
  if (Number(depState.amountDeposited) !== amountDeposited) {
    throw new Error(`expected amountDeposited=${amountDeposited}, got ${depState.amountDeposited}`)
  }

  const recNonce = await getNonce(node, user.address, nexusDir)
  const recResult = await submitTx(node, {
    chainPath: [nexusDir], nonce: recNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -fee }],
    receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded, directory: CHILD }],
  }, nexusDir, user)
  if (!recResult.ok) throw new Error(`receipt failed: ${JSON.stringify(recResult.submit)}`)
  console.log(`  [2/3] receipt accepted`)
  await waitFor(async () => {
    const r = await getReceipt(node, user.address, amountDemanded, swapNonceHex, CHILD)
    return r.exists ? r : null
  }, 'receipt visible', { timeoutMs: 45_000 })

  const wdNonce = await getNonce(node, user.address, CHILD)
  const wdResult = await submitTx(node, {
    chainPath: [nexusDir, CHILD], nonce: wdNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: amountDeposited - fee }],
    withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded, amountWithdrawn: amountDeposited }],
  }, CHILD, user)
  if (!wdResult.ok) throw new Error(`withdrawal failed: ${JSON.stringify(wdResult.submit)}`)
  console.log(`  [3/3] withdrawal accepted`)
  await waitFor(async () => {
    const r = await getDeposit(node, user.address, amountDemanded, swapNonceHex, CHILD)
    return !r.exists
  }, 'deposit consumed', { timeoutMs: 45_000 })
  console.log(`  ✓ swap complete`)
}

console.log(`\n[phase 2] swap A (pre-restart)...`)
const userA = genKeypair()
console.log(`  user A: ${userA.address}`)
await fundAccount(userA.address, 5000)
const swapNonceA = '0a' + Date.now().toString(16).padStart(30, '0').slice(-30)
await runSwap({ label: 'swap A', user: userA, amountDeposited: 100, amountDemanded: 250, swapNonceHex: swapNonceA })

console.log(`\n[phase 3] restarting node (preserving data-dir)...`)
await node.restart()
await node.waitForRPC(300_000)
console.log(`  ✓ RPC ready after restart`)

await startMining(node, nexusDir)

console.log(`\n[phase 4] verifying swap A state survived restart...`)
const postDep = await getDeposit(node, userA.address, 250, swapNonceA, CHILD)
if (postDep.exists) {
  console.error(`  ✗ swap A deposit reappeared after restart!`); node.stop(); process.exit(1)
}
console.log(`  ✓ swap A deposit still consumed`)
const postRec = await getReceipt(node, userA.address, 250, swapNonceA, CHILD)
if (!postRec.exists) {
  console.error(`  ✗ swap A receipt vanished after restart!`); node.stop(); process.exit(1)
}
console.log(`  ✓ swap A receipt still present`)

console.log(`\n[phase 5] swap B (post-restart, inverse rate)...`)
const initialHeight = (await chainInfo(node)).chains.find((c) => c.directory === nexusDir).height
await waitFor(async () => {
  const h = (await chainInfo(node)).chains.find((c) => c.directory === nexusDir).height
  return h > initialHeight ? h : null
}, 'nexus mining advance after restart', { timeoutMs: 90_000 })

const userB = genKeypair()
console.log(`  user B: ${userB.address}`)
await fundAccount(userB.address, 5000)
const swapNonceB = '0b' + Date.now().toString(16).padStart(30, '0').slice(-30)
await runSwap({ label: 'swap B', user: userB, amountDeposited: 200, amountDemanded: 75, swapNonceHex: swapNonceB })

console.log(`\n=== RESULTS ===`)
console.log(`✓ swap A executed pre-restart (rate 2.50x)`)
console.log(`✓ node restarted cleanly (data-dir preserved)`)
console.log(`✓ swap A deposit/receipt state survived restart`)
console.log(`✓ swap B executed post-restart (rate 0.375x — inverse)`)

node.stop()
await sleep(500)
process.exit(0)
