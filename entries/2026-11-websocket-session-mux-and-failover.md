# Head-of-line blocking, a 130 vs 120 double-billing leak, and 4.51 us warm-standby failover

*2026-11*

We built `stanza-mux`, a zero-dependency Rust stateful WebSocket session
multiplexer, warm worker pool lease manager, and SHA-256 usage-metering ledger
for pipelined command streams. Along the way a sequential wait loop caused a
30.5x p95 latency stall under bimodal workloads, and our first stop-on-error
batch rollback leaked 10 uncommitted usage events into the billing ledger.

## Method

- `stanza-mux` frames every request and response with a 52-byte little-endian
  `SMUX` header (`session_id: u128`, `cmd_id: u128`, `cmd_seq: u64`,
  `FrameKind`, `flags`, `payload_len: u32`) and a 4-byte masked Castagnoli
  CRC32C trailer.
- Each session admits up to `max_in_flight_per_session` (`32` by default)
  pipelined commands concurrently and completes them out-of-order by `cmd_id`.
- Completed commands are retained in a bounded per-session replay window keyed
  by both `cmd_id -> (request_sha256, MuxFrame)` and `cmd_seq`. When a client
  reconnects with `FrameKind::Resume(last_acked_seq)` or retries a `cmd_id`,
  the multiplexer returns the cached response with `FLAG_REPLAYED` without
  re-executing on the worker or double-billing.
- State-mutating commands (`FLAG_STATE_MUTATING`) append to the session's
  `JournalMutation` log. When an active worker crashes or misses its heartbeat,
  `WorkerPool` promotes a pre-warmed standby worker and replays the session's
  mutation journal before serving the next command.
- We verified the state machine with a 1,000-seed SplitMix64 Deterministic
  Simulation Testing (DST) harness (`0x5a4f4f5f534d5558..+1000`, 200 steps per
  seed, 200,000 steps) and ran a 100,000-command benchmark under `rustc 1.99.1
  --release`.

## Results

Deterministic simulation across 1,000 seeds (`0.38 s` wall time, `522,811 steps/s`):

| metric | count |
|---|---:|
| seeds verified | 1,000 / 1,000 |
| simulation steps | 200,000 |
| pipelined commands completed | 137,749 |
| out-of-order completions verified | 132,035 |
| reconnect `Resume` and retry replays served | 22,446 |
| mid-session worker crashes recovered via warm standby | 15,931 |
| worker state mutations replayed on failover | 72,611 |
| atomic batch rollbacks verified | 12,116 |
| 1-bit wire corruptions injected and caught by CRC32C | 11,948 / 11,948 |
| SHA-256 metering chains verified | 1,000 |
| invariant failures | 0 |

Benchmark across 100,000 pipelined commands (`window = 32`):

| operation | throughput | p50 | p99 | p999 |
|---|---:|---:|---:|---:|
| frame encode + CRC32C + decode + mux + SHA-256 metering | 534,028 cmds/s | 1,708 ns | 2,816 ns | 16,242 ns |
| warm-standby worker failover (64-mutation journal replay) | n/a | 4.51 us | 8.53 us | 94.71 us |

Head-of-line blocking comparison on a 10,000-command bimodal stream (95% fast
`400 us` queries, 5% heavy `15,000 us` state mutations across a 32-command
window):

| dispatch model | p50 wait | p95 wait | p95 reduction |
|---|---:|---:|---:|
| sequential wait-per-command (`SendCmd` then blocking `GetResponse`) | 6,415 us | 15,243 us | 1.0x |
| multiplexed out-of-order completion (`SessionMux`) | 448 us | 499 us | 30.5x |

## What we learned

First, in a single-actor WebSocket session loop that processes `SendCommand`
followed by a blocking `GetResponse(cmd_id)` before reading the next request
from its channel, callers cannot pipeline commands without head-of-line
blocking. Whenever one heavy command (`15 ms`) lands in a 32-command burst,
every subsequent fast inspection query (`400 us`) queues behind it, pushing p95
latency from `499 us` to `15,243 us` (`30.5x`). Separating command admission
(`submit_command`) from out-of-order completion (`complete_command(cmd_id)`)
lets fast read-only queries return while the heavy mutation is still running.

Second, our first implementation of stop-on-first-failure batches
(`FrameKind::Batch` with `FLAG_STOP_ON_ERROR`) executed sub-commands eagerly
through `complete_command` and truncated `session.mutation_journal` + restored
the worker's `state_fingerprint` when sub-command `k` failed. During the first
100-seed DST run, the harness panicked with `assertion failed: metering ledger
must bill each unique completed command exactly once (left: 130, right: 120)`.
Rolling back the worker and mutation journal did not roll back the append-only
SHA-256 `MeteringLedger`, so sub-command `0` of each aborted batch was still
billed (`10` aborted batches = `10` phantom billing events). Switching
`execute_batch` to a two-phase stage-and-validate pass before committing to
`complete_command` eliminated the phantom billing events while preserving
append-only hash-chain integrity.

Third, replaying state-mutating commands onto a pre-warmed standby worker took
`4.51 us` at p50 (`8.53 us` at p99) for a 64-mutation session journal, five
orders of magnitude faster than cold-starting a fresh worker process on
disconnect.

## What changed as a result

- `SessionMux::submit_command` and `SessionMux::complete_command` decouple
  admission from completion using a per-session `BTreeMap<u128, InFlightCommand>`
  window capped at `max_in_flight_per_session`.
- `SessionMux::execute_batch` runs a two-phase validation pass over all
  sub-commands before committing mutations to the worker state, replay journal,
  or SHA-256 `MeteringLedger`.
- `WorkerPool::evict_and_failover` automatically promotes a `WarmIdle` standby
  worker and replays the session's `JournalMutation` log on primary worker
  eviction.

## Reproduce it

```bash
git clone https://github.com/StanzaAPI/stanza-mux
cd stanza-mux
cargo test --release
cargo run --release -- dst --seeds 1000 --steps 200
cargo run --release -- bench --commands 100000 --window 32
```

Source: [StanzaAPI/stanza-mux](https://github.com/StanzaAPI/stanza-mux).

## Open items

- Session mutation journals grow linearly with the number of state-mutating
  commands in a session; adding periodic worker state checkpoints would cap
  journal replay length for multi-hour sessions.
- `MeteringLedger` stores events in memory and exports deterministic JSON
  rollups; wiring `MeteringLedger` directly into `stanza-lsm` `WriteBatch`
  commits will persist billing anchors across gateway restarts.
