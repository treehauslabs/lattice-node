# Lattice Node RPC API

Base URL: `http://localhost:<rpc-port>`

## Authentication

When `--rpc-auth` is enabled, include the cookie token:
```
Authorization: Bearer <token from ~/.lattice/.cookie>
```

## Chain

### GET /api/chain/info
Returns status of all chains.

```json
{
  "chains": [
    {
      "directory": "Nexus",
      "height": 1234,
      "tip": "baguqeera...",
      "mining": true,
      "mempoolCount": 5,
      "syncing": false
    }
  ],
  "genesisHash": "baguqeera..."
}
```

### GET /api/chain/spec
Returns chain specification parameters.

```json
{
  "directory": "Nexus",
  "targetBlockTime": 10000,
  "initialReward": 1048576,
  "halvingInterval": 17592186044416,
  "maxTransactionsPerBlock": 5000,
  "maxStateGrowth": 3000000,
  "maxBlockSize": 10000000,
  "premine": 3518437208883,
  "premineAmount": 3689348814741700608
}
```

## Accounts

### GET /api/balance/{address}
```json
{"address": "baguqeera...", "balance": 1048576}
```

### GET /api/nonce/{address}
```json
{"address": "baguqeera...", "nonce": 0}
```

### GET /api/proof/{address}
Returns a balance proof for light client verification.

## Blocks

### GET /api/block/latest
```json
{"hash": "baguqeera...", "index": 1234, "timestamp": 1742601600000, "difficulty": "ff..."}
```

### GET /api/block/{id}
Fetch by hash or height. Returns block header fields.

## Transactions

### POST /api/transaction
Submit a signed transaction.

**Request:**
```json
{
  "signatures": {"<publicKeyHex>": "<signatureHex>"},
  "bodyCID": "<cid>",
  "bodyData": "<hex-encoded body>"
}
```

**Response:**
```json
{"accepted": true, "txCID": "baguqeera...", "error": null}
```

### GET /api/receipt/{txCID}
Returns transaction receipt (derived from CAS).

```json
{
  "txCID": "baguqeera...",
  "blockHash": "baguqeera...",
  "blockHeight": 42,
  "timestamp": 1742601600000,
  "fee": 100,
  "sender": "baguqeera...",
  "status": "confirmed",
  "accountActions": [
    {"owner": "baguqeera...", "oldBalance": 1000, "newBalance": 900}
  ]
}
```

### GET /api/mempool
```json
{"count": 5, "totalFees": 500}
```

## Fee Market

### GET /api/fee/estimate?target=N
Estimate fee for confirmation within N blocks.

```json
{"fee": 42, "target": 5}
```

### GET /api/fee/histogram
Fee distribution across recent blocks.

```json
{
  "buckets": [{"range": "1-10", "count": 150}],
  "blockCount": 100
}
```

## DEX (Batch Auction)

### GET /api/orders
Active orders on the DEX.

### POST /api/orders
Place an order directly.

### POST /api/orders/commit
Submit a blinded order commitment (MEV protection).

```json
{"commitHash": "<hash>", "sender": "<address>"}
```

### POST /api/orders/reveal
Reveal a previously committed order after the auction window.

```json
{
  "commitHash": "<hash>",
  "side": "buy",
  "price": 100,
  "amount": 10,
  "owner": "<address>",
  "salt": "<random>"
}
```

## Light Client

### GET /api/light/headers?from=X&to=Y
Block headers for light client sync (max 1000 per request).

### GET /api/light/proof/{address}
Account proof with block context for independent verification.

## Network

### GET /api/peers
```json
{"count": 12, "peers": [{"publicKey": "abcd...", "host": "1.2.3.4", "port": 4001}]}
```

## Observability

### GET /metrics
Prometheus-format metrics.

```
lattice_blocks_accepted_total 1234
lattice_chain_height{chain="Nexus"} 1234
lattice_mempool_size{chain="Nexus"} 5
lattice_mining_active{chain="Nexus"} 1
lattice_transactions_submitted_total 5678
```

### GET /ws
WebSocket endpoint (planned). Returns 501 currently.
