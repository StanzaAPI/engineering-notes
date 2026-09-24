# Benchmarking X12 parsers, and the bugs it found in our own code

*2026-09*

We publish a throughput claim for our X12 parser: 250,000 healthcare claim
records, about 500 MB, parsed in roughly 12 seconds inside a 25 MB V8 memory
budget. Claims like that are cheap to make. The X12 ecosystem publishes almost
no parser benchmarks, so there was no way for anyone to check ours against
anything.

So we built a reproducible benchmark, and then pointed it at the most
established open-source Node X12 parsers to see how we actually compare. The
exercise found two bugs in our own code and one in a library we respected.
This is the write-up, including the parts that are unflattering.

## Method

- 500.5 MB of synthetic 837P claims, 255,000 transactions, about 1,963 bytes
  per transaction, generated deterministically from a seed.
- Each parser runs in a fresh process, sequentially, never in parallel.
- Output is discarded while parsing. We measure parse cost, not retention
  policy, because retaining output is a consumer decision.
- Peak heap samples `process.memoryUsage().heapUsed` every 25 ms. The capped
  run enforces `--max-old-space-size=25`, which aborts the process if
  old-space allocation exceeds the bound.
- Versions: `node-x12@1.7.1`, `x12-parser@1.3.0`, Node v26.8.2, Core i7-10700K.

## Results

Capped at 25 MB old space, which is the constraint that breaks parsers in
serverless and edge runtimes:

| Parser | Mode | Result | Wall time | Items emitted |
| :-- | :-- | :-- | :-- | :-- |
| Stanza | streaming, 837 domain parsing | ok | 14.2 s | 255,001 transactions |
| node-x12 | streaming, lax | ok | 20.3 s | 20,655,000 segments |
| x12-parser | streaming | ok | 39.2 s | 20,655,000 segments |
| node-x12 | streaming, strict | fails on valid input | - | - |

Uncapped, with V8 free to use memory:

| Parser | Wall time |
| :-- | :-- |
| Stanza | 13.4 s |
| node-x12 | 13.6 s |
| x12-parser | 32.3 s |

## What we learned

### 1. Uncapped the parsers tie; under a 25 MB cap they do not

`node-x12` ties us at 13.4 versus 13.6 seconds when memory is free. Under a hard
25 MB old-space cap it slows by 50 percent, to 20.3 seconds, while Stanza holds
14.2 seconds. `x12-parser` is about 2.7 times slower than Stanza under the cap.

A throughput number without a memory bound says little. What kills parsers in
workers and edge runtimes is the ceiling, and that is the number we should have
led with.

### 2. Our own test-data generator was emitting invalid X12, and our parser did not notice

`node-x12` refused the corpus with:

```
X12 Standard: The value in SE02 does not match the value in ST02.
```

It was right. Our generator picked the transaction control number for `ST02`
and `SE02` independently at random, producing files that strict parsers must
reject. We fixed the generator. Our parser had accepted those files because it
does not validate `ST02`/`SE02` consistency at all. That is a real gap, and it
is now a cataloged adversarial case.

Our benchmark was measuring speed against a corpus that was not valid X12, and
a competing parser was the one that caught it.

### 3. node-x12's strict streaming mode rejects a valid single envelope

Used exactly as its documentation shows, `node-x12` in strict mode throws on a
well-formed single-envelope file:

```
X12 Standard: An EDI document must contain at least one functional group.
```

Its stream path pushes parsed segments without building the interchange object
model, then validates that empty model at flush. Lax mode works. We used lax
mode for the comparison and published the reproduction command, because a
measurement that quietly changes library behavior is not a measurement.

### 4. The parsers do different work

Stanza emits 255,001 parsed transaction frames with 837 field mapping and SNIP
element checks such as NPI Luhn validation. The libraries emit 20,655,000 raw
segment objects for the consumer to interpret. That is 81 times more objects to
handle, and none of them know what a claim is.

The fair claim is narrower: we do more semantic work per record, emit far fewer
objects, and hold our speed under a memory ceiling the alternatives do not.

## What changed as a result

- Fixed the generator: `ST02`/`SE02` and envelope control numbers are now
  consistent.
- Added `structure.st-se-control-mismatch` to the adversarial suite.
- Published [COMPARISON.md](https://github.com/StanzaAPI/benchmark-harness/blob/main/COMPARISON.md)
  with the full tables, fairness caveats, and a feature matrix that states
  plainly where we do not compete.
- Started this engineering log, because the failures deserved a permanent home
  and not a buried commit message.

## Reproduce it

With Nix there is nothing to install:

```bash
# from anywhere, no checkout
nix run github:StanzaAPI/benchmark-harness#smoke

# or from a checkout
nix run .#generate -- --transactions 255000 --claims 5 --out data/claims.x12
nix run .#bench    -- data/claims.x12
nix run .#compare  -- --file data/claims.x12 --cap 25
```

The flake builds `node_modules` and `dist/` from the lockfile, so the apps run
without `npm install` and without network.

Without Nix (Node >= 23):

```bash
git clone https://github.com/StanzaAPI/benchmark-harness
cd benchmark-harness
npm install && npm run build
node bin/generate.mjs --transactions 255000 --claims 5 --out data/claims.x12
node bin/compare.mjs --file data/claims.x12 --cap 25
```

Single machine, single synthetic corpus. Run it on yours and tell us where the
numbers land differently.

## Open items

- Validate `ST02`/`SE02` and envelope control consistency in our parser.
- Expand the adversarial suite and document each case's purpose.
- Map more than four transaction sets.
- Compare against `x12-parser` on multi-gigabyte input, where streaming design
  differences should matter more.
