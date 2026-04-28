// Stateless-mode CLI surface:
//   1. `node --stateless --mine X` is rejected with a clear error.
//   2. `node --stateless` boots, logs "(stateless)", and serves RPC.

import { execSync, spawn } from 'node:child_process'
import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot, BIN, requireBinary } from '../../lib/env.mjs'
import { sleep, waitFor } from '../../lib/waitFor.mjs'

requireBinary()
const ROOT = smokeRoot('stateless-cli')
const [{ port, rpcPort }] = allocPorts(1, { seed: 7 })
const DIR = `${ROOT}/s`

console.log('=== stateless-mode CLI smoke test ===')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(DIR, { recursive: true })

console.log('\n[1] `--stateless --mine Nexus` is rejected...')
let rejectedOK = false
try {
  const out = execSync(
    `${BIN} node --data-dir ${DIR}/reject --port 4099 --stateless --mine Nexus`,
    { stdio: 'pipe', timeout: 10_000 },
  ).toString()
  console.log(`  UNEXPECTED exit 0; stdout:\n${out}`)
} catch (e) {
  const combined = (e.stdout?.toString() || '') + (e.stderr?.toString() || '')
  if (combined.includes('incompatible with --mine')) {
    console.log(`  ✓ rejected with expected message`)
    rejectedOK = true
  } else {
    console.log(`  ✗ non-zero exit, but missing expected message:\n${combined}`)
  }
}
if (!rejectedOK) { console.error('✗ test 1 failed'); process.exit(1) }

console.log('\n[2] `--stateless` boots cleanly and RPC responds...')
const args = [
  'node', '--port', String(port), '--rpc-port', String(rpcPort),
  '--data-dir', DIR, '--no-dns-seeds', '--stateless',
]
console.log(`  ${BIN} ${args.join(' ')}`)
const p = spawn(BIN, args, { stdio: ['ignore', 'pipe', 'pipe'] })
let outBuf = ''
p.stdout.on('data', (d) => { outBuf += d.toString() })
p.stderr.on('data', (d) => { outBuf += d.toString() })
process.on('exit', () => { try { p.kill('SIGTERM') } catch {} })

await waitFor(async () => {
  try {
    const res = await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)
    return res.ok ? true : null
  } catch { return null }
}, 'stateless node RPC up', { timeoutMs: 30_000, intervalMs: 500 })
console.log('  ✓ stateless node RPC up')

if (!outBuf.includes('(stateless)')) {
  console.error('  ✗ startup log missing "(stateless)" marker')
  console.log(outBuf.slice(0, 2000))
  p.kill('SIGTERM'); process.exit(1)
}
console.log('  ✓ log contains "(stateless)"')

const info = await (await fetch(`http://127.0.0.1:${rpcPort}/api/chain/info`)).json()
if (!info.nexus) {
  console.error('  ✗ /api/chain/info missing nexus:', info)
  p.kill('SIGTERM'); process.exit(1)
}
console.log(`  ✓ /api/chain/info nexus=${info.nexus}`)

p.kill('SIGTERM')
await sleep(500)
console.log('\n✓ stateless CLI surface works end-to-end.')
process.exit(0)
