// Multi-chain stability: one node mines Nexus + 3 child chains for SMOKE_DURATION_MIN
// minutes (default 30). Asserts every chain keeps advancing and peak RSS stays
// under 2× steady-state baseline (caught the multi-chain leak class that
// triggered UNSTOPPABLE_LATTICE).
//
// Long-running by default — opt in via SMOKE_STABILITY=1.

import { allocPorts, smokeRoot } from '../../lib/env.mjs'
import { singleNode } from '../../lib/node.mjs'
import { sleep } from '../../lib/waitFor.mjs'
import { chainInfo, deployChild, startMining } from '../../lib/chain.mjs'
import { rssBytes } from '../../lib/probe.mjs'

if (process.env.SMOKE_STABILITY !== '1') {
  console.log('skipping stability-multichain (set SMOKE_STABILITY=1 to run; long-running)')
  process.exit(0)
}

const ROOT = smokeRoot('stability-multichain')
const [{ port, rpcPort }] = allocPorts(1, { seed: 5 })
const DURATION_MIN = Number(process.env.SMOKE_DURATION_MIN || 30)
const SAMPLE_INTERVAL_S = 30
const WARMUP_S = 60
const RSS_RATIO_LIMIT = 2.0
const CHAINS = ['Alpha', 'Beta', 'Gamma']

console.log(`=== stability-multichain smoke (${DURATION_MIN}min, ${CHAINS.length + 1} chains) ===`)
const node = singleNode({ root: ROOT, port, rpcPort })
node.start()
const aBoot = await node.waitForRPC()
const nexusDir = aBoot.nexus
await node.readIdentity()

console.log(`\n[2] Deploy ${CHAINS.length} child chains...`)
for (const dir of CHAINS) {
  await deployChild(node, { directory: dir, parentDirectory: nexusDir, premine: 0 })
}
await startMining(node, nexusDir)

console.log(`\n[3] Warmup ${WARMUP_S}s before sampling baseline RSS...`)
await sleep(WARMUP_S * 1000)

const samples = []
async function sample() {
  const info = await chainInfo(node)
  const heights = {}
  for (const c of info?.chains ?? []) heights[c.directory] = c.height
  const rss = rssBytes(node.pid)
  return { t: Date.now(), rss, heights }
}

const baseline = await sample()
samples.push(baseline)
console.log(`  baseline RSS=${(baseline.rss / 1024 / 1024).toFixed(1)}MB heights=${JSON.stringify(baseline.heights)}`)

const endAt = Date.now() + DURATION_MIN * 60 * 1000
let peakRSS = baseline.rss
let stallDetected = null

while (Date.now() < endAt) {
  const remaining = endAt - Date.now()
  await sleep(Math.min(SAMPLE_INTERVAL_S * 1000, remaining))
  const s = await sample()
  samples.push(s)
  const prev = samples[samples.length - 2]
  const rssMB = (s.rss / 1024 / 1024).toFixed(1)
  const ratio = (s.rss / baseline.rss).toFixed(2)
  if (s.rss > peakRSS) peakRSS = s.rss

  for (const dir of [nexusDir, ...CHAINS]) {
    const before = prev.heights[dir] ?? 0
    const after = s.heights[dir] ?? 0
    if (after <= before) {
      stallDetected = stallDetected || `${dir} stalled at height ${after} (was ${before})`
    }
  }

  const elapsedMin = ((Date.now() - baseline.t) / 60000).toFixed(1)
  console.log(`  t=${elapsedMin}m RSS=${rssMB}MB (${ratio}× baseline) heights=${JSON.stringify(s.heights)}`)
  if (stallDetected) break
}

node.stop()
await sleep(500)

if (stallDetected) {
  console.error(`\n  ✗ stall: ${stallDetected}`)
  console.error(`    inspect ${ROOT}/node.log`)
  process.exit(1)
}

const peakRatio = peakRSS / baseline.rss
const peakMB = (peakRSS / 1024 / 1024).toFixed(1)
console.log(`\n  baseline RSS ${(baseline.rss / 1024 / 1024).toFixed(1)}MB → peak ${peakMB}MB (${peakRatio.toFixed(2)}× baseline)`)
if (peakRatio > RSS_RATIO_LIMIT) {
  console.error(`  ✗ RSS exceeded ${RSS_RATIO_LIMIT}× steady-state — multi-chain leak suspected`)
  process.exit(1)
}

const last = samples[samples.length - 1]
const advanced = Object.fromEntries(
  Object.entries(last.heights).map(([d, h]) => [d, h - (baseline.heights[d] ?? 0)]),
)
console.log(`  height progress over run: ${JSON.stringify(advanced)}`)
console.log('\n✓ stability-multichain smoke test passed.')
process.exit(0)
