// Node lifecycle + RPC client. Every scenario uses this to spawn nodes,
// teardown is centralized so signal handlers don't leak between scenarios.

import { spawn } from 'node:child_process'
import { readFileSync, mkdirSync, createWriteStream, rmSync, existsSync } from 'node:fs'
import { BIN, requireBinary } from './env.mjs'
import { sleep, waitFor } from './waitFor.mjs'

export class Node {
  // opts: { name, dir, port, rpcPort }
  constructor(opts) {
    this.name = opts.name
    this.dir = opts.dir
    this.port = opts.port
    this.rpcPort = opts.rpcPort
    this.proc = null
    this.logStream = null
    this._identity = null
  }

  get logPath() { return `${this.dir}/../${this.name}.log` }
  get base() { return `http://127.0.0.1:${this.rpcPort}` }
  get pid() { return this.proc?.pid }

  // extras: { peers?: [Node|peerArg], subscribe?: ['Nexus/Foo', ...], extraArgs?: [] }
  // Append-mode log so restart() preserves prior output.
  start(extras = {}) {
    requireBinary()
    mkdirSync(this.dir, { recursive: true })
    const args = [
      'node',
      '--port', String(this.port),
      '--rpc-port', String(this.rpcPort),
      '--data-dir', this.dir,
      '--no-dns-seeds',
    ]
    for (const peer of extras.peers ?? []) {
      args.push('--peer', typeof peer === 'string' ? peer : peer.peerArg())
    }
    for (const sub of extras.subscribe ?? []) {
      args.push('--subscribe', sub)
    }
    if (extras.extraArgs) args.push(...extras.extraArgs)

    this.logStream = createWriteStream(this.logPath, { flags: 'a' })
    const env = extras.env ? { ...process.env, ...extras.env } : undefined
    this.proc = spawn(BIN, args, { stdio: ['ignore', 'pipe', 'pipe'], env })
    this.proc.stdout.pipe(this.logStream)
    this.proc.stderr.pipe(this.logStream)
    this.proc.on('exit', (code) => {
      console.log(`[${this.name}] exited code=${code}`)
      this.proc = null
    })
    return this
  }

  stop() {
    if (!this.proc) return
    try { this.proc.kill('SIGTERM') } catch {}
    this.proc = null
  }

  // Stop and poll the RPC port until it stops responding. Required before
  // re-spawning against the same port — without it, restart() races the OS
  // socket teardown.
  async stopAndAwaitShutdown({ timeoutMs = 30_000 } = {}) {
    this.stop()
    const start = Date.now()
    while (Date.now() - start < timeoutMs) {
      try {
        await fetch(`${this.base}/api/chain/info`, { signal: AbortSignal.timeout(500) })
      } catch {
        return
      }
      await sleep(500)
    }
    throw new Error(`${this.name} failed to shut down within ${timeoutMs}ms`)
  }

  async restart(extras) {
    await this.stopAndAwaitShutdown()
    return this.start(extras)
  }

  async rpc(method, path, body) {
    try {
      const res = await fetch(`${this.base}${path}`, {
        method,
        headers: body ? { 'content-type': 'application/json' } : undefined,
        body: body ? JSON.stringify(body) : undefined,
      })
      const text = await res.text()
      let json
      try { json = JSON.parse(text) } catch { json = { _raw: text } }
      return { ok: res.ok, status: res.status, json }
    } catch (e) {
      return { ok: false, status: 0, json: { error: String(e) } }
    }
  }

  async waitForRPC(timeoutMs = 60_000) {
    return waitFor(async () => {
      const r = await this.rpc('GET', '/api/chain/info')
      return r.ok ? r.json : null
    }, `${this.name} RPC`, { timeoutMs, intervalMs: 500 })
  }

  async readIdentity(timeoutMs = 30_000) {
    if (this._identity) return this._identity
    const id = await waitFor(() => {
      try {
        const parsed = JSON.parse(readFileSync(`${this.dir}/identity.json`, 'utf8'))
        return parsed.publicKey ? parsed : null
      } catch { return null }
    }, `${this.name} identity.json`, { timeoutMs, intervalMs: 200 })
    this._identity = id
    return id
  }

  // <pubkey>@127.0.0.1:<port> — for use in --peer args.
  peerArg() {
    if (!this._identity) throw new Error(`${this.name}.readIdentity() must be called before peerArg()`)
    return `${this._identity.publicKey}@127.0.0.1:${this.port}`
  }
}

// A set of nodes, with one teardown handler that fires on SIGINT or
// uncaughtException so leftover processes don't survive scenario crashes.
export class Network {
  // opts: { root, nodes: [{name,port,rpcPort}, ...] }
  constructor({ root, nodes }) {
    this.root = root
    this.nodes = nodes.map((n) => new Node({ ...n, dir: `${root}/${n.name}` }))
    this._installed = false
  }

  static fresh(opts) {
    rmSync(opts.root, { recursive: true, force: true })
    mkdirSync(opts.root, { recursive: true })
    const net = new Network(opts)
    net._installSignalHandlers()
    return net
  }

  byName(name) {
    const n = this.nodes.find((x) => x.name === name)
    if (!n) throw new Error(`no node named ${name}`)
    return n
  }

  teardown() {
    for (const n of this.nodes) n.stop()
  }

  _installSignalHandlers() {
    if (this._installed) return
    this._installed = true
    process.on('SIGINT', () => { this.teardown(); process.exit(1) })
    process.on('uncaughtException', (e) => {
      console.error(e); this.teardown(); process.exit(1)
    })
  }
}

// Convenience for single-node scenarios.
export function singleNode({ root, name = 'node', port, rpcPort }) {
  if (existsSync(root)) rmSync(root, { recursive: true, force: true })
  const net = Network.fresh({ root, nodes: [{ name, port, rpcPort }] })
  return net.byName(name)
}
