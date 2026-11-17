# Torn WAL frames, a fake 0.000% Bloom filter, and a 29x compaction stall

*2026-11*

We built `stanza-lsm`, a zero-dependency Rust Write-Ahead Log and LSM-tree
storage engine for Stanza API idempotency keys, SHA-256 hash-chained audit logs,
and regulatory reference tables. Along the way our first benchmark reported a
0.000% Bloom filter false-positive rate and a 2.4 us `fdatasync` latency. Both
numbers were wrong.

## Method

- The engine writes single operations and multi-key `WriteBatch` records to
  `active.wal` with a 19-byte header and a masked Castagnoli CRC32C checksum.
- A BTree-backed MVCC Memtable orders keys by `(user_key ASC, seq DESC)` and
  flushes at 4 MiB to L0 SSTables. Each SSTable splits data into 4,096-byte
  blocks with 16-key prefix delta-compression, a 10-bit/key Kirsch-Mitzenmacher
  Bloom filter (`k = 7`), a sparse block index, and a 64-byte footer.
- Every data block, filter block, index block, and footer carries a masked
  CRC32C trailer verified on read.
- For fault injection we implemented `SimFs`, an in-memory file system that
  separates volatile OS page-cache bytes from durable disk bytes. On simulated
  power loss, `SimFs` drops un-synced directory renames and truncates or tears
  un-flushed WAL tails at a random byte offset before running recovery.
- We ran 1,000 deterministic simulation seeds (`0x5354414e5a412026..+1000`,
  200 steps per seed, 200,000 operations) against a reference `BTreeMap` oracle
  and historical snapshot map.
- We then ran the 100,000-record GLEIF LEI benchmark (`ref:lei:5493001KJTIIGC...`)
  on `/dev/nvme1n1p3` (btrfs on NVMe) under `rustc 1.99.1 --release`.

## Results

Deterministic simulation across 1,000 seeds (`2.65 s` wall time, `75,334 ops/s`):

| metric | count |
|---|---:|
| seeds verified | 1,000 / 1,000 |
| total operations | 200,000 |
| power-loss crashes simulated | 20,080 |
| torn WAL tails truncated and recovered | 12,093 |
| atomic `WriteBatch`es committed | 35,937 (0 partial batches) |
| MVCC snapshots verified across compaction | 2,299 |
| range and prefix scans verified | 35,055 |
| 1-bit SSTable corruptions injected and caught | 13,190 / 13,190 |
| invariant failures | 0 |

NVMe benchmark across 100,000 LEI records (`11.15 MB` logical, `44.25 MB` physical):

| operation | throughput | p50 | p99 | p999 |
|---|---:|---:|---:|---:|
| 100-record `WriteBatch` + `fdatasync` | 99,399 rec/s | 693.9 us | 2,894.2 us | 19,986.0 us |
| 1-record `put` + `fdatasync` | 1,786 rec/s | 559.7 us | 718.2 us | 5,906.0 us |
| point-hit lookup (linear index scan) | 132,720 ops/s | 7,029 ns | 23,748 ns | 32,377 ns |
| point-hit lookup (binary index search) | 761,577 ops/s | 648 ns | 12,080 ns | 13,559 ns |
| absent-key lookup (`[min_key, max_key]`) | 5,866,842 ops/s | 113 ns | 175 ns | 793 ns |

Storage efficiency:

| metric | value |
|---|---:|
| 16-key prefix compression (`2,800,000 B -> 324,684 B`) | 88.4% key reduction |
| Bloom filter rejections (`49,581 / 50,000` probes) | 0.838% FPR |
| write amplification (WAL + L0 flush + L1 compaction) | 3.97x |

## What we learned

Three things went wrong in the first benchmark run.

First, our initial absent-key benchmark inserted keys `0..100,000` and probed
absent keys `1,100,000..1,150,000`. Every absent probe sorted above the SSTable
`max_key`. `SstReader::get` checked `key > self.meta.max_key` on the first line
and returned before calling `BloomFilter::may_contain`. That bug produced a
50 ns lookup time and a 0.000% false-positive rate without executing a single
Bloom probe. Interleaving even present keys (`2i`) and odd absent keys (`2i + 1`)
forced every absent lookup inside `[min_key, max_key]` and exposed the true
0.838% false-positive rate (419 false positives out of 50,000 probes, matching
the 0.819% theoretical rate for 10 bits/key at `k = 7`).

Second, our first `SstReader::get` walked `self.index` with a `for` loop before
binary-searching inside the 4 KiB data block. After compacting 100,000 records
into L1, the sparse index held 2,700 block descriptors, and the linear scan
spent 6.4 us comparing block bounds on every hit. Switching `SstReader::get` and
`SstReader::range_visible` to `self.index.partition_point` dropped median
point-hit latency from 7,029 ns to 648 ns.

Third, `std::env::temp_dir()` placed the first benchmark directory on `/tmp`,
which is a RAM-backed `tmpfs` mount on our test host. On `tmpfs`, `fdatasync`
returned in 2.4 us and hid the hardware flush cost. Moving the benchmark
directory onto `/dev/nvme1n1p3` raised single-write `fdatasync` latency to
559.7 us at p50 and exposed a 29x tail spike on batched writes (`693.9 us` p50
vs `19,986.0 us` p999): every fourth 4 MiB Memtable flush crosses
`l0_compaction_trigger = 4` and merges 16 MiB into L1 on the caller's thread.

## What changed as a result

- `SstLookup` now separates `RangeFilteredOut` from `BloomFilteredOut` in
  `src/sst.rs` so `EngineMetrics::bloom_work_avoided` never counts range-guard
  short-circuits as Bloom filter hits.
- `SstReader::get` and `SstReader::range_visible` use `partition_point` binary
  search over the sparse block index.
- `stanza-lsm bench` interleaves even present keys (`2i`) with odd absent keys
  (`2i + 1`) and defaults its working directory to the current disk mount
  instead of `/tmp`.
- `LsmEngine::compact` accepts a `force` flag so callers that drop MVCC
  snapshots can force a single-SSTable L1 pass to purge tombstones immediately.

## Reproduce it

```bash
git clone https://github.com/StanzaAPI/stanza-lsm
cd stanza-lsm
cargo test --release
cargo run --release -- dst --seeds 1000 --steps 200
cargo run --release -- bench --records 100000
```

Source: [StanzaAPI/stanza-lsm](https://github.com/StanzaAPI/stanza-lsm).

## Open items

- Compaction runs synchronously on the writer thread when `L0` reaches four
  files, causing the 19.99 ms p999 stall. Moving L0-to-L1 compaction onto a
  background thread with L0 write throttling is the next step.
- Data blocks use prefix delta-compression on keys and store values raw. Adding
  LZ4 block compression would shrink JSON reference payloads further.
- `PosixFs` uses buffered `read_range` (`seek` + `read_exact`) per block cache
  miss. Switching to `std::os::unix::fs::FileExt::read_exact_at` (`pread64`)
  will remove the file-descriptor seek lock under concurrent readers.
