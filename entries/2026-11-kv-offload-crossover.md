# KV offload only pays above 4k tokens

*2026-11*

A fixed KV pool refuses new sequences once every block is resident, and most of
that resident KV belongs to requests nobody will read again. We spilled the
least recently used sequences to Valkey and measured what a restore costs. The
direct comparison is prefill: when fetching the KV takes longer than recomputing
it, the cache is a loss.

## Method

- L1 is 64 blocks of 16 tokens at dim 64. The workload is 200 sequences of 32
  to 400 tokens, 44,166 tokens, 43x more than L1 holds.
- The baseline refuses a sequence when the pool is full. The tiered path spills
  the LRU sequence and restores it on the next read.
- Blocks are content-addressed by sha256 over the K and V bytes, so a restore
  can hit an entry written by a different sequence or a previous process.
- The crossover run uses Qwen3-4B-Instruct-2507: 36 layers, 8 KV heads, head
  dim 128, f16 KV at 147,456 bytes per token. The geometry comes from the model
  definition.
- Prefill is a real `/v1/completions` request with `cache_prompt=false`.
  `prompt_ms` is read from the server timings.
- Restore writes the same byte count to Valkey as 16-token blocks and reads it
  back through the RESP client the tiering path uses.
- Four prefix lengths, three runs each, median reported. The first request
  after model load is discarded: shader setup makes it about 3x slower than
  steady state.

## Results

Capacity:

| | fixed pool | tiered |
|---|---:|---:|
| sequences served | 4 of 200 (2%) | **200 of 200 (100%)** |
| L2 hit rate on restore | - | 1.00 |
| spills / restores | - | 246 / 50 |
| Valkey memory for 44k tokens | - | 60 MB |
| mean restore | - | 1.7 ms (localhost) |

Restore against prefill:

| prefix tokens | prefill | restore | prefill / restore |
|---:|---:|---:|---:|
| 512 | 100 ms | 104 ms | 0.97 |
| 2,048 | 373 ms | 416 ms | 0.90 |
| 4,096 | 810 ms | 783 ms | 1.03 |
| 6,144 | 1,310 ms | 1,025 ms | 1.28 |

## What we learned

The capacity number answers a different question. It compares tiering against
refusing work. Against a prefill, a restore loses below 2k tokens, ties around
4k, and wins by 28% at 6,144.

The reason is the shape of the two costs. A restore moves `tokens x 144 KiB`
over the socket; at 6,144 tokens that is 864 MiB, read at about 840 MiB/s on
loopback. Prefill costs compute, and the per-token cost rises with context
because attention work grows with the prefix.

The restore side is sensitive to the machine. One re-run with a compiler in the
background took 4.3 s at 6,144 tokens instead of 1.0 s, while prefill stayed
within 5% of its reference value. A single run on a busy box is not a
measurement.

## What changed as a result

- The repo publishes the crossover, the chart, and a `make bench` target that
  runs the capacity benchmark and re-renders the chart.
- `sweep.py` discards a warm-up request and reports the median of three runs.
- Claims about the KV tier now quote the crossover instead of the capacity
  ratio alone.

## Reproduce it

```bash
nix develop
make bench

llama-server -m ~/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
  --alias qwen3-4b --host 127.0.0.1 --port 8097 \
  --ctx-size 8192 --parallel 1 --n-gpu-layers 99 \
  -ctk f16 -ctv f16 --reasoning off
make bench-restore
```

Source: [DrMkdaddy/valkey-kv-l2](https://github.com/DrMkdaddy/valkey-kv-l2).

## Open items

- The restore path moves random bytes of the right size. It measures transfer
  and deserialization, not the attention math a real restore would preserve.
- Networking is not modeled. A 1 ms RTT adds about 30% to a 4k restore.
- KV quantization would shrink the bytes per token and move the crossover left.
  `q8_0` is the obvious next run.
- Batch size changes the comparison. Prefill is shared across a batch and a
  restore is per sequence.
