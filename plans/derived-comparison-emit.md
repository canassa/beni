# Derived eq/compare at width: unrolled code or a field table? (investigation, 2026-09-28)

Read-only on the repo. master `88b291a`. The ReleaseFast beni was built in a scratch worktree, which has since
been removed. The experiments are in `scratchpad/exp/`:

- `gen.mjs` and `measure.mjs`: build size and emit time.
- `realbench.mjs`: times beni's REAL output.
- `rt.js`: the design mimics. It runs under `node-rt.mjs`, the SM shell, `bun`, and headless Chrome through `browser.mjs`.
- `hoist.js`: the evidence-passing variants.
- Raw data: `measure.log`, `real-node.jsonl`, `rt-all.jsonl`, `rt-tables.md` and `hoist.txt`.

Machine: Ryzen 9 5950X.

Engines:

- Node 24.19 (V8)
- Chrome 153 headless (V8)
- SpiderMonkey 140.14 shell ("sm"), standing in for Firefox. The playwright Firefox would not start on NixOS because `libgtk-3` was missing.
- Bun 1.3.13 ("jsc"), standing in for WebKit.

Every timing is the median of 7 samples of at least 15 ms each, in ns per `==`/`compare`. Each width ran in a fresh
process or page.

## 1. What is emitted today

Measured with `--library --jobs=1 --no-cache`, the best of 3 runs. B/field is output bytes ÷ n. The emit column is
`--self-profile`'s `emit` phase.

| shape (eq+compare, 2 use sites) | n | dev bytes | rel bytes | dev br | rel br | emit ms | emit µs/field |
|---|---|---|---|---|---|---|---|
| record `{f1..fn : Int}` | 64 | 11 732 | 5 792 | 1 438 | 1 324 | 1.2 | 18 |
| | 4 096 | 791 472 | 383 735 | 41 784 | 36 576 | 17.1 | 4.2 |
| | 4 097 (wide) | 728 349 | 352 414 | 38 002 | 30 682 | 15.0 | 3.7 |
| | 65 530 | 12 569 737 | 6 214 688 | 630 638 | 467 911 | 240 | 3.7 |
| nominal payload `Q {f..}` | 65 530 | 12 569 779 | 6 214 701 | 646 027 | 468 626 | 243 | 3.7 |
| nominal positional `P Int…` | 4 096 | 633 838 | 397 024 | 36 860 | 30 942 | 15.0 | 3.7 |
| | 65 530 | 10 778 863 | 6 935 158 | 446 342 | 400 094 | 251–270 | 3.8–4.1 |
| `L (List Int)…` (has a steps twin) | 4 096 | 2 103 882 | 1 025 528 | 52 413 | 39 640 | 46 | 11.3 |
| | 65 530 | 34 484 399 | 17 205 184 | 638 153 | 574 686 | 755 | 11.5 |
| type of n PARAMETERS `T a1..an` | 4 096 | 1 895 821 | 1 163 439 | | | 45.8 | 11 |
| | 4 097 | 1 761 445 | 1 090 238 | | | 39.2 | 9.6 |

The marginal cost is linear: about **190 B/field dev and 95 release** for a record or payload, 165/106 for a
positional payload, and **527/263** when the positions can recurse (List, type parameters). Those shapes get a
`function*` steps twin per type. Emit costs **3.3–4 µs per field** (11 µs with a twin), and checking costs another
1.5–2 µs per field.

At 4 096 fields the record breaks down as follows (dev):

- **24 %** is the shape-keyed NAME `eq$r$f1$f10…`, which spells every field and is printed 4 times (93 910 of 790 624 bytes).
- **17 %** is the use sites' positional evidence lists (`W$eq$prim, ` × 4 096 × 2).
- The rest is the body.

`--release` removes the name and shortens the lists. In release a record field costs about 26 B in `eq`
(`a[k](b.fK,c.fK)&&`) and about 60 B in `compare` (`const Yka=a[4093](c.f996,d.f996);if(Yka!=="EQ")return Yka;`).

The code has these shapes (as `static-dispatch-spike.md` §9 says, as built):

- **Record and tuple.** They are shared by shape. Every position calls its OWN evidence parameter (`$m$k(l, r)`), even when every field is `Int`. There is one positional parameter per field up to 4 096; past that, one array `$m` that **every call site builds as an array literal on every call**. `eq` is one `&&` chain in runs of 1 024. `compare` is `const $o$i = …; if ($o$i !== "EQ") return $o$i;` for each field.
- **Nominal.** Primitive positions are inlined (`$x.a === $y.a`). Evidence is per type PARAMETER. A body with a non-tail depth-taking call gets a `$d` parameter, a prologue and a `$$steps` generator twin, which roughly doubles the bytes.
- **The identity shortcut.** No shape has one. `r == r` walks every field.

**Eager derivation costs a check, and nothing at emit.** A 65 530-position type that is never compared costs
`derived` = 27 ms of a 72 ms `check`. Emit already skips rows Reach cannot reach (`liveDerived`): 162 bytes, 10.7 ms.
A `--library` build roots every `pub` type's `$$eq`/`$$compare` because they are exported.

**Real programs are nowhere near these widths.** In bench/corpus plus `tests/corpus/run` (dev), derived code is 1.4 %
of all emitted bytes: 133 functions, the widest 15 positions. Only **1** of the 133 is a structural duplicate of
another in the same program.

## 2. Runtime: beni's real output (Node, release; dev is the same except where noted)

| record n | eq equal | eq same obj | eq first differs | cmp equal | cmp first |
|---|---|---|---|---|---|
| 8 | 2.3 | 2.3 | 1.0 | 23* | 15* |
| 64 | 47 | 43 | 13 | 74 | 22 |
| 512 | 896 | 830 | 122 | 9 866 | 168 |
| 1 024 | 35 542 | 35 055 | 141 | 34 115 | 302 |
| 4 096 | 346 211 | 192 535 | 717 | 178 901 | 2 169 |
| 4 097 (array form) | 218 698 | 186 907 | **5 222** | 200 311 | 5 742 |
| 65 530 | 4.3 ms | 4.2 ms | **1.4 ms** | 4.5 ms | 1.0 ms |

\* dev measured 9.7 and 5.6 here.

A positional nominal payload of `Int`s, with inlined `===` and no evidence, costs:

- 3.6 at n = 8, 29 at 64 and 360 at 512
- **13 294 at 1 024** and 107 132 at 4 096
- first-differs 16 ns at every width

Three facts carry the analysis:

- **(F1) There is a cliff at about 1 000 positions** (compare: about 256–512). Past it V8 no longer optimises the unrolled function (the bytecode-size limit), and the cost per field jumps about 38×: 0.9 µs becomes 35 µs between 512 and 1 024 record fields.
- **(F2) Evidence passing is O(width) per call, even when the first field differs.** Positional evidence pushes n arguments. The wide form allocates an n-element array literal per call (1.4 ms per `==` at 65 530, 5.2 µs at 4 097).
- **(F3) Record rows never inline a primitive.** Every field is an evidence call. The same data compared as a positional payload is 1.3–2× faster (A.11's choice: the number of functions is bounded by shapes).

## 3. Runtime: the candidates, across four engines (`rt.js` mimics; `rt-tables.md` has everything)

The implementations measured:

- `cur`: today's record shape, positional up to 4 096 and a per-call array past it.
- `inl`: unrolled with `===` inlined.
- `tab`: the proposed `eqFields(x, y, {keys, ev})` loop with `x[k]`.
- `tabk`: the same, but a primitive entry in the table is `null` and the loop inlines `===`.
- `forin`: `for (k in x)`.
- `…Id`: the same with `if (x === y)` added.

| eq, equal records | node cur / inl / tab | chrome cur / inl / tab | sm cur / inl / tab | jsc cur / inl / tab |
|---|---|---|---|---|
| n=8 | 5.8 / 7.2 / **106** | 3.0 / 7.2 / **112** | 17 / 8.4 / **185** | 3.7 / 6.8 / **59** |
| n=64 | 58 / 26 / **1 700** | 56 / 25 / **2 000** | 95 / 36 / **2 000** | 75 / 26 / **437** |
| n=512 | 1 100 / 386 / 18 400 | 4 700 / 1 500 / 6 700 | 8 100 / 497 / 18 500 | 9 300 / 623 / 5 500 |
| n=1 024 | 33 µs / 12.8 / **13.7** | 20.5 / 5.5 / 14.2 | 43.8 / 11.4 / 52.5 | 41.7 / 25.8 / 58.1 |
| n=4 096 | 169 µs / 104 / **65** | 137 / 84 / **65** | 195 / 108 / **311** | 191 / 118 / **346** |
| n=65 530 | 3.8 ms / 2.0 / **1.5** | 3.8 / 1.4 / **1.5** | 9.8 / 1.3 / **7.4** | 1.9 / 0.7 / **7.2** |

| first field differs | n=64 | n=4 096 | n=4 097 | n=65 530 |
|---|---|---|---|---|
| cur (node / sm / jsc) | 33 / 48 / 41 | 29.5 µs / 27.8 µs / 14.8 µs | 3.7 µs / 13.1 µs / 4.2 µs | 991 µs / 520 µs / 390 µs |
| tab (node / sm / jsc) | 31 / 21 / 12 | 25 / 22 / 11 | 17 / 20 / 11 | 63 / 21 / 12 |
| inl (node / sm / jsc) | 6.6 / 6.3 / 4.6 | 27 / 11.5 / 1 000 | 19 / 11 / 1 000 | 28 / 11 / 1 100 |

**Megamorphism** (`eq-poly`, width 8, K record types through one path, ns per compare):

| K | node cur / tab | sm cur / tab | jsc cur / tab |
|---|---|---|---|
| 1 | 6 / 123 | 30 / 254 | 2 / 61 |
| 64 | 31 / 128 | 40 / 297 | 23 / 77 |

Reading these:

- **The generic loop is megamorphic from the first type.** Its `x[k]` site sees a different NAME every iteration, so it is megamorphic even for ONE type (the K=1 row). More types cost it nothing more. An unrolled function's `x.f` loads are monomorphic per shape and only degrade (6→31 ns) as unrelated shapes flow through shared evidence sites.
- **`for…in`** (the enum cache) is 3–4× the unrolled cost at small widths, and collapses past about 1 000 properties (dictionary-mode objects).

**Identity (field identity, CLAUDE.md rule 8).** `tabId` on the same object costs about 5 ns at every width in every
engine. `curId` stays O(n) (26 µs at 4 096 V8) because the use site pushes n evidence arguments before the `x === y`
test runs. So an identity shortcut only pays once evidence passing is O(1).

Evidence passing alone (`hoist.js`, record `eq`, ns: equal / first-differs):

| engine | n | positional | per-call array | hoisted const array |
|---|---|---|---|---|
| node | 64 | 37 / 10 | 80 / 53 | 37 / 8 |
| node | 4 096 | 138 k / 595 | 182 k / 4 649 | 163 k / **28** |
| sm | 512 | 7 918 / 73 | 12 852 / 1 190 | 1 018 / **8** |
| sm | 4 096 | 164 k / 514 | 212 k / 12 620 | 193 k / **23** |
| jsc | 4 096 | 133 k / 1 491 | 229 k / 3 690 | 191 k / 998 |

At n = 8 positional is the best everywhere (2.1 vs 9.1 ns in Node).

## 4. The four designs

**(a) One generic `eqFields`/`compareFields` over a per-type table.**

- **Size.** A keys array per shape (shared by `eq` and `compare`), plus a per-use evidence array (`0` for a primitive), plus about 1 kB of helper added once to `_core/_derived.mjs`. At 65 530 that is 841 kB raw / 41 kB br. Today it is 12.6 MB / 631 kB dev and 6.2 MB / 468 kB release: **15× raw dev, 7× raw release, 11–15× brotli**. At 4 096 it is 53 kB / 2.7 kB br against 791 / 42 kB.
- **Emit.** An array literal of 65 530 strings emits in 11.5 ms (0.18 µs per element; a PROXY, the table was not implemented) against 240 ms. That is about **20× less emit** and about 40 ms less `Rename`/print work at release.
- **Runtime.** It is a **loss at every width below about 1 000**: 5–30× at 8–512, in all four engines (the megamorphic keyed load). At 4 096–65 530 it wins 2.5× in V8 but loses 1.6× in SM and 1.8–3.8× in JSC on full walks. It short-circuits in O(1) everywhere.
- **Verdict.** A win in size and compile time, not in runtime. It must never apply to ordinary widths.

**(b) Unrolled up to a threshold, the table past it** (the wide-evidence pattern).

- **Runtime.** Past the threshold the unrolled code is already de-optimised (F1), so the table costs little: V8 is faster, and SM/JSC are within about 2× on a full walk and far faster on a mismatch.
- **Size.** Same as (a) past the threshold, unchanged below it.
- **Real programs.** No real program changes (widest in corpus: 15).

**(c) Share structurally identical derived functions.** Records and tuples already share by shape (A.11). Across
nominal types, the corpus has 1 duplicate in 133. Tag names and order tables differ per type, so only single-constructor
types could share. Negligible; not worth an identity-by-structure hash in the emitter.

**(d) Lazy derivation.** Emit is already lazy: Reach drops rows it cannot reach. What remains eager is the checker's
fixpoint plus publishing contexts in the interface. That is 27 ms per 65 530 positions, 1.9 ms per 4 096, and about 0
at real widths. Making it lazy moves the context computation to the first use in ANOTHER module. That breaks "the
declaring module is the only one that can emit without depending on which other module asked first" (§9.4's rule for
eager derivation) and interface v3's published contexts, cache keys and determinism. It is not worth it.

**(e) Found along the way: F2 and F3.** They matter more than the table at real widths.

- **Hoist closed evidence (e1).** When a use's evidence is all constants (the common case), bind the evidence array once as a module `const` and use the array convention past a lower threshold (about 64). This fixes O(width)-per-call on a mismatch and on the same object.
- **Inline primitive positions in records (e2).** When every field's evidence at a use is a primitive, emit the body with `===` or the inline compare, keyed by (shape, primitive vector). That measures 1.3–3× on full walks at 8–512 in all engines, and it bounds the function count by distinct (shape, primitive-vector) pairs, not by instantiations. It is a partial revisit of A.11 and the owner's call.

Both are shape changes to the output. Neither touches the checker.

## 5. Interactions

- **Release optimiser.** Opt has nothing to inline in a table. Rename shrinks the table's `$m`/evidence names, but the field-name STRINGS are property names and stay long; keys already stay long in the unrolled form. A table removes the 65 535 `$o$i` locals that Rename's self-check is timed on (`Rename.zig` test). Compact printing does not apply.
- **Reach.** The table is a new synthesised top per (shape) and per (use evidence). Its edges are the evidence entries it holds, which is the same edge set `argsAt(row.body)` gives today. The helper roots `_core/_derived.mjs` the way `listEq` does now.
- **Depth, steps and the engine (backend §4).** A table row needs no per-type `$$steps` twin: write `eqFields`/`compareFields` ONCE in `_derived.mjs` with a depth parameter and a generator twin (or an explicit stack) of its own. This removes the twin that makes the List and parameter shapes 527 B/field. Order stays exact: fields in name order, constructors in declaration order, stopping at the first `False` or non-`EQ`. `run/DerivedDeepOrder`'s oracle applies unchanged.
- **Source maps (§11).** One helper line is attributed for a wide `==`, instead of one mapping per field. Positions of table entries are not source positions anyway, since derived code has `Node.no_pos`.
- **Evidence and the calling convention.** A table row's derived function keeps its signature (`$m`/positional evidence, `$x`, `$y`, `$d`). Only its BODY changes, so `ext_derived` importers and interface v3 need no change, and `Convention.derivedEvidence` stays the one owner of positional vs array. The decision rule is a pure function of the COUNT of positions (plus `Convention`'s evidence count), so exporter and importer agree without a flag. That is the same argument as §9.2's wide form.
- **What the checker must publish.** For (b), nothing new: the lowerer has `row.shape`, `argsAt(row.body)` and the context. For an identity shortcut it would need a per-row **reflexive** bit. Today `primitive strict_eq` covers both `Int` and `Float`, so the backend cannot tell that a `Float` field (NaN) makes `x === y ⇒ True` wrong. For (e2), nothing: the use's evidence terms are already `primitive p`.
- **Field identity (rule 8).** The table form preserves identity, as the current form does: it reads fields and allocates nothing. An `x === y` shortcut would EXPLOIT identity (about 5 ns for an unchanged record at any width). But it changes answers:
  - `r == r` with a NaN field: today False, then True (Elm's own quirk);
  - a non-reflexive hand-written `eq`;
  - skipped `Debug.log` lines in hand-written methods, which contradicts backend §4's "Order is exact".

  It is an owner decision, and it is only legal on rows the checker marks reflexive.

## 6. Recommendation

1. **Adopt (b) with a threshold of 1 024 positions per constructor, or record fields.** The threshold is a `Convention`-owned constant, not 4 096. Engines stop optimising the unrolled body around there (V8 cliff 512→1 024; the compare cliff is lower), so the table costs at most about 2× on a full walk in SM/JSC and wins in V8, and short-circuits in O(1). Expected results:
   - **Size and emit:** about 15× less raw and 11–15× less brotli, and about 20× less emit time for every derived row past the threshold. A 65 537-field payload goes from about 13 MB and 240 ms of emit to about 0.85 MB and about 12 ms. The 4 097-parameter type loses its steps twins.
   - **Unchanged:** every current corpus output, since the widest is 15.

   The risks:
   - (i) A 1 024–4 096-field record's full-walk `==` in Firefox/Safari becomes up to about 1.8× slower. Nobody writes one.
   - (ii) A second implementation of the depth protocol in the runtime, which needs its own `DerivedDeepOrder`-style oracle.
   - (iii) The keys array per shape must not be emitted per use.
2. **Separately, and first, because it helps widths people write:** (e1) hoist a use's closed evidence into a module `const` and pass an array past about 64 entries. Keep positional below that, since it is the fastest at 8. This removes F2 and makes (b)'s table and any identity shortcut O(1) on a mismatch.
3. **Bring to the owner, not decided here:** (e2) primitive-inlined record rows, a partial revisit of A.11 worth 1.3–3× at 8–512 fields in every engine; and the `x === y` shortcut, gated on a checker-published reflexive bit.
4. **Reject** (a) at all widths as the only form, (c) and (d).

### Spec sketch (amend, never renumber)

- **`static-dispatch-spike.md` §9.2**, after *The wide form*: add a paragraph *The table form (past 1 024 positions)*. It covers the keys array per shape, the evidence array per use, `eqFields`/`compareFields` in `_core/_derived.mjs`, that order is exact, and that the signature is unchanged. Also a new appendix entry A.nn with the measurements above. Cross-point §9.3/§9.4 to it, one sentence each, as §9.4 already does for the wide form.
- **`backend.md` §4**, *Derived comparisons do not grow the native stack*: add *The runtime* with the two helpers, their depth weight and steps. In *Emitted JavaScript nests only as deep as the source*: the table row replaces `derived_group` runs past the threshold.
- **`backend.md` §9** (reachability): the table's synthesised const is a unit, and its edges are its evidence entries.
- **`checker-v2.md` §12.5**: `Convention` gains `max_unrolled_positions` beside `max_positional_evidence`.
- **For (e1):** `static-dispatch-spike.md` §8.2 (evidence as values) and `backend.md` §6.

### Tests that would prove it (hand-picked, per the owner's rule)

- **Small width:** the existing `emit/DerivedEqShapes`, `DerivedCompareNominal` and `DerivedEqNominal` goldens stay byte-identical. That is the proof nothing under the threshold moved.
- **Threshold edge:** one `run/` fixture, or an `abuse_wide_test` scenario. A record, and a two-constructor payload, at exactly 1 024 fields (unrolled) and 1 025 (table). It covers `==`, `/=` and `<` on:
  - equal values;
  - the first field different;
  - the last field different;
  - the same object;
  - different constructors;
  - a hand-written-method field with `Debug.log`, whose output is identical across the edge (order exactness).

  Plus an `emit/` golden of the 1 025 shape (a keys array, not 1 025 `&&` terms), and a cross-module importer of a 1 025-field payload.
- **Widest:** replace the removed 65 535-field scenario with a 65 530-field `==`/`<` that builds and runs in both builds, with a byte ceiling on `W.mjs` (for example under 1.5 MB dev) so a regression to the unrolled form fails.
- **Depth:** a recursive table-form type past the depth limit (`abuse_test`'s 4 097-parameter pair, run first-position-recursive), so that the runtime helper's steps path is exercised.
