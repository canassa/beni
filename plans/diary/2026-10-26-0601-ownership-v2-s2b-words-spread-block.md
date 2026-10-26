## 2026-10-26 06:01 CET — Ownership v2 S2b: words, the spread fact, a minimal block

**What I did**

- Checked Appendix C's derivations with S2's modules (`Rows.zig` tests): C.1's rows by
  hand, the call's instantiation and the read-off's fold as C.2/C.4 state them, the rest
  by `Cond.lower`, `Cond.instantiate`, `joinRes` and `Cond.leq`. mapHelp's κ at
  `res[*]` matches each round of the table and settles at round 4; foldlFrom's res and
  κ settle at round 3. S2's `sep` answers the folded pair `lost`, so `within` is the
  read-off's (S3b), as C.10 says.
- The v2 value words (`written` … `concatenated`) and type words (`sequence`, `cell`,
  `sender`, `failure`) through parser, lowering, formatter, AST/BIR dumps and the typed
  interface (format 18), with six new `misplaced_ownership_word` readings.
- `Bir.Spread` per declaration, read by the pre-pass.
- core's List primitives, Builder, Ref, Deferred and Result worded; each pinned in
  `word-bodies.txt` with the taken readers and the pinned `sortWith` body, and a gate
  that fails when one is added unpinned.
- `Rows.fromWords` taught the new words against the place's kind; `Block.zig` writes
  and reads classes; `@ownership_summary_size` (attribute, diagnostics, formatter).

**What I learned**

- v1 reads every word of a beni declaration as "use the words, not the body", so a
  v2 row that needs an old word (`consumed`, `borrowed`) must keep it out of v1's
  column. The rule I used: a signature with any v2-only word keeps all its words in
  the v2 column. It cannot help a declaration whose v2 row needs only old words
  (`Log.annotate`'s `once`, `Js.maySuspend`'s `unused`): wording those changes v1.
- §2.13.6 has no word for `at`'s row (res π₁`[*]`, no split), `copy`'s (fresh storage
  over π₁`[*]`), `cons`'s, or `focus`'s put-back; C.9 names them by reference only.
- Burying `Cond.lower`'s arrivals group under another `and` made each store open a
  new group: n stores built n groups, quadratic to write. Keep the group on top.
- `Cell.internCell` keys a result/site/refinement cell without its place, so the cell
  keeps the first creator's place and a block cannot spell it canonically across
  build orders (it is still a function of the module).
- Source maps embed core's text, so a core edit moves every `.mjs.map` and the run
  hashes, while no `.mjs` changes (457 run programs compared, dev and release).
