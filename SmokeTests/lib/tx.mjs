// Transaction submission: prepare → sign → submit. Wrapped so scenarios stop
// reimplementing the three-step dance and the bodyCID/bodyData plumbing.

import { sign } from './wallet.mjs'

// keypair: { privateKey, publicKey }
// chain: target chain directory (string)
// body: { chainPath, nonce, signers, fee, accountActions?, depositActions?, receiptActions?, withdrawalActions? }
export async function submitTx(node, body, chain, keypair) {
  const prep = await node.rpc('POST', '/api/transaction/prepare', body)
  if (!prep.ok) throw new Error(`prepare(${chain}) failed: ${JSON.stringify(prep.json)}`)
  const signature = sign(prep.json.bodyCID, keypair.privateKey)
  const sub = await node.rpc('POST', '/api/transaction', {
    signatures: { [keypair.publicKey]: signature },
    bodyCID: prep.json.bodyCID,
    bodyData: prep.json.bodyData,
    chain,
  })
  return { prepared: prep.json, submit: sub.json, ok: sub.ok }
}
