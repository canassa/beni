## 2026-10-08 20:45 CEST — Specifying the write-set analysis (R3/R4's shared summary)

**What I did**
- Wrote `docs/design/write-sets.md`, the normative contract for the per-message write-set
  analysis the owner decided on after research 62: nested-message dispatch and same-variant
  analysis as a sound abstract interpretation, gated on a read-only pass. The domain is
  k-limited access paths (k = 8, from the model root; fields, tuple indices, constructor
  tag-and-position steps, list positions with edit tags) with two write kinds, `node` (rebuilt,
  children keep identity) and `value`. The abstract values are symbolic terms over the old
  model (`Same`, `Rec`, `Con`, `Lst`, `Fresh`, `Alt` with tag facts); the write set is read off
  the result by a `diff` that knows the matched tag per `case` arm. Functions are symbolic
  summaries instantiated by substitution, which is how `updateWith Home …` is seen through;
  recursion is a bounded Kleene iteration. Message keys are paths of constructors through the
  message, split where `update` and its callees match.
- Added pointer paragraphs in `backend.md` §15.4 and `plans/compile-away.md` R3/R4; no section
  renumbered, no compiler code.

**What I learned**
- The prototype classifier's "root write" problem is a domain problem, not a rule gap: without a
  `node`/`value` distinction, re-applying a constructor around matched parts can only be read as
  a write of the whole path. With the distinction and one tag fact per `case` arm, Conduit's
  page union, the status rebuilds and `Feed`'s opaque wrapper all fall out of one `diff` row.
- Slice B's read paths are relative to locals and at most four links; anchoring them to the
  model through nested pages adds steps, so the write side's k must be larger than 4 (Conduit's
  deepest anchored read is about nine). The same interpreter that computes writes gives the
  anchor for free.
- `List.map` and friends are beni over `foreign` `at`/`put`/`kept`, so their precision has to
  come from a declared row citing `backend.md` §4's identity list, not from their bodies; most
  of `Maybe`/`Result` needs no row at all.
