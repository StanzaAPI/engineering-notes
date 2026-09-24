# Word-level lyric alignment when four sources disagree

*2026-09*

We serve time-synced lyrics for a catalogue of 888 tracks, 95 of them vocal.
Line-level timing is easy to borrow from community databases. Word-level timing
is not, because no single source has it. We had four candidate sources, and each
was authoritative somewhere and wrong somewhere else: the audio the player
actually plays; official release lyrics (Apple Music TTML), line-level; community
lyrics (LRCLIB, NetEase), line-level; and a Whisper transcription.

Every bug we hit traced back to one mistake: when two sources disagreed, the
code trusted one in some places and the other elsewhere. An anchor that led the
clock put one track 1.2 s late. An instrumental edit was
forced-fit tens of seconds from where it belonged and stamped `good`. A store
entry that carried a few extra lines made a full track look like a short edit and
skipped the check that would have caught it.

## Method

Every question has one authority, and when sources disagree the pipeline
abstains instead of blending.

1. **When** a word is sung: the served audio. Forced alignment is the clock, and
   external anchors never lead it.
2. **What** the word is: external text, official by default. The audio is
   evidence against a word, never a source of one. A per-line ASR mismatch is
   flagged for review.
3. **Where to search**, and the fallback when no fit lands: external anchors, as
   a fallback only.
4. External anchors are never averaged into the audio clock. A disagreement is
   flagged, not blended. Two independent fits of the same audio are a separate
   case; the eSpeak IPA pass is one of those.
5. Every cache is content-addressed by the audio bytes, the text, and the config.
   Change the audio and the cache is stale and recomputed. Rebuilds are
   deterministic and idempotent, and each one diffs the previous snapshot.
6. Every song and line is `measured`, `fallback`, or `flagged`, with its source
   and confidence recorded. `good` is asserted only with evidence.

The clock itself is a forced alignment of the known text to the audio (MMS_FA),
with an isolated-vocal onset from Demucs stems and the IPA pass as a second
acoustic opinion on that same audio. Whisper handles language routing and support
and does not set timing. Onset snapping moves a word only when the aligner is
already within 30 ms of the peak it snaps to. Every step runs as a Nix app, so
each pins its interpreter and tools: `align` fits the catalogue, `eval` reports
accuracy and drift, and `feedback` records a correction.

## Results

- Word-level timing for the 95 vocal tracks, each marked `measured`, `fallback`,
  or `flagged`.
- `eval` reports the state distribution, stalls, drift against a frozen
  reference, and a snapshot diff that exits non-zero on regression.
- A warm-cache rebuild of the alignment takes about 5 seconds. Changed song text
  invalidates that song's cache and re-fits it.
- A by-hand loop a listener can use: shift a track, pin a line, drag a
  word marker, or tap one key per word against the waveform. Each edit is stored
  as a correction record and re-applied on the next rebuild, before the monotonic
  clamp.

## What we learned

### 1. Official lyrics are not accurate timings

The release TTML anchors ran 1 to 3 seconds late on several tracks and 20 seconds
late on one. They are the authoritative text and a poor clock.

### 2. Averaging hides errors instead of reducing them

When the opening lines disagreed with the alignment, averaging the two clocks was
the obvious fix and the wrong one. It banks the lag into every line after it. The
pipeline flags the disagreement instead.

### 3. Corrections are worth nothing until they accumulate

A correction kept only in the session fixes one run. Stored as data and
re-applied before the clamp, it improves every later rebuild. We did not have
that at first, so a person could fix the same word again and again.

### 4. An isolated vocal is a better alignment input than the mix

The Demucs stems help twice: they make the words easier to hear, and they give
the aligner a cleaner signal to measure.

## What changed as a result

- ADR-0001 fixed the authority rules: the served audio is the clock, anchors are
  fallback-only, and a disagreement is flagged.
- The alignment passes read upstream data only, so a run cannot cite itself. An
  earlier version re-ran the IPA pass after alignment and echoed its own result.
- Accuracy is measured against a frozen reference before a change lands, and the
  snapshot diff fails the build on regression. A change that helps one track and
  hurts another cannot ship quietly.
- A per-track state badge drives a review queue built from `flagged`, so a person
  sees each disagreement once.
- Human corrections became first-class records: the by-hand tool writes them,
  `align` reads them back on every rebuild, and a headless browser pass checks the
  tooling.

## Reproduce it

The catalogue and the alignment code are not public. The steps below describe
the design:

1. Pick one clock, make it the served audio, and treat everything else as
   fallback.
2. Content-address every cache by the inputs that matter, and rebuild
   deterministically when they change.
3. Keep human corrections as data the next build re-applies, before any monotonic
   clamp.
4. Gate every accuracy change on a frozen reference and a snapshot diff that fails
   the build on regression.

## Open items

- Extract the domain-neutral core (forced alignment against a chosen clock, the
  cache, the three-state output, the eval snapshot diff) into a public repo with
  synthetic audio.
- Expand the frozen reference set beyond the current tracks.
- Measure the same pipeline on a second language pair.
