# Talks

Recorded talks and streams kept as primary-source evidence for beni's design decisions, the way
`references/` keeps vendored source. A talk is not a design document and is never normative — it is
somebody's argument, cited so that a decision sheet can say where a claim came from.

**The convention.** One directory per talk, named `<year>-<speaker-slug>-<title-slug>/`, holding
three files:

| File | What it is |
|---|---|
| `raw.txt` | the source paste, byte-for-byte, for provenance — never edited |
| `transcript.md` | the readable transcript: chapter headings and paragraphs, each with a time link |
| `notes.md` | the organised version — thesis, chapter-by-chapter argument, topic index, and what it means for beni |

**Auto-caption transcripts are unverified.** Where `raw.txt` is YouTube's automatic captioning, the
`transcript.md` built from it has been cleaned mechanically and lightly corrected, but it is a
machine's guess at what was said. **Quote from the video, not from the file** — every paragraph
carries a time link for exactly that reason. Each `transcript.md` says in its header which treatment
it received and lists the corrections that were applied.

## Index

| Talk | Speaker | Date | Link | Why it is here |
|---|---|---|---|---|
| [Front-End's Existential Crisis](2024-ryan-carniato-front-ends-existential-crisis/) | Ryan Carniato (SolidJS) | 2024-01-26 | [YouTube](https://www.youtube.com/watch?v=aA7Xeh7WG4E) (5 h 16 m) | A 30-year history of the front end, ending in an argument that hydration, serialisation and the client/server split are one unsolved problem — from the author of beni's UI performance gold standard (CLAUDE.md rule 8) |
| [Are There Actually That Many Different Ways to Build Web Apps?](2024-ryan-carniato-ways-to-build-web-apps/) | Ryan Carniato (SolidJS) | 2024-10-18 | [YouTube](https://www.youtube.com/watch?v=ja4LIaxxUeA) (5 h 05 m) | Reduces web app architecture to three buckets (SPA, server components / islands, stateful servers) and scores each — the map for the server-rendering, hydration, islands and routing space beni has not yet designed |
