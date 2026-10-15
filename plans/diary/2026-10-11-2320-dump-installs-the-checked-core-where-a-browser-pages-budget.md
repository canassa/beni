## 2026-10-11 23:20 CEST — dump installs the checked core; where a browser page's budget goes

**What I did.** Measured the browser pages' instruction counts process by process (a
`perf_event_open` wrapper with `inherit`, and the corpus walker's own `BENI_TEST_TIMING`
records). `browser/tea/ApiItems`, hashes valid: 2.78 billion — the development build 0.63, the
release build 2.02, the harness about 0.12; with Node running the page (a PR that moves its
hash) 3.99, Node's share about 1.2. No build checks core or a platform from source (27 of 28
modules installed, one checked). Inside the release build, whole-program specialisation
(`Spec`) is about 1.4 billion of the 2.0: 8 analyses, 96 points-to sweeps, `spec_passes_capped`
1. Inside the development build emit is the bulk: every core and platform module is lowered to
JsIr again in every process (~340 million), elimination runs twice (~115 million), and the
runtime-roots refinement lowers nine modules a second time (~60 million). Then fixed the queued
`dump` defect: the informational bit is now the switch as it reaches a module —
`informational ∧ (explain ∨ app)` — one function for the key and the checker's gates, and
`unkeyed_for`/`raw_markup_attribute` gated to the root package as `language.md` §10 says.
`fast-compiler.md` §8 amended; a cache test pins it.

**What I learned.** The 3.5–3.9 billion of a schema Tea page is not redundant checking: it is
the release optimiser and Node, and the budget only bites when Node runs. `dump --stage=writes
--msg-types` went from 857 to 174 million; `ListValues`' value-fuzz case from 1 702 to 1 018
million (hashes valid). The two next slices with real size are `Spec`'s cost on schema programs
and caching the lowered JsIr of embedded modules.
