# lattice-node smoke tests

End-to-end scenarios that spawn real `LatticeNode` binaries, hit real RPC, and
assert observable chain state. Each scenario is hermetic: it owns its
`SMOKE_ROOT`, allocates a non-overlapping port range, and tears down its own
processes on exit, SIGINT, or uncaughtException.

## Architecture

The harness only talks to the node via three surfaces — RPC, the CLI, and
on-disk artifacts under the data directory. There are no language-level
imports of node internals, so this directory is portable to any future node
implementation.

```
SmokeTests/
├── lib/                  # shared harness — node lifecycle, RPC, wallet, probes
├── scenarios/
│   ├── swap/             # cross-chain deposit→receipt→withdrawal cycles
│   ├── network/          # multi-node sync, late-join, partition, mesh convergence
│   ├── follower/         # subscription gate, stateless mode
│   ├── persistence/      # restart resilience
│   └── liveness/         # long-running RSS + height-progress
└── run.mjs               # orchestrator (sequential per-scenario, fresh tmp dir each)
```

Scenario files are self-contained and can be run individually.

## Running

```bash
swift build                    # produce .build/debug/LatticeNode
cd SmokeTests
npm install
npm run all                    # default tier — under ~5 min
npm run swap                   # one scenario
SMOKE_FILTER=swap npm run all  # only matching scenarios
SMOKE_FAIL_FAST=1 npm run all  # stop on first failure
SMOKE_STABILITY=1 npm run all  # also run the 30-min stability test
```

## Environment variables

| var | meaning |
|---|---|
| `LATTICE_NODE_BIN` | path to the binary (default: `../.build/debug/LatticeNode`) |
| `SMOKE_ROOT` | per-scenario tmp dir (set by `run.mjs`; defaults under `/tmp/` for standalone) |
| `SMOKE_PORT_SEED` | shifts every scenario's port range — for parallel runs |
| `SMOKE_FILTER` | regex; only matching scenarios run |
| `SMOKE_FAIL_FAST` | `1` to stop on first failure |
| `SMOKE_STABILITY` | `1` to enable `stability-multichain` |
| `SMOKE_DURATION_MIN` | duration for stability test (default 30) |
