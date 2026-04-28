// Poll-with-deadline, the only "wait" primitive scenarios should use.
// Sleeps mask flakes; deadlines surface them with informative messages.

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export async function waitFor(fn, desc, { timeoutMs = 30_000, intervalMs = 500 } = {}) {
  const start = Date.now()
  let lastErr
  while (Date.now() - start < timeoutMs) {
    try {
      const r = await fn()
      if (r !== null && r !== undefined && r !== false) return r
    } catch (e) {
      lastErr = e
    }
    await sleep(intervalMs)
  }
  const tail = lastErr ? ` (last error: ${lastErr.message})` : ''
  throw new Error(`timed out after ${timeoutMs}ms: ${desc}${tail}`)
}
