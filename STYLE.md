# Style

House rules for the prose in this log, and the reason the lint exists. The
backbone is George Orwell, *Politics and the English Language* (1946).

## Orwell's rules

1. Never use a metaphor, simile, or other figure of speech which you are used
   to seeing in print.
2. Never use a long word where a short one will do.
3. If it is possible to cut a word out, always cut it out.
4. Never use the passive where you can use the active.
5. Never use a foreign phrase, a scientific word, or a jargon word if you can
   think of an everyday English equivalent.
6. Break any of these rules sooner than say anything outright barbarous.

Rule 6 matters. These are rules of thumb for clear writing, not a checklist to
satisfy at the cost of the sentence.

## Phrases to avoid

Filler and puffery that hollow out a sentence. The lint fails the bolder ones
and warns on the rest.

- **Importance padding.** "stands as", "plays a vital role", "underscores",
  "reflects broader", "marking a turning point".
- **Analysis tacked on the end.** "highlighting", "underscoring", "reflecting",
  "contributing to", "ensuring", "fostering".
- **Puffery.** "boasts", "vibrant", "nestled", "in the heart of",
  "groundbreaking", "renowned".
- **Negative parallelism.** "not just X, but Y", "not X, but Y", "Y rather
  than X".
- **Rule of three.** Three items with the same grammar, added for rhythm.
- **Avoiding "is".** "serves as", "stands as" where "is" works.
- **Vague attribution.** "experts say", "it is worth noting".
- **Heavy formatting.** Em dashes by the handful, bold on every noun, Title
  Case headings.

## House rules

- Every claim carries a concrete noun: a file, a number, a commit, a command.
  If a sentence could be pasted into any repo, delete it.
- Say what happened, in order, with the numbers.
- One em dash per entry, at most.
- Cut "actually", "really", "very", "in order to", "the fact that".
- Prefer the active voice: "We fixed the generator", not "the generator was
  fixed".
- Do not reach for a figure of speech when a plain verb will do. "The same
  shape" and "pays for itself" are the kind of phrase the reader has seen
  before and learns nothing from.

## What the lint checks

`nix run .#lint` fails an entry on format (filename, H1, date line, required
sections) and on the banned vocabulary. It warns on the softer phrases above
and on em-dash count. A clean lint is a floor and not a pass: the patterns that
matter most are structural, and a person has to read for those.

## A worked example

Before:

> Every recurring bug had the same shape.

After:

> Every bug we hit traced back to one mistake: when two sources disagreed, the
> code trusted one in some places and the other elsewhere.

The first leans on a metaphor and hides the finding. The rewrite names the
mistake and says where the code went wrong.
