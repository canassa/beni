## 2026-10-21 21:16 CEST — Marko 6 stream added to references/talks

**What I did**
- Parsed `transcript.txt` (YouTube auto-captions of Ryan Carniato's stream with Dylan Piercey,
  "Marko 6: Fulfilling the Promise of Less JavaScript", 5 h 38 m) into
  `references/talks/2025-ryan-carniato-marko-6-with-dylan-piercey/`: `raw.txt`, `transcript.md`,
  `notes.md`; added the row to `references/talks/README.md`.
- The parser split the glued timestamp and spoken duration and cross-checked them: 2 598 lines,
  17 chapters, 0 failures. `transcript.md` joins them into minute-long paragraphs, drops `um`/`uh`
  (58 484 → 57 476 words) and fixes Marko, Svelte, Qwik, TanStack and SolidJS by script.
- The first `transcript.txt` I was shown was the already-filed 2024 talk; the file was replaced
  with the Marko one before the second look.

**What I learned**
- The paste has no link and no date. The year is inferred from the stream ("it's already
  September", Marko 6 still a beta), so the directory says 2025 and the time stamps are plain text.
  Fill in the link and date when the video is identified.
- The paste's chapter 17 holds the Marko Q&A and the whole *This Week in JavaScript* half.
- Relevance to beni is in `notes.md`: Marko ships no template for server-rendered markup and
  serialises only what handlers read — input to W22 (hydration); TEA's message-valued handlers
  remove the closure-capture part of that problem. Inference, not measured.

**Addendum (21:25)** — the owner supplied the link, `https://www.youtube.com/watch?v=x-3RxGf4KA8`.
The transcript's paragraph and chapter time stamps now link into the video; `raw.txt`, `notes.md` and
the README row carry the link. The stream's date is still inferred (September 2025), not confirmed.
