// Grandchild cross-chain swap: deposit/withdrawal on grandchild, receipt on the
// direct parent (Mid). Validates `withdrawalsAreValid` walks the recursive
// ChainLevel tree to find receiptState on the intermediate parent — not the
// nexus.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'
import { genKeypair, computeAddress } from '../../lib/wallet.mjs'
import {
  chainInfo, getNonce, getBalance, getDeposit, getReceipt,
  startMining, stopMining, awaitChainsQuiesced, deployChild, waitForHeight,
} from '../../lib/chain.mjs'
import { submitTx } from '../../lib/tx.mjs'

const ROOT = smokeRoot('grandchild')
const [{ port, rpcPort }] = allocPorts(1, { seed: 82 })
const MID = 'Mid'
const ALPHA = 'AlphaChain'
const BETA = 'BetaChain'

console.log('=== grandchild cross-chain swap smoke test ===')
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
console.log(`initial chains: ${info.chains.map((c) => `${c.directory}@${c.height}`).join(', ')}`)

await startMining(node, nexusDir)

console.log(`\n[A] Deploying ${MID} as child of ${nexusDir}...`)
await deployChild(node, { directory: MID, parentDirectory: nexusDir, premine: 100, premineRecipient: minerAddr })

console.log(`\n[B] Deploying grandchildren ${ALPHA} and ${BETA} as children of ${MID}...`)
await deployChild(node, { directory: ALPHA, parentDirectory: MID, premine: 100, premineRecipient: minerAddr })
await deployChild(node, { directory: BETA, parentDirectory: MID, premine: 100, premineRecipient: minerAddr })

console.log(`\n[C] Verifying chain topology...`)
const postInfo = await chainInfo(node)
const byDir = Object.fromEntries(postInfo.chains.map((c) => [c.directory, c]))
for (const [dir, expectedParent] of [[MID, nexusDir], [ALPHA, MID], [BETA, MID]]) {
  if (!byDir[dir]) throw new Error(`chain ${dir} not present after deploy`)
  if (byDir[dir].parentDirectory !== expectedParent) {
    throw new Error(`${dir}: expected parentDirectory=${expectedParent}, got ${byDir[dir].parentDirectory}`)
  }
  console.log(`  ✓ ${dir}.parentDirectory = ${byDir[dir].parentDirectory}`)
}

console.log(`\n[D] Waiting for chains to mine blocks...`)
await waitForHeight(node, MID, 3, 60_000)
await waitForHeight(node, ALPHA, 3, 60_000)
await waitForHeight(node, BETA, 3, 60_000)

const minerMid0 = await getBalance(node, minerAddr, MID)
const minerAlpha0 = await getBalance(node, minerAddr, ALPHA)
const minerBeta0 = await getBalance(node, minerAddr, BETA)
console.log(`  miner balances: ${MID}=${minerMid0} ${ALPHA}=${minerAlpha0} ${BETA}=${minerBeta0}`)

const fundAmount = 5000
if (minerMid0 < fundAmount + 100 || minerAlpha0 < fundAmount + 100 || minerBeta0 < fundAmount + 100) {
  console.error('Insufficient miner balance'); node.stop(); process.exit(1)
}

console.log(`\n[E] Pausing mining to stage fund txs...`)
await stopMining(node, nexusDir)
await awaitChainsQuiesced(node, [nexusDir, MID, ALPHA, BETA])

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

await stageFund(MID, [nexusDir, MID])
await stageFund(ALPHA, [nexusDir, MID, ALPHA])
await stageFund(BETA, [nexusDir, MID, BETA])

console.log(`resuming mining`)
await startMining(node, nexusDir)

await waitFor(async () => (await getBalance(node, user.address, MID)) >= fundAmount,
  `user ${MID} funded`, { timeoutMs: 60_000 })
await waitFor(async () => (await getBalance(node, user.address, ALPHA)) >= fundAmount,
  `user ${ALPHA} funded`, { timeoutMs: 60_000 })
await waitFor(async () => (await getBalance(node, user.address, BETA)) >= fundAmount,
  `user ${BETA} funded`, { timeoutMs: 60_000 })

const userMid0 = await getBalance(node, user.address, MID)
const userAlpha0 = await getBalance(node, user.address, ALPHA)
const userBeta0 = await getBalance(node, user.address, BETA)
console.log(`  user balances: ${MID}=${userMid0} ${ALPHA}=${userAlpha0} ${BETA}=${userBeta0}`)

const nextNonce = { [MID]: 0, [ALPHA]: 0, [BETA]: 0 }

async function runCycle(grandchild, index) {
  const swapNonceHex = (Date.now() + index * 97).toString(16).padStart(32, '0').slice(-32)
  const amount = 500
  const fee = 1
  console.log(`  [cycle ${index}] grandchild=${grandchild} amount=${amount} swapNonce=0x${swapNonceHex.slice(0, 12)}...`)

  const depNonce = nextNonce[grandchild]++
  const depResult = await submitTx(node, {
    chainPath: [nexusDir, MID, grandchild], nonce: depNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -(amount + fee) }],
    depositActions: [{ nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountDeposited: amount }],
  }, grandchild, user)
  if (!depResult.ok) throw new Error(`deposit failed: ${JSON.stringify(depResult.submit)}`)
  await waitFor(async () => {
    const r = await getDeposit(node, user.address, amount, swapNonceHex, grandchild)
    return r.exists ? r : null
  }, `deposit visible on ${grandchild}`, { timeoutMs: 60_000 })

  const recNonce = nextNonce[MID]++
  const recResult = await submitTx(node, {
    chainPath: [nexusDir, MID], nonce: recNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: -fee }],
    receiptActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, directory: grandchild }],
  }, MID, user)
  if (!recResult.ok) throw new Error(`receipt failed: ${JSON.stringify(recResult.submit)}`)
  await waitFor(async () => {
    const r = await getReceipt(node, user.address, amount, swapNonceHex, grandchild)
    return r.exists ? r : null
  }, `receipt visible for ${grandchild}`, { timeoutMs: 60_000 })

  const wdNonce = nextNonce[grandchild]++
  const wdResult = await submitTx(node, {
    chainPath: [nexusDir, MID, grandchild], nonce: wdNonce, signers: [user.address], fee,
    accountActions: [{ owner: user.address, delta: amount - fee }],
    withdrawalActions: [{ withdrawer: user.address, nonce: swapNonceHex, demander: user.address, amountDemanded: amount, amountWithdrawn: amount }],
  }, grandchild, user)
  if (!wdResult.ok) throw new Error(`withdrawal failed: ${JSON.stringify(wdResult.submit)}`)
  await waitFor(async () => {
    const r = await getDeposit(node, user.address, amount, swapNonceHex, grandchild)
    return !r.exists
  }, `deposit consumed on ${grandchild}`, { timeoutMs: 60_000 })

  console.log(`    ✓ cycle complete`)
}

console.log(`\n[F] Running 3 cycles on ${ALPHA}...`)
for (let i = 0; i < 3; i++) await runCycle(ALPHA, i)

console.log(`\n[G] Running 3 cycles on ${BETA}...`)
for (let i = 0; i < 3; i++) await runCycle(BETA, i + 100)

await sleep(4000)
const userMid1 = await getBalance(node, user.address, MID)
const userAlpha1 = await getBalance(node, user.address, ALPHA)
const userBeta1 = await getBalance(node, user.address, BETA)

console.log(`\n=== RESULTS ===`)
console.log(`${MID}     before=${userMid0}  after=${userMid1}  delta=${userMid1 - userMid0}`)
console.log(`${ALPHA}   before=${userAlpha0}  after=${userAlpha1}  delta=${userAlpha1 - userAlpha0}`)
console.log(`${BETA}    before=${userBeta0}  after=${userBeta1}  delta=${userBeta1 - userBeta0}`)
console.log(`✓ receipt state lived on ${MID} (intermediate parent), validating tree-walk in withdrawalsAreValid`)

node.stop()
await sleep(500)
process.exit(0)
