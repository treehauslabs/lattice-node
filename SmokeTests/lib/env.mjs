// Environment + binary + port discovery. Centralizes the few magic strings
// every scenario needs so they aren't duplicated across files.

import { existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '..', '..')

export const BIN = process.env.LATTICE_NODE_BIN
  || resolve(REPO_ROOT, '.build/debug/LatticeNode')

export function requireBinary() {
  if (!existsSync(BIN)) {
    console.error(`lattice-node binary not found at ${BIN}`)
    console.error(`build it with: (cd ${REPO_ROOT} && swift build)`)
    process.exit(1)
  }
}

// Each scenario gets its own ROOT (set by run.mjs per-test, or defaulted for
// standalone runs). Per-test isolation is the contract.
export function smokeRoot(defaultName) {
  return process.env.SMOKE_ROOT || `/tmp/smoke-${defaultName}`
}

// Deterministic port allocator. Each scenario asks for N nodes and gets a
// non-overlapping (p2p, rpc) pair per node. Seed makes parallel runs trivial:
// `SMOKE_PORT_SEED=1 node scenario.mjs` shifts the whole range.
export function allocPorts(count, { seed } = {}) {
  const base = Number(process.env.SMOKE_PORT_SEED ?? seed ?? 0)
  const P2P_BASE = 4100 + base * 100
  const RPC_BASE = 8200 + base * 100
  return Array.from({ length: count }, (_, i) => ({
    port: P2P_BASE + i,
    rpcPort: RPC_BASE + i,
  }))
}
