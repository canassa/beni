## 2026-09-20 19:20 CEST — Two Ryan Carniato streams filed under `references/talks/`

**What I did**

The owner dropped two YouTube transcript pastes (Solid's author; 5 h 16 m and 5 h 05 m, ~85 000
words of auto-captions together) and asked for them to be formatted, organised and stored in the
references. One Opus agent each; I validated and committed (`23f72f1`, and this commit).

- New convention, `references/talks/<year>-<speaker>-<title>/`: `raw.txt` (byte-identical paste),
  `transcript.md` (chapters, time-linked paragraphs, light corrections, `[?]` for the unresolved, an
  appendix of every correction), `notes.md` (thesis, chapter arguments, topic index, "what this means
  for beni" tied to W ids, his claims separated from our inference). `README.md` is the index;
  `CLAUDE.md` References now points at it.
- The mechanical part is a script: the glued timestamps (`3:083 minutes, 8 seconds…`) are split by
  regenerating YouTube's spoken-out form and asserting it on every line — 0 failures in 2 242 and
  2 153 lines — and the word count is conserved exactly before the editorial pass (44 457; 40 486).
- Validation: checksums of both `raw.txt`, no leaked tool markup, and passages compared against the
  raw captions (the Elm answer at 2:25:57; "SSR is a toggle" at 28:05; 5:00:06).
- When the second paste arrived under the same filename while the first agent was running, I moved
  it to `references/talks/_incoming/` first and told the second agent what it may read and must not
  write; the shared README row came back in its report and I merged it.

**What I learned**

- Both talks press on the same two places in beni's browser plan. **Local state**: "MVC in stateless
  is lovely; MVC in stateful is a disaster", and Redux is "too simple" — the one-model cell is what he
  argues against, and ephemeral UI state needs somewhere to live. This is the owner's live question
  (Elm has no components), and an argument for designing narrow widget-local state.
  **Server rendering**: his whole taxonomy (SPA / server components and islands / stateful servers)
  puts beni-as-planned in the SPA bucket's worst cell for first load; beni has no SSR, hydration,
  routing or data-loading design at all. He also says SSR is "a toggle" on an SPA, and that the real
  fix needs one language on both sides compiling to JavaScript — which beni is.
- Supporting evidence for the current direction: his case against diffing is a case against
  memoisation-by-hand (so W29's seam must never make a programmer reach for it); "compilers have
  limits on the scope they can analyze" (against inline-everything; and an SVG-namespace question
  nobody wrote down); template bytes, not runtime bytes, are what grows.
- Auto-captions are evidence of what was argued, not of what was said: 84 and 159 `[?]` remain, and
  the header of each transcript tells the reader to quote from the video.
