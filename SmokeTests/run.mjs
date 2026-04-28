// Smoke-test orchestrator.
//
// Runs every scenario sequentially with a fresh tmp dir per test, prints
// per-test pass/fail with wall-clock time, and exits non-zero on any failure.
// Long-running tests (stability-multichain) are skipped unless gated env vars
// are set; default invocation is under ~5 minutes.
//
// Usage:
//   node run.mjs                          # default tier
//   SMOKE_STABILITY=1 node run.mjs        # also run the stability test
//   SMOKE_FILTER=swap node run.mjs        # run tests whose name matches /swap/
//   SMOKE_FAIL_FAST=1 node run.mjs        # stop on first failure

import { spawn } from 'node:child_process'
import { existsSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const FILTER = process.env.SMOKE_FILTER ? new RegExp(process.env.SMOKE_FILTER) : null
const FAIL_FAST = process.env.SMOKE_FAIL_FAST === '1'

// Order: cheap correctness tests first, expensive/long-running last. Each
// scenario gets its own port range via a per-scenario seed (in env.mjs);
// orchestrator just sets SMOKE_ROOT.
const TESTS = [
  { name: 'multinode-convergence', file: 'scenarios/network/multinode-convergence.mjs', timeoutMs: 90_000 },
  { name: 'sync',                  file: 'scenarios/network/sync.mjs',                  timeoutMs: 120_000 },
  { name: 'late-joiner',           file: 'scenarios/network/late-joiner.mjs',           timeoutMs: 240_000 },
  { name: 'partition',             file: 'scenarios/network/partition.mjs',             timeoutMs: 240_000 },
  { name: 'parent-dependency',     file: 'scenarios/follower/parent-dependency.mjs',    timeoutMs: 300_000 },
  { name: 'stateless-cli',         file: 'scenarios/follower/stateless-cli.mjs',        timeoutMs: 60_000 },
  { name: 'stateless-follower',    file: 'scenarios/follower/stateless-follower.mjs',   timeoutMs: 360_000 },
  { name: 'restart-resilience',    file: 'scenarios/persistence/restart-resilience.mjs', timeoutMs: 360_000 },
  { name: 'swap',                  file: 'scenarios/swap/swap.mjs',                     timeoutMs: 180_000 },
  { name: 'variable-rate-swap',    file: 'scenarios/swap/variable-rate-swap.mjs',       timeoutMs: 180_000 },
  { name: 'grandchild-swap',       file: 'scenarios/swap/grandchild-swap.mjs',          timeoutMs: 240_000 },
  { name: 'multidepth-swap',       file: 'scenarios/swap/multidepth-swap.mjs',          timeoutMs: 300_000 },
  { name: 'bad-signature',         file: 'scenarios/safety/bad-signature.mjs',          timeoutMs: 60_000 },
  { name: 'double-spend',          file: 'scenarios/safety/double-spend.mjs',           timeoutMs: 120_000 },
  { name: 'nonce-edge-cases',      file: 'scenarios/safety/nonce-edge-cases.mjs',       timeoutMs: 180_000 },
  { name: 'rpc-idempotency',       file: 'scenarios/safety/rpc-idempotency.mjs',        timeoutMs: 120_000 },
  { name: 'swap-violations',       file: 'scenarios/safety/swap-violations.mjs',        timeoutMs: 300_000 },
  { name: 'fee-bounds',             file: 'scenarios/safety/fee-bounds.mjs',              timeoutMs: 180_000 },
  { name: 'balance-overdraft',      file: 'scenarios/safety/balance-overdraft.mjs',       timeoutMs: 180_000 },
  { name: 'supply-conservation',   file: 'scenarios/safety/supply-conservation.mjs',    timeoutMs: 600_000 },
  { name: 'mempool-propagation',   file: 'scenarios/safety/mempool-propagation.mjs',    timeoutMs: 300_000 },
  { name: 'sigterm-under-load',    file: 'scenarios/persistence/sigterm-under-load.mjs', timeoutMs: 360_000 },
  { name: 'finality',              file: 'scenarios/rpc/finality.mjs',                  timeoutMs: 180_000 },
  { name: 'fee-and-rbf',           file: 'scenarios/rpc/fee-and-rbf.mjs',               timeoutMs: 180_000 },
  { name: 'health-and-metrics',    file: 'scenarios/rpc/health-and-metrics.mjs',         timeoutMs: 180_000 },
  { name: 'block-explorer',        file: 'scenarios/rpc/block-explorer.mjs',             timeoutMs: 180_000 },
  { name: 'chain-spec',            file: 'scenarios/rpc/chain-spec.mjs',                 timeoutMs: 180_000 },
  { name: 'balance-proof',         file: 'scenarios/rpc/balance-proof.mjs',              timeoutMs: 180_000 },
  { name: 'difficulty-adjustment', file: 'scenarios/rpc/difficulty-adjustment.mjs',      timeoutMs: 360_000 },
  { name: 'concurrent-senders',   file: 'scenarios/safety/concurrent-senders.mjs',      timeoutMs: 180_000 },
  { name: 'premine-correctness',  file: 'scenarios/safety/premine-correctness.mjs',     timeoutMs: 180_000 },
  { name: 'large-block',          file: 'scenarios/safety/large-block.mjs',             timeoutMs: 300_000 },
  { name: 'deploy-under-load',    file: 'scenarios/safety/deploy-under-load.mjs',       timeoutMs: 300_000 },
  { name: 'reorg-state-rollback', file: 'scenarios/safety/reorg-state-rollback.mjs',    timeoutMs: 360_000 },
  { name: 'stability-multichain',  file: 'scenarios/liveness/stability-multichain.mjs', timeoutMs: 35 * 60_000, gated: 'SMOKE_STABILITY' },
]

const RUN_ID = `${Date.now()}-${process.pid}`
const RUN_ROOT = `/tmp/smoke-all-${RUN_ID}`

function fmtMs(ms) {
  if (ms < 1000) return `${ms}ms`
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60_000).toFixed(1)}m`
}

async function runOne(test) {
  const filePath = join(HERE, test.file)
  if (!existsSync(filePath)) return { skipped: true, reason: 'missing' }
  if (test.gated && process.env[test.gated] !== '1') {
    return { skipped: true, reason: `gated by ${test.gated}=1` }
  }

  const root = `${RUN_ROOT}/${test.name}`
  rmSync(root, { recursive: true, force: true })
  const start = Date.now()
  const env = { ...process.env, SMOKE_ROOT: root }
  const child = spawn(process.execPath, [filePath], {
    stdio: ['ignore', 'pipe', 'pipe'], env,
  })
  let stdout = '', stderr = ''
  child.stdout.on('data', (d) => { stdout += d })
  child.stderr.on('data', (d) => { stderr += d })

  const timer = setTimeout(() => { try { child.kill('SIGKILL') } catch {} }, test.timeoutMs)
  const code = await new Promise((resolve) => child.on('exit', resolve))
  clearTimeout(timer)
  const ms = Date.now() - start
  return { ok: code === 0, code, ms, stdout, stderr, root }
}

console.log(`=== smoke-all ===  run=${RUN_ID}  root=${RUN_ROOT}\n`)

const results = []
for (const test of TESTS) {
  if (FILTER && !FILTER.test(test.name)) {
    results.push({ test, skipped: true, reason: 'filter' })
    continue
  }
  process.stdout.write(`▶ ${test.name.padEnd(28)}  `)
  const r = await runOne(test)
  if (r.skipped) {
    console.log(`SKIP (${r.reason})`)
    results.push({ test, ...r })
    continue
  }
  if (r.ok) {
    console.log(`PASS  ${fmtMs(r.ms)}`)
  } else {
    console.log(`FAIL  ${fmtMs(r.ms)}  exit=${r.code}`)
    const tail = (r.stdout + r.stderr).split('\n').slice(-15).join('\n')
    console.log(tail.split('\n').map((l) => `    ${l}`).join('\n'))
    console.log(`    artifacts: ${r.root}`)
  }
  results.push({ test, ...r })
  if (FAIL_FAST && !r.ok) break
}

const ran = results.filter((r) => !r.skipped)
const passed = ran.filter((r) => r.ok)
const failed = ran.filter((r) => !r.ok)
const skipped = results.filter((r) => r.skipped)
const totalMs = ran.reduce((a, r) => a + (r.ms || 0), 0)

console.log(`\n=== summary ===`)
console.log(`  ${ran.length} ran, ${passed.length} passed, ${failed.length} failed, ${skipped.length} skipped`)
console.log(`  wall-clock: ${fmtMs(totalMs)}`)
if (failed.length) {
  console.log(`  failed: ${failed.map((f) => f.test.name).join(', ')}`)
  console.log(`  inspect artifacts under ${RUN_ROOT}`)
}

process.exit(failed.length ? 1 : 0)
