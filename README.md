# Engineering Notes

A public log of what we build, what breaks, and what we get wrong.

Each entry documents one experiment or incident: the method, the results, the
things we did not expect, and what changed afterward. Entries are written when
the work happens, not when the narrative is convenient. Corrections stay in the
file.

This exists for three reasons:

1. Our claims should be checkable, including the unflattering ones.
2. The failures are usually more informative than the results.
3. Anyone evaluating our work can see how we think, not just what we shipped.

## Entries

| Date | Entry | Summary |
| :-- | :-- | :-- |
| 2026-09 | [Benchmarking X12 parsers, and the bugs it found in our own code](entries/2026-09-benchmarking-x12-parsers.md) | A head-to-head against `node-x12` and `x12-parser` under a 25 MB ceiling. We tied one of them uncapped, found a bug in our own test-data generator, and found a validation gap in our own parser. |
| 2026-09 | [Word-level lyric alignment when four sources disagree](entries/2026-09-word-level-lyric-alignment.md) | Four lyric sources, one clock. Forced alignment of 95 vocal tracks, content-addressed caches, and an accuracy harness that blocks regressions. |

## Queue

- Adversarial X12 test data: 100 hostile inputs, and what each one is for.
- What a hard memory ceiling actually means for a streaming parser.
- Two upstream bugs: discriminated unions in Python codegen, and flattened
  error chains in Rust.

## Adding an entry

One file per entry under `entries/`, named `YYYY-MM-slug.md`. Lead with why the
work happened, then the method, then the results, then what surprised us and
what changed. Include reproduction commands or links. Keep it readable by an
engineer who has ten minutes. [STYLE.md](STYLE.md) has the phrasing rules.

```sh
nix run .#new  -- word-level-lyric-alignment   # scaffold the file
nix run .#show -- word-level-lyric-alignment   # render it
nix run .#lint                                 # names, sections, vocabulary
```

`nix run .#help` lists every command, and `nix flake check` runs the lint as a
build. Without a checkout: `nix run github:StanzaAPI/engineering-notes#list`.

Corrections and counter-examples are welcome as issues or pull requests.
