# Checker v2 — the architecture of the rewritten type checker

**Status.** Normative in three stages, set by the slices of
[`plans/checker-rewrite.md`](../../plans/checker-rewrite.md):

- **Shared code, from the slice that lands each part, for both checkers.**
  - §13 (the evidence-tree contract) from R2a, and §12.5 (`Convention`) from R2b.
  - §14.2 (interface v3) from R3.
  - §15.1's `Session` quiet rule from R1.
- **`src/check2/`**, the new checker, for everything else from R4b. The flag and harness exist from R4a.
- **`src/check/`**, the whole document, at the cut-over (R11).
- *R12 (2026-09-27):* v1 is deleted, with `--checker`, `BENI_CHECKER` and the checker id in the
  cache key, and `src/check2/` took the name `src/check/` (§19.1 *As built by R12*). A path
  `check2/X.zig` below is `check/X.zig` now; each note keeps the name it was written with.

Written 2026-09-24 at `master` = `7427828`. **Slice references.** Round 3 split four slices. A bare "R2" below means R2a, the tree contract, except where it names `Convention` (R2b). "R4" means R4a for the flag, harness and cache key, and R4b for the foundation. "R6" means R6a for resolution and `check`, and R6b for elaboration and `build`. "R8" means R8a for the fixpoint, D4 and install, and R8b for D1 privacy and schema endpoints. `checker-rewrite.md` §4 is authoritative. Revised the same day after a read-only design review
(`review-design.md`, items B1–B7, S1–S22 and N1–N13; the revision is traced in §24). Every owner
decision it depends on was **taken by the owner on 2026-09-24** (§21), and the amendments the
review required are dated in §21.

**Why this document exists.** Five reviews of the checker at `7427828` found 61 defects,
catalogued as CK-01 … CK-61 in [`plans/checker-findings.md`](../../plans/checker-findings.md).
About half compile a program and then give a wrong answer at run time. They fall into fourteen
root-cause classes, K1 … K14. The owner decided to rewrite the checker from the ground up, so that
**its structure makes each class impossible, or checked**, rather than patching each finding.

**What it supersedes, and what it does not.** [`checker.md`](checker.md) and
[`static-dispatch-spike.md`](static-dispatch-spike.md) stay normative for every external behaviour
not listed in §20. They also stay normative for the old checker until the cut-over. The table below
maps each old section to its replacement. Each of those sections carries a pointer note back here.
No section of either document is renumbered (CLAUDE.md rule 2).

| Old section | Replaced by | What changes |
|---|---|---|
| `checker.md` §5, the constraint set on `Flags` | §4.1, §4.2 | constraints become references to *wanteds*; their types are graph children |
| `checker.md` §6.2, "two additions … inside `unify`" | §7 | `unify` never resolves and never reports |
| `checker.md` §6.3, "a constrained `let` binding is not generalised" | §8.4, D5 | rule (a) is retired |
| `checker.md` §6.4, obligations | §8.5 | obligations whose variable escapes move to the outer rank |
| `checker.md` §6.5, `?` | §8.6, D2 | a deferred obligation, not a greedy probe |
| `checker.md` §6.6, the per-declaration gate | §15.2 | a failure bit, not diagnostic regions |
| `checker.md` §6.7, "has evidence parameters" defers | §12.5 | one `Convention` function |
| `static-dispatch-spike.md` §3.3, private methods | §11.3, D1 | |
| `static-dispatch-spike.md` §6.1–§6.4 | §4, §7–§10 | |
| `static-dispatch-spike.md` §6.3.1 step 4, capability paragraphs | §11 | |
| `static-dispatch-spike.md` §7.1–§7.3, the dispatch table | §13 | evidence *trees* |
| `static-dispatch-spike.md` §8.1–§8.2, what `Lower` recounts | §13.3 | |
| `static-dispatch-spike.md` §9.4, "one evidence parameter per type parameter" | §11.2, D4 | one parameter per context entry |
| `static-dispatch-spike.md` §10.12, `method_needs_annotation` | §10, D3 | retired |
| `static-dispatch-spike.md` §11, "a constrained `let` binding is monomorphic" | D5 | |

---

## 1. The fourteen classes, and the mechanism that closes each

| Class | Findings | Mechanism | § |
|---|---|---|---|
| **K1** Annotation generality unchecked | CK-01, CK-10 | **I1.** Every annotated binding is read once, as rigid variables at its own rank. After generalisation, every rigid must still be a distinct rigid root at the generalised rank; otherwise `rigid_mismatch` at the recorded capture site | §8.3 |
| **K2** Constraints and obligations outside the graph | CK-02, CK-05, CK-06, CK-18, CK-29 | **I2.** Every walk takes its successors from one of two `Walk` functions and declares which. `owned` includes a variable's wanteds' method types and serves rank adjustment, copy, the error scan, publication and the merge's rank lowering. `structural` excludes them and serves occurs, the marker walk and the resolver walks. **I15.** A wanted's method-type variables never outrank its receiver: attaching lowers them. **I3.** Obligations ride on their variables, like wanteds, and share one rank (§4.5), so one whose variable escaped travels with it | §4.1, §7.1, §8 |
| **K3** Walks that are not total | CK-03, CK-04, CK-08, CK-10, CK-37 | **I4.** No walk has a fixed-size stack, and none answers when it gives up. Every walk that can meet a cycle uses the epoch colour of §4.1 over `structural` successors and reports `infinite_type` when it does. A lambda's and a case branch's binders are occurs-checked when the lambda or branch ends. Every boundary occurs-checks after its last unification. Records are normalised on merge, and closedness reads the whole chain | §4.1, §7.3, §8.2 |
| **K4** Evidence computed in many places | CK-25, CK-27, CK-28, CK-30, CK-31, CK-32, CK-33, CK-34, CK-35 | **I5–I7.** An evidence slot is a *wanted* created by instantiating a scheme, so the number of slots comes from the callee's requirement list by construction. One elaboration pass writes trees. `Lower` never counts. One `Convention` function decides how a value with evidence is defined and called | §9, §12, §13 |
| **K5** Default answers | CK-16, CK-17, CK-20, CK-21 | **I8.** "Unknown" is never "yes". A rigid without the method is reported at the wanted's origin. A shortcut (the `number` bridge) unifies the declared method type before it answers. The contract has no `err` term, and a missing answer is `internal` | §9.3, §13 |
| **K6** Own-method ordering | CK-36 | **I9.** A use of a module's own method that has no scheme yet demands that method's group, which is checked nested **at that moment** (§10.2). A dispatch or value back-edge merges groups. There are no priority groups, and `method_needs_annotation` survives only for §11.2's non-ordering case | §10 |
| **K7** Capability computed several ways | CK-19, CK-22, CK-23, CK-24, CK-26 | **I10.** "Can `T` answer `m`?" *is* instance resolution. Derived instance contexts come from one memoised fixpoint that the module worker owns. They are published in the interface and read back on a cache hit, never recomputed | §11 |
| **K8** Stale generation context | CK-09 | **I11.** Constraint generation resolves a `.local` reference to its `Var` when it builds the node. The solver never reads `env.local_var` | §6.2 |
| **K9** Intra-module pipeline | CK-11–CK-15 | **I12.** Named sequential phases. Failure is a per-declaration bit set by the reporter on *errors*. `quiet` is enforced once, in the one emit path. There is one scheme-publication routine | §5, §14, §15 |
| **K10** Interface representation gaps | CK-38, CK-39 | interface v3: `u16` arity, record-alias constructor rows, derived contexts | §14.2 |
| **K11** Super-linear bookkeeping | CK-40, CK-41, CK-42 | epoch marks instead of store-sized memsets; an own-name index built once; the fixpoint is lazy and memoised; no per-group settling | §4.1, §18 |
| **K12** Id-order dependence | CK-07 | **I13.** Every choice among several diagnostics is made in name-text order | §7.2 |
| **K13** Diagnostic selection | CK-48–CK-61 | the resolver reports at `origin`; mismatch *categories* for method clauses and `?` legs; the cycle path is rendered | §15.4 |
| **K14** Outside the checker | CK-43–CK-47 | fixed in shared code before the rewrite | `checker-rewrite.md` R1 |

---

## 2. Invariants

Each invariant is enforced **by construction**: no code path can violate it. Where construction
alone is not enough, it is also checked by an **assert**, a debug assertion plus `internal` in a
release build. The fixtures of the CK entries in §1 are the black-box evidence.

| # | Invariant | Enforced by |
|---|---|---|
| **I1** | After a binding with an annotation is generalised, each rigid variable its annotation introduced is still a rigid root with that name, is not merged with another of its rigids, and has rank `generalized` | construction (§8.3); CK-01 |
| **I2** | Every walk over the type graph takes its successors from `Walk.structural` or `Walk.owned` (§4.1), and the choice is part of the walk's declaration | construction: `TypeStore` exposes no raw payload accessor outside `Walk.zig`. Review rule: a new walk that names neither is refused, and so is one whose choice contradicts §4.1's table. *Revised 2026-09-24 (B1): a single successor function that yielded method types made every constrained variable look cyclic to occurs.* |
| **I3** | An open obligation or wanted rides on its variables. It is decided when a variable is bound (readied), or closed when a variable is quantified. One whose variable escaped is still attached to it, so it is decided by whichever boundary quantifies or binds it | construction (§4.5). *Revised 2026-09-24 (round 2, N1): buckets removed.* |
| **I4** | No walk stops at a fixed depth or stack size without reporting. A walk that can meet a cycle detects it by colour and reports `infinite_type` | construction (`Walk.zig` is the only DFS); `check/depth/` pairs for the reported guards |
| **I5** | The evidence of an instruction that instantiates a scheme is exactly one wanted per requirement of that scheme, in the scheme's canonical order (§12.1) | construction (`Instantiate.zig` creates them); assert in `Dispatch.finish` |
| **I6** | Every wanted is answered exactly once, by one of: a given, an instance term, a promotion to a parameter, or a proven-undetermined default. An open wanted at elaboration is `internal` | construction (§12.2); assert |
| **I7** | For every term with arguments, `args.len == evidenceCount(callee)`, where the count is read from the callee's `DeclInfo`, interface entry or derived row | assert in `Dispatch.finish` and again in `Lower` (cheap) |
| **I8** | No failure to decide is answered as success. The walk, resolver and elaborator results are `yes`, `no (reason)` or `blocked (on what)`, and `blocked` is never read as `yes` | construction (the result types have no "unknown → accept" arm) |
| **I9** | Whether a program checks, and what it computes, does not depend on the order of top-level declarations | construction, by three rules. (1) Every nesting is demanded by the frame directly below it, through per-frame `ready` queues drained after every constraint node (§9.1). (2) A re-entrant derived-context query runs a fresh fixpoint (§11.2). (3) Inside a recursive group, D14 lowers the method type of **every wanted** (a method callee, instantiation evidence or a sub-wanted) that is resolved or attached while its receiver is group-level, and every variable of an obligation that has a group-level deciding variable, in `Resolve`'s single resolution function (§10.7). **One stated exception:** the nesting budget (§10.2) can refuse very deep generated code in one order only. Tested by R7's permutation scenario and `test-v2`. *Restated 2026-09-24 (round 3: B-1, B-2, B-3; round 4: R7-1, R7-3).* |
| **I10** | Whether `T` answers `m` has one answer per module, computed by one function, and a cache hit installs the published answer | construction (§11) |
| **I11** | The solver reads no generation-time context | construction: `Solve` has no `Env.local_var` |
| **I12** | A declaration's failure bit is set iff an **error** diagnostic was attributed to it or to a member of its binding group. Every consumer that must skip failed declarations reads the bit | construction (§15.2) |
| **I13** | When several independent failures could be reported and only one is, the one reported is the first in name-text or source order, never in id order | construction (§7.2) |
| **I14** | Nothing written during speculation survives a rollback. Every write a probe can make, including the in-place `Wanted.state` and `answers` writes of `unify`, is either an append truncated by rollback or a journalled in-place write. A probe never calls `Resolve`, `Instances`, `Groups`, the obligation deciders or `Report` | construction (§7.5); a debug assertion that those entry points are not reached while `journal.depth > 0`. *Revised 2026-09-24 (B5).* Consequence: a probe never nests a group check, because only resolution nests and a probe never resolves (round 3, N-1). |
| **I15** | For every wanted `w` whose receiver is **not generalised**, every variable reachable from `w.method_type` by `Walk.owned` has rank ≤ `rank(find(w.receiver))`. All variables of one open obligation have one rank | construction: attaching, and re-attaching on merge, lowers them (§7.1, §4.5), OCaml's `update_level` on binding. A debug assert checks the wanteds and obligations met during each boundary's own generalisation walk, which is linear (S-new-6). A promoted wanted on a generalised receiver is exempt: its method type may mention outer variables free, the HM(X) reading of §8.4 (S-new-4). *Added 2026-09-24 (B2); restricted and extended in round 2 (N1, S-new-4, S-new-6). Amended by R5's review (2026-09-25): the obligation half is directional — no dependant of an open obligation outranks its owner (§4.5, *Amended by R5's review*); "one rank" over-lowered a `?` target (CK-99).* |
| **I16** | A boundary generalises only after nothing it runs can unify any more, and it occurs-checks after the last unification | construction: §8.1's fixpoint loop precedes occurs and generalisation. *Added 2026-09-24 (B3).* |

---

## 3. Prior art

The design is conventional, and deliberately so. Each mechanism has a published or shipped
ancestor.

- **Constraint generation, then solving, with levels.** Elm's `Type/Constrain.hs` and
  `Type/Solve.hs`, already beni's model (`fast-compiler.md` §7). Rémy's levels (Rémy 1992) and
  Kiselyov's account of the OCaml checker ("How OCaml type checker works — or what polymorphism
  and garbage collection have in common", 2013). Generalisation scans the young pool and never the
  environment.
- **Constraint variables live at their carrier's level.** HM(X), Odersky, Sulzmann and Wehr, "Type
  inference with constrained types", TAPOS 1999. A constrained scheme `∀ā. C ⇒ τ` quantifies only
  variables that neither `C`'s outer part nor the environment fixes. OCaml's `update_level`, which
  lowers a type's levels when it is bound to a variable of a lower level, is the mechanism I15
  copies.

  **The constraint edges of `Walk.owned` are new relative to both Elm and Roc, and unexercised**
  (§23). Elm has no constraint sets. Roc stores constraints on `Flex` variables
  (`references/roc/src/types/types.zig:303-349`) but deliberately does **not** treat them as graph
  edges:
  - its occurs check skips flex constraints ("Flex variables are not checked for cycles - they are
    allowed to have self-referential constraints", `src/check/occurs.zig:262-265`);
  - its generalisation does not descend into them ("Constraints are deliberately not descended
    into", `src/types/generalize.zig:422`, `:428`).

  Roc keeps outer-receiver requirements in a side table instead (`design.md:5461-5540`). v2 splits
  the two successor functions, so occurs follows Roc and level adjustment follows HM(X).
  *Citation corrected 2026-09-24 (B1): the first draft called this "the same idea in code".*
- **Rigid escape.** Elm checks the `let`'s rigids with `isGeneric` after solving `CLet`. OCaml
  reports "the type constructor … would escape its scope" by a level test. I1 is the level test
  applied after generalisation.
- **Occurs check at every binder.** Elm's `Constrain` gives lambda arguments and case patterns
  their own `CLet` headers, so `Solve` occurs-checks them. §8.2 does the same without the extra
  headers.
- **Dictionary passing with evidence variables, elaborated after solving.** Wadler and Blott, "How
  to make ad-hoc polymorphism less ad hoc", POPL 1989. OutsideIn(X), Vytiniotis, Peyton Jones,
  Schrijvers and Sulzmann, JFP 2011: *wanteds* carry evidence variables, *givens* come from
  annotations, and the solver binds evidence that desugaring reads. §9 and §12 are OutsideIn
  restricted to single-parameter classes with head-matching instances, no overlap and no
  superclasses.
- **One enumeration defines the evidence parameters, and callers derive theirs from it.** Roc's
  `dispatch_evidence.zig:1-27` and `design.md:9044-9075`, with its `validateDispatchEvidence`
  totality check (`checked_artifact.zig:31800-31830`). See I5–I7.
- **Derived instance contexts by fixpoint.** The Haskell 2010 Report §11 (derived instances), and
  GHC's `deriving`, which infers the context of a derived instance by iterating to a least fixpoint
  (`simplifyDeriv`). §11.2.
- **Deferral of a dispatch into an unchecked, untyped local method.** Roc
  `Check.zig:31704-31762` and `:13978-14045` (`resolveGroupPendingDispatchTargets`), and
  `design.md:2197-2231` ("group suspension and merge need no dedicated machinery"). Roc accepts
  exactly the program row 75 refuses (`scheme_use_evidence_test.zig:96-122`). §10.
- **Rejection as a class flag, not poison.** Roc `store.zig:756-771` and `design.md:8860-8880`
  (CK-37).
- **Migration behind a flag, with the old implementation as the oracle.** rustc's next-generation
  trait solver shipped behind `-Znext-solver` and ran the test suite and crater under both before
  switching (§22).

**What is not copied from Roc**, per `review-roc.md` §6:
- the promoted-requirements side table for outer-rank receivers (`design.md:5461-5760`, the most
  bug-dense part of Roc). I2 makes it unnecessary: a requirement on an outer receiver lives at the
  outer rank;
- `.lss` monomorphisation;
- `EvidenceChainIndex.depth`, because closures capture lexically;
- numeric-literal dispatch.

---

## 4. Data structures

### 4.1 The store

`check2/TypeStore.zig` is the current store, adapted. The union-find with path compression, the
Rémy rank kept separate from the tree rank, roots-only accessors, and the nested undo journal whose
snapshot truncates `vars` and `extra` are all kept.

```zig
pub const Descriptor = struct {       // MultiArrayList column set, unchanged except `mark`
    parent: Var,
    rank: u32,                        // `generalized` = 0
    content: Content,
    mark: u32,                        // an EPOCH stamp; see below
    copy: Var.Optional,               // the instantiation memo
};
pub const Flags = struct {            // flex and rigid payload
    name: Symbol.Optional = .none,
    kind: Kind = .any,                // any | number | appendable, closed (fast-compiler §3.1)
    equatable: bool = false,          // the core-only structural marker (§11.4)
    wants: WantList.Optional = .none, // NEW: a range into `want_links`: the wanteds riding here
    obls: OblList.Optional = .none,   // NEW: a range into `obl_links`: the open obligations riding here (§4.5)
};
```

- **`wants` replaces `constraints`.** The entries are `WantedId`s (§4.2), not copies of
  constraints. A variable's method requirements are therefore one table, not one table per variable
  plus site lists. `want_links` is append-only. A merge appends the union and leaves both inputs, so
  a rollback is a truncation (I14).
- **Two successor functions, and every walk names one** (I2). For a root `v`:

  | Content | `Walk.structural(v)` | `Walk.owned(v)` |
  |---|---|---|
  | `structure` | every argument, parameter, result, field type and the extension | the same |
  | `alias` | the arguments and `actual` | the same |
  | `flex` | nothing | **the `method_type` of every wanted in `wants`** |
  | `rigid` | nothing | the `method_type` of every wanted, and of every given |
  | `err` | nothing | nothing |

  Which walk uses which:

  | Walk | Successors | Why |
  |---|---|---|
  | occurs (§8.2), the marker walk (§11.4), `recordRow`, resolver and instance walks (§9.5), `unify` | `structural` | a method type nearly always mentions its own receiver (`x.eq : x, x -> Bool`), so following it would make every constrained variable a false cycle, and would find a function inside every `==`'s receiver. This matches Roc (§3) |
  | `adjustRank`, `copyHelp`, `hasError`, `Schemes.Writer`, `lowerTo` (I15, §7.1), the merge's rank lowering (§10.4), the I15 assert | `owned` | what a variable's requirements mention must be copied with it, generalised with it, published with it, and never outrank it |

  A self-reference through `owned` is expected and harmless. `owned` walks are rank or memo walks
  that stop at a visited node (epoch mark). They are not colour walks and never report a cycle.

  `owned` alone does not close CK-02. Elm's `adjustRank` descends only from young-pool entries, and
  CK-02's receiver `x` is not young. So I15 **lowers** a method type's variables when the wanted is
  attached (§7.1). With both, CK-02 and CK-29 are closed by construction.
  *Revised 2026-09-24 (B1, B2).*
- **Epoch marks, not memsets.** `mark` holds the epoch of the walk that last visited the node. A walk
  takes `epoch = store.nextEpoch()` and tests `mark == epoch`, so there is no clearing pass and no
  store-sized allocation per walk. A three-colour walk (occurs, cycle-safe resolution) takes two
  consecutive epochs, one for grey and one for black. This also fixes `Schemes.Writer.resetMemo`
  (CK-41) and `schemaPropertiesWithDeps`' `seen` (CK-40).
- **Growable DFS stacks only** (I4). `Walk.zig` owns one reusable `std.ArrayList` stack per walk
  kind on the module's scratch arena. There are no fixed arrays.
- **Records are normalised on merge** (CK-08). When `unifyRecord` merges two records, the surviving
  root's content is the *flattened* record: the union of the fields, sorted by symbol for the
  merge-join, plus the final extension. So a closed record stays one node with `ext =
  empty_record`. `Walk.recordRow(v)` follows an extension chain to its end and is the only
  closedness test. A chain can still exist transiently inside a `unify` call.

  Symbol order is internal to the merge-join. **Everything that shows or chooses among fields orders
  them by name text:** `Render`, `Schemes.Writer`, the failure choice of §7.2 and the derived
  `Shape.record` key. This is already true of `Render` and the writer today, and it keeps CK-07's
  class out of messages (N5).

*As built by R4b (2026-09-25): the store is the shared type, and `Flags` is unchanged.* v2's store
**is** `src/check/TypeStore.zig`'s type, unmodified, and R4b writes no `check2/TypeStore.zig`:

- Every piece §19 keeps shared reads that type — `Render` (every message), `Schemes` (the
  interface writer and reader), `Types.Builder` (every annotation), `Schema.State`,
  `SchemaPlanBuild`, `Exhaustive`'s context and `dump --stage=types` — so a second store type would
  have meant copying all of them, which §19.1 forbids ("imports the shared files … and does not
  copy them").
- R4b needs none of the additions above. The union-find, ranks, epoch marks (`nextMark`), `copy`
  memo and journal are already the store's. `wants` and `obls` carry nothing in R4b's subset (§5,
  *As built by R4b*): no module v2 checks ever attaches a method constraint or an obligation.
- **Owed by R5/R6a (a design gap, not decided here):** `Flags.wants`/`obls` cannot be added to the
  shared `Flags` without changing v1, which is frozen (§22). The likely form is a v2-owned
  `check2/TypeStore.zig` that wraps the shared store and keeps `wants`/`obls` as **side columns
  indexed by root**, merged on union and truncated on rollback like `extra`, so the shared readers
  keep working. R5 decides and amends this paragraph. *(Decided by R5 below.)*

*Decided by R5 (2026-09-25), before any obligation code: `obls` is one new field of the shared
`Flags`, and `wants` is the shared `Flags.constraints` that already exists.* Three options were on
the table (`plans/checker-rewrite.md` R5): fork the store type with its writer and printer; extend
the shared `Flags`; or v2 side columns indexed by root, with hooks into the writer and printer.

- **`obls: ObligationSet.Optional`** is added to `src/check/TypeStore.zig`'s `Flags`. It is an
  opaque `u32` naming a set in v2's own table (`check2/Obligations.zig`: the obligation rows, the
  sets and their links, §4.5). The store knows nothing about what it names. v1 never writes it and
  never reads it: every `Flags` v1 builds is a literal that leaves it at its default `.none`, and
  v1's one rebuild of a `Flags` from parts (CK-18's `dischargeEquatable`) drops it exactly as it
  drops `constraints`, on a variable that never has one. `Flags` grows from 12 to 16 bytes and
  `Content` does not grow: its largest payloads, `Structure` and `Alias`, are already 16 bytes (a
  comptime assert in `TypeStore.zig` holds it at 20). **v1's behaviour is byte-identical**, proved
  by the whole corpus under v1 and the dumps of every fixture, before and after (R5 *As built*).
- **`wants` is `Flags.constraints`.** The method requirements riding on a variable are what the
  shared `Schemes.Writer` publishes and `Render` prints, and both read `Flags.constraints` today.
  Keeping `wants` there means neither is forked or hooked. R6a pairs each `MethodConstraint` entry
  with its `WantedId` in a v2 column indexed by the entry's position (the entries are append-only,
  so a position never changes meaning). How it pairs them is R6a's to write down here.
- **Why not side columns.** A column indexed by variable would be a second owner of "what rides
  on this variable": it must grow with every `store.fresh` (shared code that cannot know it), be
  kept in step with every merge, and be rolled back beside the journal rather than by it, and the
  shared writer and printer could not see it without a hook each. In the descriptor, the fact moves
  with `find`, `merge` and the undo journal for free, like `kind` and `equatable` beside it.
- **Why not a fork.** §19.1 forbids copying the shared readers, and a second store type would copy
  all of them (`Render`, `Schemes`, `Types.Builder`, `Schema.State`, `Exhaustive`'s context).
- **One owner per fact.** The link "this obligation rides here" is the descriptor's; the
  obligation itself (kind, variables, region, state) is `Obligations.zig`'s row; every merge of two
  `Flags` is `Unify.zig`'s, `obls` included (CK-18's class: v2 never rebuilds a `Flags` field by
  field — it copies the struct and changes one field).
- **I2 as enforced in R4b** (restated by R4b's review, S6): **a type's children are read only
  through `Walk`** — every traversal takes its successors from `Walk.child(…, .structural |
  .owned | .payload)`, and a function's parameters, a record's field in a range just built and a
  variable's constraints have one accessor each there (`Walk.function`, `Walk.fieldIn`,
  `Walk.constraints`). `Unify.zig` and `Instantiate.zig` also read children, to pair two
  structures and to copy one. Anyone may read a node's tag and flags. `src/check2/rules_test.zig`
  enforces it by reading the sources, since the shared store cannot (and refuses an import of v1's
  `Constrain.zig` or `Solve.zig`). The shared readers above keep their own walks (v1 code, kept).

### 4.2 Wanteds, givens and evidence

These tables are per module, append-only and index-based (`check2/Evidence.zig`). None is keyed by
anything but its own index.

```zig
pub const WantedId = enum(u32) { _ };   // also the evidence variable: one wanted, one EvId
pub const Wanted = struct {
    method: Symbol,
    receiver: Var,                      // the carrier; may become concrete
    method_type: Var,                   // the method's type AT THIS USE
    origin: Bir.Inst.Index.Optional,    // the instruction in THIS module that raised it (primary region);
                                        // .none for P5 eager rows and fixpoint wanteds (§11.2), which
                                        // have no instruction and never report at a site
    origin_decl: Origin,                // decl(DeclIndex) | derived(TypeId, Kind): the owner of the
                                        // failure bit (§15.2) and the "origin module" D1 reads (always
                                        // this module: wanteds are per module)
    region: Bir.Inst.Index,             // where the requirement was written (a where clause, an operator)
    owner: Binder,                      // whose evidence parameters an answer may name (§4.3)
    frame: FrameId,                     // the frame current at creation: whose `ready` queue it joins (§9.1)
    seq: u32,                           // module-wide creation sequence, shared with obligations (§9.1)
    state: enum(u8) { open, ready, answered, promoted, defaulted, failed },
};
pub const Given = struct {              // from an annotation's `where`, or a derived body's context
    rigid: Var, method: Symbol, method_type: Var, binder: Binder, k: u16,
};
pub const Answer = union(enum(u8)) {    // what a wanted is bound to; the evidence TERM, pre-elaboration
    param: struct { binder: Binder, k: u16 },
    alias: WantedId,                    // a Rule-U1 join: this wanted IS that one
    top: struct { decl: Bir.DeclIndex, args: WantRange },
    ext: struct { module: Graph.Index, value: Interface.ValueIndex, args: WantRange },
    derived: struct { index: u32, args: WantRange },
    ext_derived: struct { module: Graph.Index, type: Types.TypeId, kind: Derived.Kind, args: WantRange },
    primitive: Dispatch.Primitive,
    undetermined,                       // §9.4 proven-undetermined default (§13.1)
    field,                              // the callee of a dot-call on a record's function field
    group_call: struct { callee: Bir.DeclIndex },  // args filled from the callee's final list (§12.3)
};
answers: []Answer.Optional              // indexed by WantedId
inst_evidence: []WantRange              // per instruction that instantiated a constrained scheme
inst_callee: []WantedId.Optional        // per `method_call`/`type_dispatch`: the wanted naming the function
```

- **An instantiation creates the evidence.** Instantiating a scheme with requirements `R₀ … Rₙ₋₁`
  (canonical order, §12.1) creates `n` fresh wanteds whose `method_type`s are copied through the
  same memo as the body. The instantiating instruction records them as `inst_evidence[inst]`. The
  count is the scheme's by construction (I5). No cursor, parent pointer or site list exists.
- **A `method_call` node creates one wanted**, the callee, recorded as `inst_callee[inst]`.
  Resolving it may create sub-wanteds, the target's own evidence, as its `args`.
- **A join is an alias.** When two variables that both carry a wanted named `m` merge (Rule U1), the
  two `method_type`s are unified and the younger wanted is answered `alias(older)`. There is no
  `resolved_methods`, no `superseded` redirect, no `adopt` and no `committed_copy`: an alias is the
  whole mechanism (disp R2).
- **In-place writes are journalled** (I14, B5). `Wanted.state` and `answers[id]` can be written for
  a wanted created before a speculation's snapshot:
  - the alias of a join;
  - `open → ready` when a flex is bound;
  - `→ failed` against `err`.

  Each such write goes through `TypeStore.journal` as a `WantUndo { id, old_state, old_answer }`
  entry, so `rollback` restores it exactly as it restores a descriptor. Resolution, promotion and
  elaboration write the same fields, but they never run inside a probe (I14), so they need no
  journal.

*As built by R6a (2026-09-25): how a `Flags.constraints` entry is paired with its wanted, and what
R6a records.* `check2/Evidence.zig` holds the tables; §4.1's *Decided by R5* left the pairing to R6a.

- **By position.** `Evidence.slots[p]` names what sits at position `p` of the store's append-only
  `constraints` table: a wanted, a given (a rigid's entry, tagged), or nothing. An OPEN wanted on a
  flex receiver is exactly one entry of that flex's set, so a flex's set is its open wanteds and
  `Schemes.Writer` publishes a promoted scheme's requirements with no hook. Every place v2 makes an
  entry pairs it in the same step: attaching (`Resolve.attach`, which re-pairs a copied range when
  `extendConstraints` could not append in place), a merge's union (`Unify.unionWants`), a copy's
  requirements (`Instantiate.want`) and an imported scheme's (`Instantiate.wantImported`, the
  entries `Schemes.instantiate` made). A given's position is its identity: a rigid's set is never
  rebuilt.
- **`Given`** is `{ rigid, method, method_type, decl, k }`: registered when a top-level annotated
  declaration's rigid reading is made (`Evidence.registerGivens`), `k` its index in
  `Evidence.requirements` of that reading. A `let` annotation has no `where` clause
  (`language.md`), so every binder is `decl` until D5 (R14). *R14 (2026-09-27):* still true of
  givens; a `let` binding's promoted wanted is answered `promoted`, and P6 names its parameter
  `param let <inst> k` (§12.3 *as built by R14*).
- **`Wanted`** is §4.2's row less `owner` and `frame` (one top-level frame at a time until R7:
  every wanted joins `Solve.ready`) and plus `parent` (the lineage of §9.5) and `kind` (the surface:
  dot-call, operator, `where` clause, `type_dispatch` — which decides derivation and the texts).
  `seq` is the one counter obligations use (`Obligations.seq`), so the queue drains both in creation
  order. *Revised by R6a's review (2026-09-25, B1):* the `walked` bit is gone — it let a position
  skip the derivability verdict, and a flex position bound later was then never asked (§9 *As
  built by R6a*).
- **`Answer`** is recorded for every answered wanted: `param { decl, k }` for a GIVEN (the
  declaration's `where` clause, `k` its index in the clause's canonical order), `promoted { root,
  method }` for a requirement promotion kept, `alias`, `top`/`ext` with their instantiation's
  wanteds as `args`, `derived` with its positions, `primitive`, `undetermined`, `field`,
  `group_call`; P6 (R6b) elaborates them. *Revised by R6a's review (S1):* a promoted wanted
  records its REQUIREMENT, never an index — the index is the member's at the site, which P6
  computes by §12.3 (a recursive group's members share quantifiers, so one wanted can be a
  different member's `k` at each site).
- **`inst_evidence`** *(revised by R6a's review, B4)* is recorded where the wanteds are CREATED: a
  copy (`Instantiate.copy`) and an imported scheme (`Instantiate.wantImported`) make their
  requirements' wanteds in `Evidence.requirements` order of the scheme — §12.1's canonical order,
  the one function the writer and promotion read — and `Solve.instantiated` records them as the
  instruction's row. A `top`/`ext` answer's `args` are the same list. Nothing downstream reorders
  evidence: I5 holds by construction.
- **Every entry is paired, or the compiler says so** *(revised by R6a's review, S2)*. A flex's
  entry with no wanted — in `Unify`'s release and union, `Solve.poison`, `Resolve.attach`, promotion,
  the cap, an instantiation's copy — is `internal`: `Solve.expect` (a debug build stops, a release
  build reports and takes the safe path) or, inside `Unify`, which never reports, `Unify.invariant`,
  whose first fault `Solve` reports after the unification. Never a silent `continue`.
- **In-place writes are not journalled**: v2 still has no speculation (§7.5), and `Resolve.step`
  asserts that no snapshot is open (I14).

### 4.3 Binders

```zig
pub const Binder = union(enum(u8)) {
    decl: Bir.DeclIndex,         // a top-level declaration's evidence parameters
    let_def: Bir.Inst.Index,     // a generalised constrained `let` binding (D5)
    derived: u32,                // a derived function's context parameters (§11.2)
};
```

A `param` answer names a binder and an index into that binder's requirement list. The elaborator
checks that the binder encloses the site. A `param` that names a non-enclosing binder is `internal`.

### 4.4 Groups

`check2/Groups.zig` owns the SCC decomposition, exactly as today's `bindingGroups`: top-level values
over `refs`, `let` bindings over local references. Per top-level group it holds:

```zig
status: enum { unchecked, checking, done },
frame: ?u32,           // index into the frame stack while `checking`
merged_into: ?GroupId, // union-find parent after a back-edge (§10.4); none = its own root
```

The **effective status** of a group is the status of `root(g)`, following `merged_into` to the
root, as in union-find. A group merged into a root that is now `done` reads as `done`, and a
back-edge to a merged group merges from its root (S-new-3).

*Simplified 2026-09-24 (review round 2, N3).* The `parked` lists, the `value_deps` prefix lists and
the `merged` status are deleted. Nesting happens at demand (§10.2), so nothing waits in a group.

*As built by R7 (2026-09-26):* `Groups.zig`; `frame_of[g]` is `frame`, the SCCs are
read from `Module.bindingGroups`; a group is `checking` from its generation on (§10.8).

### 4.5 Obligations ride on their variables

`tuple_index`, `interpolatable`, `equatable` (explicit `Basics.eq`/`neq`) and `try` (§8.6) are
`Obligation { kind, vars, region, state, frame, seq }` rows (`frame` and `seq` as for wanteds, §9.1) in one append-only table, exactly like wanteds.
An **open** obligation is attached to each of its flex variables through `Flags.obls`, a range into
the append-only `obl_links`, which merges like `wants`.

- **`Walk.owned` yields an obligation's other variables**, as it yields a wanted's method type:
  the `tuple_index` result, and the `try` subject, target result and instruction result.
- **All variables of one obligation share one rank** (I15, extended). Creating an obligation runs
  `lowerTo(vars, min rank of vars)`. So does every merge that moves it, because the surviving
  root's rank can only be lower.
  - What is lowered is the closure of the **result** variables (the `tuple_index` result, the `try`
    instruction result). The **deciding** variables, the tuple and the `try` subject and target, are
    flex roots for as long as the obligation is open, so their closure is just themselves and their
    own requirements. Nothing else, such as a subject's success type, is over-lowered. R5's reviewer
    tests a `let`-local `?` whose target escapes and whose subject is otherwise young (round 3, N-3).
  - In N1's program, `a = p.0` has its result `r` lowered to `p`'s outer rank, so `a` is not
    generalised to `∀r. r`, and `( a + snd p, String.length a )` is the `type_mismatch` it should
    be.
- **Readied through their variable**, as wanteds are. When a flex carrying it is bound to a
  structure or a rigid, the obligation goes on **its creation frame's** `ready` queue (§9.1; row field `frame`, round 4 R4-1). It is decided in the
  settle loop of the frame that drains it (§8.1).
- **Decided at quantification.** When generalisation quantifies a variable that still carries open
  obligations, the boundary's close step reports or folds them, per §8.5. That is where v1 already
  handles the `equatable` flag.
- **Carried by escape.** An obligation whose variable escaped is simply still attached to it. There
  are no buckets and nothing to re-bucket (I3).

The cost is linear: each obligation is attached once, readied at most once and closed at most once
(S-new-2). *Revised 2026-09-24 (review round 2, N1 and S-new-2): per-rank buckets, and extras
"treated as children" without any lowering, let an outer variable's obligation extras be
generalised.*

*Amended by R5's review (2026-09-25): every obligation has an **owner**, and rank sharing runs
from the owner to its dependants, never back.* The round-2 text above ("all variables of one
obligation share one rank") over-constrains a `?`. In

```elm
f u =
    let
        g k =
            k (u?)
    in
    ( g (\v -> Ok v), g (\v -> Ok (String.fromInt v)) )
```

the subject `u` is `f`'s and the target is `g`'s own result. Sharing one rank lowered the target
to `u`'s rank, so `g` stopped being polymorphic in its result — including the result's *success*
type, which a `?` never constrains — and v2 refused a program v1 builds and runs
(`tests/corpus/run/TryTargetKeepsItsSuccessType.beni`, CK-99). What a decision couples is: the
subject and the target share a head and an error type, and the value is the subject's payload.
The target's own success type is free. D2 as amended (§21.1) already names the owner: the
boundary that decides a `?` by default is **the target's own generalisation boundary**. So:

| Kind | Owner | Dependants (lowered to the owner's rank, never the reverse) |
|---|---|---|
| `tuple_index` | the tuple | the result |
| `interpolatable` | the part | — |
| `equatable` | the variable | — |
| `try` | the **target's** result | the subject and the value |

- Lowering the dependants keeps N1 and N2: in CK-68's program the `.0` result drops to `p`'s rank,
  and in N2's (`g u = k (u?)`, target outer through `k`) the subject `u` drops to the target's
  rank, so `g` is not generalised over it.
- A `?` whose subject is outer and whose target is young (the program above) is owned by the
  target's frame. If nothing decided it by that frame's step 3, it is defaulted there, to
  `Result`, as v1 decides it. A fact about the subject that comes later, in the outer frame, is
  too late for it. That is D2 as amended ("the target's own generalisation boundary"), and v1
  refuses the same programs.
- **I15, as enforced from R5:** for every open obligation, no dependant outranks its owner. Every
  obligation variable is a flex root while the row is open, except a result, which may be bound
  to a structure; `lowerTo` then lowers that structure's closure, like any variable bound to an
  outer one. So the round-2 sentence is replaced by the table above. `Walk.owned` yields a row's
  dependants from its owner only.

*As built by R5, after its review (2026-09-25).* `check2/Obligations.zig` holds the rows and the
sets, and `Flags.obls` (§4.1, *Decided by R5*) is the link.

- **A row** is `{ kind, state, region, seq, origin, reported, vars[3], index }`. `vars` holds the
  deciding variables first (the tuple; the part; the `try` subject and target), then the results
  (the `tuple_index` result, the `try` value), padded with the first. `origin` and `reported`
  serve the `equatable` marker (§11.4 *As built by R5*). `seq` is the table's counter until R6a
  shares it with wanteds, and the drain sorts by it.
- **A set** is a growable list of row ids, one per variable that carries rows, mutated in place.
  Attaching a row appends to the owner's set. A merge of two flexes moves the smaller set's open
  rows into the larger one (union by size). Neither is persistent: no speculation exists yet
  (§7.5), and the probe, when it arrives, must journal set mutations or never merge a set.
- **Decided at once, or attached.** The solver creates the row at its node and decides it there
  when a deciding variable is already known. A `try` is decided when **either** side is (D2 as
  amended). Otherwise the row is attached to every deciding flex root, its dependants are lowered
  to the owner's rank, and a `try` goes on the open-`try` list of the frame at its target's rank.
- **A merge** of two flexes lowers the dependants of only the rows owned by a side whose rank
  strictly dropped. The rows at the surviving rank already hold I15.
- **Readied**: `Unify.bind`, a merge with `err` and `Solve.poison` ready a flex's open rows onto
  the top-level frame's queue. `Solve` owns that queue, and `Unify` holds one pointer to it (§9.1:
  every `let` frame routes there; R7 makes the queue per frame). A row readied onto a variable
  that is still a flex is re-attached, not decided: a bind to an alias whose expansion is a flex.
- **Cost (the §4.5 claim, stated precisely).** Let R be the rows, M the flex merges and D the
  deepest nesting of frames. Then:
  - Attaching is O(1) amortised.
  - A merge moves the smaller set, so all moves together are O(R log R).
  - A row's dependants are lowered once at attachment and once per strict rank drop of its owner:
    O(R · D) in all.
  - Readying and closing touch each row once.
  - Step 3 looks at a `try` row once per frame it passes through on its way out: O(tries · D).

  CK-96, CK-97 and CK-98 time the three shapes that were quadratic before
  (`tests/blackbox/perf_test.zig`, `zig build test-perf`).
- No row or set write is journalled (§7.5, I14): see above.

---

## 5. The per-module pipeline

`check2/Module.zig` runs these phases in this order, once per module, with no re-settling. Each
phase reads and writes only what its row says.

| Phase | Name | Reads | Writes |
|---|---|---|---|
| P1 | `setup` | Bir, interfaces of imports | store, the tables of §4, schema state (`Schema.State.buildAll`) |
| P2 | `annotations` | every annotated value and its `where` | each annotated declaration's **published scheme**, read at rank `generalized` (§6.6); `DeclInfo.requirements` for bodiless `foreign … where`. No rigid of P2 is ever unified |
| P3 | `index` | the declaration table | own-name index `Symbol → DeclIndex` (all values; `pub` bit), own nominal types; replaces the linear `ownDeclNamed` scans (CK-42) |
| P4 | `groups` | everything above | per group in SCC order, **skipping groups whose effective status is already `done`** because a nesting checked them (round 3, S-7), through `checkGroup` (§10.2): constrain, solve, resolve (nesting other groups at demand), occurs, generalise, check generality, promote |
| P5 | `derived` | the fixpoint of §11 (already memoised during P4) | the eager derived rows for every own nominal type (A.23) |
| P6 | `elaborate` | answers, `inst_evidence`, `inst_callee`, group-call records | the dispatch table's trees (§12.2, §13) |
| P7 | `exhaustive` | failure bits (§15.2), Bir | `missing_patterns`, `redundant_pattern`, refutable-pattern diagnostics |
| P8 | `publish` | schemes, derived contexts | the interface record through the one routine (§14.1) |
| P9 | `finish` | the dispatch table | `Dispatch.finish` (sort, assert I5–I7), `--roundtrip-dispatch`, `Cycles.run`, then the schema plan, gated on the module having **no error after cycles** (CK-15) |

- The profile events `constrain`, `solve`, `resolve`, `derived`, `elaborate`, `exhaustive` and
  `publish` nest inside `check`, one per phase. Nothing super-linear can then hide *between* events
  (orch F3).
  *As built by R8c (2026-09-26):* `derived` (P5), `elaborate` (P6), `publish` (P8) and `finish`
  (P9) are `Profile.Phase`s, one event each per module under `--checker=v2`, nested in `check`
  (`blackbox_test.zig`, "--self-profile under --checker=v2 …"). `resolve` stays inside `solve`: the
  name is the frontend's resolution event.
- `--roundtrip-interfaces` stays where it is, after P8.
- The inter-module machinery is kept (§19): the DAG scheduler, the core gate, the cutoff-key
  protocol and cache install. It moves out of `Check.zig` into `Driver.zig` and `Incremental.zig`,
  and calls `Module.check(m)` or `Module.install(m, entry)`.

*As built by R4b (2026-09-25).* R4b runs P1, P2, P4, P7, P8 and P9, and only on a module in its
**subset**:

- **The gate (P0).** Before P1, `Subset.zig` scans the module's Bir once and names the first slice
  the module needs, or none:
  - **R6a** — a `method_call` or `type_dispatch` (every `x.m`, `==`, `<`, operator section), a
    declaration with a `where` clause, or a reference to an imported value, schema member or
    schema constructor whose scheme carries a method constraint;
  - **R5** — a `tuple_index`, `interp` or `try` instruction, an annotation variable written
    `equatable`, or a reference to an imported scheme with an `equatable` quantifier
    (`Basics.eq`/`neq`).

  A module that needs any of them reports ONE `not_implemented` at its first offending
  instruction, naming the latest slice it needs, and publishes nothing (the shell, as R4a's stub
  did), through `Report.appendTo`, the one emit path's list half (§15.1). A module an earlier
  phase reported on, or the graph poisoned, reports nothing, as before.

  *Revised by R4b's review (2026-09-25; S8, the manager's decision).* The gate first had a third
  slice, **R8a**, for a module that declares a `type` or a tagged schema (P5's eager derived rows).
  It no longer does: such a module is **checked**. Its interface's `eq`/`compare` rows say
  `unchecked` until R8a, and nothing reads them before then. Only a `--library` build needs the
  rows — it exports every nominal one (`Reach.collectRoots`) — so `js/Emit.zig` refuses a
  `--library` build under `--checker=v2` whose root package declares a `type`, with
  `not_implemented` naming R8a, before any output exists, the way it refuses schemas.
  `tests/pending/v2-subset.sh` reads the same rule off v1's dumps: no `site`, only `evidence=0`,
  none of the R5 or R6a forms, no `derived` row in a `dispatch/` fixture (v2's table has none),
  and no `type` in an `emit/` or `emit/release/` fixture (a library). `test-v2` cross-checks the
  two: a fixture v2 does not refuse either passes or is listed in `v2-expected.md`
  (`REPORT DRIFT` otherwise).
- **P3** is not needed: the own-name index serves resolution (R6a). **P5 and P6** are R8a's and
  R6b's; P9's table is one `DeclInfo` per declaration (`value_arity` from the scheme, convention
  `plain`), no site, no term.
- **P9's order**: the table, `--roundtrip-dispatch` on the table, `Cycles.run`, then the schema
  plan — gated on no error in the module, so after `Cycles` (CK-15) — and then the plan's own
  canonical round trip under the same flag. v1 round-trips the plan together with the table, which
  it can because it builds the plan first; built after `Cycles`, the plan cannot be in the table's
  round trip.
- The profile events are `check`, `constrain`, `solve` and `exhaustive`; `resolve`, `derived`,
  `elaborate` and `publish` arrive with the phases that have work (no `Profile.Phase` exists for
  them yet).

*Widened by R5 (2026-09-25).* The gate's R5 row is gone: a `tuple_index`, `interp` or `try`
instruction, an annotation variable written `equatable` and an imported `equatable` quantifier
(`Basics.eq`/`neq`) are checked. The one refusal left is **R6a**'s (dispatch); the eager derived
rows stay R8a's, refused only for a `--library` build. `tests/pending/v2-subset.sh` drops the same
forms, and `test-v2`'s drift check (`REPORT DRIFT`) holds the two together: on R5's corpus every
one of the 355 fixtures the script names passes, and no fixture v2 does not refuse is red outside
`v2-expected.md`. P9's table gains the `tries` rows (§8.6 *As built by R5*).

*Widened by R6a (2026-09-25).* The gate is gone: v2 **checks every construct**, dispatch included,
and P3 runs (the own-name index, a sorted `(name, decl)` array searched by `Solve.ownValue`: CK-42).
What remains outside it is refused where it arises, never by a pre-scan:

- **P6 is R6b's.** A root module whose own code needs evidence elaborated (`check2/Subset.zig`'s
  `needsElaboration`: a `method_call` or `type_dispatch`, a `where` clause, or a reference to an
  imported scheme with a requirement) is checked, but `js/Emit.zig` refuses to **build** it
  (`not_implemented`, R6b, before any output) and `main.zig` refuses its `dump --stage=dispatch`.
  `check` needs no elaboration. P9's table holds each declaration's requirement list (canonical
  order, §12.1) and its convention with that count, and one `callee` term per `method_call` or
  `type_dispatch` whose callee resolved to a value (`top` or `ext`) — the edge `Cycles` reads
  (`Edges.declEdges`' third leg), so a value cycle through a method is still `cyclic_value`. The
  refusal is by the Bir and the imports' interfaces only, so a cache hit answers the same.
- **An unannotated own method used before its group** (§10, R7) is `not_implemented` at the use —
  in the module rule, and in a derivability walk that meets an own type whose method of that name
  has no scheme yet. A module that reports one keeps only its refusals (`Report.keepOnlyRefusals`):
  what a use v2 could not type implies is noise.
- **Derived contexts** (§11.2, R8a) are v1's one-entry-per-parameter rule: a nominal type's derived
  `eq`/`compare` asks each type argument for the same method, and whether the type derives at all
  is the session's capability bit, which v2 settles for its own module with the shared
  `Types.settleDispatchCapabilities` (the scheme-driven settle v1 runs first) at P4's start and
  after a group that publishes an unannotated `pub eq` or `compare`. Where v1's second,
  probe-driven settle answers differently, v2 differs (listed in `tests/pending/v2-expected.md`,
  R8a). A cache hit runs the same settle and skips v1's derived-row restore
  (`Incremental.install`): v2 writes no derived row before R8a.

*Widened by R6b (2026-09-25).* P5 and P6 run, so v2 **builds** what it checks; `Subset.zig` and the
two refusals it fed (`js/Emit.zig`'s build, `main.zig`'s `dump --stage=dispatch`) are gone. What
remains refused is refused where it arises:

- **P5 is v1's rows under v1's rule until R8a** (`check2/Eager.zig`). Every own nominal type gets
  an `eq` and a `compare` row unless the module has a `pub` value of that name or the capability bit
  says the type cannot answer it; the context is one entry per type parameter; the body is ONE
  wanted per constructor argument, on the argument's type read with the parameters bound to fresh
  flex markers, resolved in a frame of its own with a quiet report. A position left open on a
  marker for the row's own method is that marker's context entry (`param derived i k`); anything
  else — a position the resolver refused, a payload asking the parameter for another method — means
  the row is not written, nor any row whose body names it. A USE whose answer is such a row is
  `not_implemented` (R8a) at the use, from P6.
- **The capability bits a dependent reads are the rows'.** After P9 a module's own ADTs derive
  exactly when it wrote a row (`Types.restoreDerivedCapabilities`, which `Incremental.install` now
  runs for v2 too), so a dependent never names a row that was not written, and a cache hit and a
  cold check agree by construction. Where a type answered the settle but P5 wrote no row, the
  dependent's comparison is refused (`not_equatable`), as v1's second settle refuses it.
- **P6** runs after P5, before P7 (`check2/Elaborate.zig`, §12.2 *As built by R6b*). The I7 assert
  runs last in P9, after `Cycles`, on a module that reported nothing (§13.1).
- A `--library` build whose root package declares a `type` is still refused (R8a): it exports every
  row, and R8a's contexts change them.

---

## 6. Constraint generation

`check2/constrain/` holds `Expr.zig`, `Pattern.zig` and `Decl.zig`, about 700 lines each. The
per-form rules are `checker.md` §6.1's table, kept verbatim. The changes are these.

### 6.1 One tree per group, generated in one pass

Unchanged in shape: Elm's `Constrain` over a binding group, producing `equal`, `let`, `and`,
pattern constraints, obligations, and the `method` node of `static-dispatch-spike.md` §6.2 Rule U0.
The tree is solved left to right.

### 6.2 `.local` resolved at generation (I11, CK-09)

The generator resolves a `.local` reference to its `Var` while it builds the node. It reads the
member's own `local_type` slice, which it holds at that point, and emits `instantiate(var)` for a
generalised local or `equal(var)` for a monomorphic one. The solver's `schemeOf` has no `.local`
arm. `Env.local_var` is not visible to `Solve`.

*As built by R4b (2026-09-25).* Resolving at generation needs every binder's variable to exist
before any reference to it is generated, which v1's order did not give (it generated a `let`'s body
first and its groups last to first, and looked locals up at solve time):

- **Generation runs in solving order**: a `let`'s groups first to last, each one's bindings
  declared before any is defined, then the body. The nesting of the `let` nodes is built
  afterwards, from the last group out, in a loop — no recursion per group.
- **A `let` pattern is a binding target too.** v1's `let` SCC gave edges only to `let_def`
  bindings, so `let c = a + 1` next to `( a, b ) = pair` had no edge to the pattern and could be
  generalised before `a` was constrained. v2's edges run to the binding that binds each local —
  a pattern binds all of its variables — through a local → binding table built once per `let`
  (v1's scan per reference was quadratic). An annotated `let_def` is still never a target.
- A `let` pattern's pattern is generated with its binding's **declaration**, so its variables exist
  before the group's other members are defined.
- `instantiate(var)` is emitted for every local and every `top` reference; the copy is the
  identity on a variable that is not generalised, so "generalised or not" need not be decided at
  generation.
- A top-level declaration's parameters are binders like a lambda's: a `binders_end` follows the
  declaration's body (§6.3).

### 6.3 Binders are registered

Every variable a binder introduces is appended to the current boundary's `binders` list: a lambda
parameter, a case-pattern variable, a `let` header and a `<-`-bound pattern. So is the top-level
header. §8.2 occurs-checks the list.

The generator also emits a **`binders_end` node** after a lambda's body constraints and after each
case branch's constraints. The node runs the occurs check over that lambda's parameters or that
branch's pattern variables at that point in the tree, before any enclosing constraint is solved.
This is Elm's placement, where each lambda and branch is a `CLet` header.

So `(\y -> y y) "s"` reports `infinite_type` at `y` before `"s"` is unified against the unrolled
arrow. `y` is then poisoned, and the application adds no second diagnostic. *Added 2026-09-24
(S4).*

### 6.4 Operator sections (CK-32)

`(==)` lowers to `lambda [%a, %b] -> method_call %a .eq [%b]` (BIR is unchanged). The "S3 shim"
(`Constrain.zig:910-914`) is deleted. A call of an operator section is an ordinary call of the
lambda, and the `method_call` inside it gets its callee wanted like any other. The evidence then
lives on the instruction `Lower` reads it from.

### 6.5 Records are constrained before they meet the expectation (CK-59)

A record literal's fields are constrained first. The literal's type is then unified with the
expected type, so a mismatch renders the literal's field types (`{ n : number, name : String }`)
and not fresh variables.

*Amended by R5 (2026-09-25): the solver chooses the order, per literal.* Constraining every
literal's fields first, as written above, also throws away the expected type a field is checked
against: `{ main = "not an Int", other = 1 }` against `Model` stopped being *"The `main` field of
this record is not what I expect"* at the field and became a mismatch of the whole record at the
literal (`check/bad/FieldNamedMain`, `SchemaRecursivePayloadMismatch`: two v1 goldens, and the
precise message was the better one). So the literal is one `record` node, and the solver decides
when it meets it:

- the **expectation first** (v1's order, each field checked against the type the context wants
  for it) when the expectation is still a variable, or a record whose whole row (`Walk.recordRow`)
  is closed and has exactly the literal's field names — the meeting then cannot fail on a name or
  on closedness;
- the **fields first** otherwise, so a missing or unexpected field, or an open record the literal
  cannot stand in for, shows the literal's own field types (CK-59).

It is a solving-order choice read off the expectation at that node, never a speculation (§7.5).
Three v1 goldens pin the old rendering and are listed in `tests/pending/v2-expected.md`
(`MissingField`, `UnknownField`, `RecordNotClosed`); CK-59's own fixture is red under v2 only for
its article, which is R13's.

*Refined by R5's review (2026-09-25).*
- **An unkinded variable** takes the literal expectation-first. A `number` or `appendable` one does
  not: it fails on the kind, so the fields go first (`Basics.add x { a = 1, b = "s" }` shows `{ a :
  number, b : String }`; structural review S1, `tests/corpus/check/bad/KindedExpectationShowsLiteral`).
- **A record open on a flex whose field names are all the literal's** also takes it expectation
  first, since the meeting cannot fail on a name. So a flagged field of a comparing function's
  parameter meets the literal's field before the lambda does, and the lambda is where
  `not_equatable` points, as in v1 (adversarial review F7).
- The row is read into `Walk.Stacks`' scratch list, not a fresh allocation per literal.

### 6.6 Annotations: one scheme, one checked instance

*Revised 2026-09-24. Round 1 (S16): the rank of P2's rigids had been unspecified. Round 2 (N8):
recursive uses must see the scheme, not the rigid instance.*

- **Every annotation has a scheme before anything uses it.**
  - A top-level annotation's scheme is built in P2 at rank `generalized`.
  - A `let` annotation's scheme is built the same way when the `let` group's frame is pushed, before
    any of its bodies is constrained.
  - No rigid of a scheme is ever unified.
- **Every reference to an annotated binding instantiates its scheme**, by value or by dispatch. That
  includes a reference from its own body, from its own binding group, and from a nested or merged
  frame. A reference to an annotated binding is therefore:
  - never an in-flight link (§10.3);
  - never a back-edge (§10.4);
  - never a demand for nesting (§10.2).

  So polymorphic recursion through an annotation works. v1 accepts
  `depth : List a -> Int` with a recursive `depth [ 1 ]`, and the same shape in a `let`, and so does
  v2 (round 2, N8).
- **Only the body check uses a rigid instantiation** of the scheme. It is made in the checking frame
  at that frame's rank, with its rigids pooled there and its `where` clause turned into givens. At
  the frame's boundary the rigids are quantified with the frame, and I1 checks them (§8.3).

This is not CK-01's "two readings". The defect there was that the checked copy was never validated.
Here the checked copy is an instance of the published scheme, and I1 validates it. A failure is an
error (`rigid_mismatch`), so a false annotation never compiles, even though dependents checked
earlier had already instantiated its scheme.

---

## 7. Unification

`check2/Unify.zig`, about 900 lines. It is today's `unifyFlat`, `unifyRecord`, `unifyAlias` and
kind lattice with the dispatch arms removed.

### 7.1 `unify` merges and queues. It never resolves and never reports

`unify(a, b) → Result` where `Result = ok | mismatch(Problem)`. The **caller** reports the problem
with its category (Elm's split). Inside `unify`:

- **flex ⊓ flex** merges kinds, `equatable` and `wants`. For a method name present on both sides it
  unifies the two `method_type`s, and on failure returns `mismatch(.method_constraint, younger
  origin)`. It then answers the younger wanted `alias(older)` (§4.2).
- **flex ⊓ structure, alias or rigid** binds the flex, and moves each of its wanteds and open
  obligations to the `ready` queue (a journalled write, §4.2). Nothing is resolved.
- **Every bind appends the bound variable to `touched`** (§8.1, N6). A merge also moves `obls`
  and runs §4.5's shared-rank lowering.
- **Attaching a wanted keeps I15.** Three things attach a wanted to a receiver: a `method` node on a
  flex, an instantiation creating one, and a merge moving `wants` onto the surviving root. Each then
  runs `lowerTo(w.method_type, rank(find(w.receiver)))`. This is an `owned` walk that lowers every
  variable it reaches to at most that rank, like `adjustRank` but downward only, stopping at nodes
  already at or below it.
  - In CK-02, `x.combine y` attaches to the outer `x`, so `y`'s type drops to `f`'s rank and `g` is
    not generalised over it.
  - A young receiver merged later with an outer variable is covered by the pool table: the young
    receiver's pool entry now reads the outer root's rank and `adjustRank` descends its `owned`
    successors.

  The cost is one walk of the method type per attachment. A method type is a function of two or
  three nodes. *Added 2026-09-24 (B2).*
- **flex ⊓ err** marks each wanted `failed` silently: poisoned, and never reported.
- **rigid ⊓ non-identical** is `mismatch(.rigid)`, as today.
- **rigid capture.** When a rigid is merged with a flex whose rank is lower than the rigid's, `unify`
  appends `Capture { rigid, region }` to the boundary's capture list. §8.3 reads it for the region of
  an escape.
  - *As built by R4b (2026-09-25), two changes.* (1) A capture is also recorded when a flex binds a
    **structure or alias of higher rank**: that is how a rigid **row** variable escapes (CK-01's
    `sk7`, `g y = o` with `g : { r | x : Int } -> …`) — `o`'s outer flex is bound to the young record
    holding `r`, and `r` itself is never merged with anything. (2) The list is **per module**, not
    per boundary, and a frame records its length when it is pushed: the rigid's frame need not be
    the current one (`g y = let k = x in k` captures inside `k`'s frame), and §8.3 reads only the
    captures since the annotation's frame was pushed. §8.3's region is the first of those whose
    node is the escaped rigid's root or reaches it by `Walk.structural` successors — one walk per
    capture, on the error path only.
- **records** use the four-way merge-join of today, producing a normalised record (§4.1).

*Amended by R15-fix-C (2026-09-28, CK-169, CK-172, CK-173, CK-174): an alias is a name, and
`unify` never closes a cycle through an alias's `actual`.* Every unification with an alias on
either side goes through one row (`Unify.throughAlias`), which first resolves each alias side to
the end of its chain:

- **Two sides whose chains end at one variable are one type**, and nothing is written. Before,
  `x ⊓ Id x` bound `x` to the alias whose expansion is `x` — a cycle through `actual`, which the
  binder's occurs check then called an INFINITE TYPE `a = Id a` (CK-172) — and two aliases of one
  name, one the other's argument, merged into a node whose `actual` reached itself.
- **A variable meets the expansion when the expansion is a variable.** `rigid ⊓ alias` answered
  "no" without looking through (`unwrapId : Id a -> a` was a rigid mismatch, CK-173), and a
  `number` flex tested its kind against an alias of the literal's own flex and failed
  (`wrap 1 == wrap 1` was a kind mismatch, CK-174). Only a **flex ⊓ alias of a structure or `err`**
  binds the flex to the alias by name, so a message still prints `Id Int` where the program wrote
  it.
- **Two aliases of one name** unify their arguments pairwise and merge, keeping the name, unless the
  arguments' unification has already joined them or their expansions; **otherwise the two
  expansions meet directly**, not one link per recursion, which spent §7.3's depth on a long chain.

With this row no write makes an alias reach itself through `actual` (every other writer of an
`alias` — the builder, instantiation, the interface readers — copies an acyclic one), and
`TypeStore.resolved` walks a chain with **no bound**: its 1 024-link guard answered `err` past it,
silently (CK-169, CK-170; §12.2 *amended by R15-fix-C*). A chain longer than the store has
variables would be this invariant broken, and panics. `resolved` **compresses** as `find` does:
each alias on the walked path gets `actual` = the chain's end, journalled like any content write,
so a chain is walked in full once. An alias's name and arguments, all `Render` prints, are
untouched.

### 7.2 Choice among failures is by text (I13, CK-07)

`unifyRecord` unifies every shared field and collects the failures. The one returned is the
smallest by field **name text**, not by symbol id. For the one-failure case, which is the common
one, the cost is zero.

### 7.3 Depth

`unify` recurses on structure. Its guard stays `Parse.max_depth + 104` (`checker.md` §5). The guard
is reachable two ways:

- through a cyclic graph, which §8.2 and §9.5 keep short-lived;
- through a **legitimately deep acyclic** type. A chain of `let`s can build an inferred type deeper
  than `Parse.max_depth`, as CK-13's 600-deep tuple does.

Past the guard, `unify` returns `mismatch(.too_deep)`, which the caller reports as
`nesting_too_deep`, the same code and cure as the other depth guards. It never returns "ok" (CK-10
item 3). *Wording corrected 2026-09-24 (N3).*

*As built by R4b's review (2026-09-25): `unify` is coinductive, and a cycle is never "too deep".*
The first bullet above was false once §8.2 checks binders only: a cycle made mid-group (a `case`
subject, `[ r, { a = r } ]`) lives until the boundary, and two isomorphic cycles unified there
(`[ r, s ]`, `( x x, y y, [ x, y ] )`) recursed to the guard — exponentially through a record
that keeps unifying after a failed field — and were reported as `nesting_too_deep` ("more than
4 200 levels … give the inner part a type alias"), or refused a valid program v1 accepts
(`List.map2 [ c ] [ c ] same` over a cyclic `c`). Three changes:

- **Coinduction.** `unify` keeps the pairs of non-variables it is unifying (`Unify.active`, a
  stack), and a pair met again on that stack is assumed equal. So a cyclic graph, or two isomorphic
  ones, unifies in time linear in its nodes, and on a finite graph nothing changes (no pair is its
  own descendant). **Link-first**, the OCaml/HM(X) textbook alternative the review offered, was
  not taken: it merges the two roots before their children, so a failing unification prints the
  same (merged) type as both "expected" and "found" — Elm's reason for children-first (v1's
  comment at `unifyFlat`) — and undoing the link on failure needs a journal around every
  structural unification. The pair stack buys link-first's termination with neither cost; its
  price is a scan of the stack per pair of non-variables, as deep as the unification.
- `unifyRecord` stops at the first shared field that fails with `too_deep`, and skips the rest.
- On `too_deep`, the caller runs the occurs check from both sides first; a cycle found is
  `infinite_type` at the unification (§8.2's reporting rule), and only a genuinely deep acyclic
  type is `nesting_too_deep`.

Fixtures: `tests/corpus/check/bad/InfiniteTypeCaseSubject*.beni`,
`…/InfiniteTypeTwoCyclesUnified.beni` and `tests/corpus/check/good/CyclicArgumentsUnify.beni`.

*Amended by R8c (2026-09-26): the pair stack's scan is bounded.* The scan per pair of
non-variables was R8a's profile's largest unify cost and quadratic in depth on a deep acyclic
unification (CK-93's note). Below 8 pairs on the stack nothing is scanned — a cycle is then met
again at most 8 levels further down, where the scan finds it; the first 64 pairs are scanned by
their current roots; deeper pairs are also kept in an array hash map keyed by their roots when
pushed, and popped in stack order (a plain hash map's tombstones made each probe longer on a deep
unification, CK-111's scenario). A deep pair whose root a merge below it has since changed is
missed and unrolled once more; merges only reduce the roots, so that happens boundedly often.
Two structures with no children (`Int`, `()`, `{}`) are merged without a pair on the stack: they
recurse into nothing, so they cannot meet a pair again (R8c's review round 2, −0.5 % of
instructions).

### 7.4 Kinds

The kind lattice is unchanged: `any ⊒ number`, `any ⊒ appendable`, `number ⊓ appendable = ⊥`.
Numeric literals through primitive aliases keep queue row 67's rule.

*Amended by R15-fix-A (2026-09-28, CK-139, CK-140): a written type that resolution refused is
`err` in the store, never a malformed node.* `Types.Builder` is the one place a written type
becomes store variables, and two refusals of resolution (`resolve/Resolve.zig`) used to reach it
as structure anyway. (1) **Arity.** An application whose argument count is not its type's arity
(`wrong_type_arity`, reported) is `err` (`Builder.apply`), so every `app` in the store has
exactly its declaration's parameters and derivation's context entries, which index them, cannot
read past the end — `type K = K Foo` over `type Foo a` crashed there. (2) **Recursive aliases.**
The builder carries the aliases being expanded around a read (`Builder.expanding`); an alias met
inside its own expansion is `err` (`recursive_alias`, reported; a cycle across modules is an
`import_cycle`). The depth bound alone did not stop `type alias A = ( A, A )`, which doubles per
level: 2^512 reads before the bound.

*Amended by R15-fix-C (2026-09-28, CK-171): an alias applied to the same arguments is expanded
once per read.* The aliases a written type names are a DAG even when the type is a tree —
`A{i} = ( A{i-1}, A{i-1} )` — and `Builder.aliasBody` expanded each USE, so `f : A18 -> A18` was
2^18 bodies (18 s in Debug). The builder of a read keeps `aliases`, `(alias, argument roots) →
the alias variable`, shared by the builders it makes for alias bodies (across modules too), and
an alias met again is that variable: a read costs its distinct pairs, and the store holds the DAG
instantiation's `copy` memo already makes. Sharing is sound — an alias's expansion is a function
of its arguments, and one type named twice is one type. An entry is made only when its expansion
is finished, so an alias inside its own expansion still reaches the `expanding` test above. The
memo is per read, never per store: two annotations get separate variables (their ranks and modes
differ, and a poison of one must not reach the other). `==` over the depth-64 DAG builds in
0.2 s (Debug). CK-144 (the same chain's interface terms, quadratic in bytes) is a different
place — the interface writer — and is not changed by this.

### 7.5 Speculation (I14, CK-35)

`TypeStore.Snapshot` is `{ journal_len, vars, extra, want_links, obl_links, wanteds, obligations,
answers, binders, captures, seq, frames: []FrameLengths }`.
- Every field except `journal_len` and `frames` is the length of a module-wide append-only table.
- `frames` holds, for **every open frame**, the lengths of that frame's own `ready` queue and
  `touched` list: `FrameLengths = { frame, ready_len, touched_len }`.
- `rollback` truncates all of them, then replays the journal backwards. That restores descriptors
  and the in-place wanted and obligation writes of §4.2 (I14).

*Revised 2026-09-24, round 4 (R4-1). The round-3 Snapshot still listed one `ready` queue and no
`touched`.* A probe's `unify` can bind a variable of **any** open frame. So it can append to any
open frame's `touched` list, and ready an item onto any open frame's queue. Every one of those lists
must therefore be restored.

**Why per-frame lists with all open frames' lengths**, rather than one tagged table per kind with a
cursor per frame:
- **Per-frame lists keep each frame's entries contiguous.** §8.1's occurs pass, S-3's linear bound
  and the hand-down on merge all walk one frame's list and nothing else. A tagged shared table would
  interleave nested frames' entries, and every walk would have to skip them. That is the O(n²) S-3
  removed.
- **The price is O(open frames) per snapshot.** That is paid only by the diagnostic probe, which
  runs only after a failure, and the open-frame count is bounded by the nesting budget (§10.2).

**Only one operation speculates:** the diagnostic "which of two did you mean" unifications, run
after a failure to choose a message.

`?` is **not** speculative in v2. §8.6 decides it from a concrete head, or by default, and then
unifies and reports. *Revised 2026-09-24 (S21): the first draft listed "`?` shape trials" here and
said the opposite in §8.6.*

A probe unifies and nothing else. It never calls `Resolve`, `Instances`, `Groups`, an obligation
decider or `Report` (I14), and it cannot create a dispatch-table row, because rows do not exist
until P6. That is what deletes `TargetProbe`, `forgetResolvedSince` and the other hand-journalled
tables.

---

## 8. Levels, generalisation and obligations

`check2/Generalize.zig`, about 450 lines. Elm's `generalize` and `adjustRank` with pools per rank
are ported as they are today, except that `adjustRankContent` descends by `Walk.owned` (I2).

### 8.1 Boundaries

A frame is pushed for every boundary: a `let` group, or a top-level group. §10 adds nested top-level
groups. At the boundary of frame `F`, with young rank `r` (I16):

1. **Settle.** Drain the frame's `ready` queue until it is empty (§9.1). A `let` frame drains its enclosing top-level frame's queue. Resolution may check a group nested
   at demand (§10.2), and may decide obligations whose variable became concrete (§8.5, §8.6).
   **No defaults are applied here.**
2. **Adjust ranks without quantifying.** Run Elm's `poolToRankTable` + `adjustRank` over `F`'s
   young pool, by `Walk.owned` successors. After this pass, a variable's rank says whether it
   escapes `F`. Every later step reads adjusted ranks only.
3. **Defaults.** Skip this step if `F` is a top-level frame merged into another (§10.4, N4).
   - Collect, in obligation-id order, the undecided `try` obligations attached to variables of `F`'s
     pool whose variables **all still have rank `r`**.
   - Apply every one of them, which defaults it to `Result` (§8.6).
   - If any was applied, or anything was readied since step 1, go back to step 1.

   Applying all at once is equivalent to applying them one at a time: a default only makes
   `Result`s, so it can only turn another undecided `?` into a `Result` decision.
4. **Occurs** over `F`'s `binders`, and over `F`'s `touched` list (§8.2, N6; per frame since round 3), by
   `Walk.structural`. *(As built by R4b: over the binders only — §18's fallback, §8.2's
   As built.)*
5. **Quantify** the rank-`r` variables of the pool (§8.4).
6. **Generality check** for the annotated bindings of `F` (§8.3).
7. **Close.** For each variable just quantified:
   - its open wanteds are promoted, or proven undetermined and defaulted (§9.4);
   - its open obligations are reported or folded (§8.5).

   Wanteds and obligations on escaped variables stay attached to them (I3).
8. Pop `F`.

**A merged top-level frame** (§10.4) runs steps 1 and 2 at its own end. It then hands its pool,
`binders` and `touched` segment to the merge root's frame, and pops. It runs no default, no occurs
check and no quantification: those happen once, at the root.

**`touched`** (N6) records the variables `unify` binds. The undo journal cannot serve here, because
it records nothing outside speculation. It is **one list per frame** (round 3, S-3): `unify` appends
to the current frame's list, and a merged frame hands its list down with its pool.

A nested frame's entries are therefore never in its demander's list. Those variables were already
generalised or handed down, so a chain of *n* nested groups costs O(n) occurs work, not O(n²).
Each list is an append-only table, truncated on rollback (§7.5).

**Termination.** Every return from step 3 to step 1 follows one of two things:
- a default applied, of which there are finitely many;
- a wanted or obligation readied, each of which happens at most once.

Step 7 can unify: a structural default resolves against a shape. It runs only on variables step 5
quantified, which no open constraint can reach any more, so it can neither ready an outer wanted nor
form a cycle through a structure that step 4 cleared. A debug-only occurs re-run over what step 7
touched asserts this.

*Revised 2026-09-24.*
- *Round 1, B3:* occurs had run before the unifying steps.
- *Round 2, N2:* defaults had read stale ranks.
- *Round 2, N4:* a merged frame had defaulted before the root's facts arrived.
- *Round 2, N6:* the "journal segment" does not exist.

*As built by R5, after its review (2026-09-25): steps 1, 3 and 7 have work.* `Solve.boundary`,
with the deciders in `Decide.zig`.
- **Step 1** drains the top-level frame's queue in `seq` order. `Solve` owns that queue and `Unify`
  holds one pointer to it; every `let` frame routes there (§9.1). The same drain runs after every
  constraint node (§9.1's eager draining), except that a readied `equatable` row is set aside
  until the next boundary's step 1. Its walk decides nothing another row reads: it only flags
  variables, and a flag matters to nothing before quantification. So the walk runs over the type
  as it then stands, and the message shows the solved type (`number -> number`, not `a -> b`).
- **Step 3** (`Decide.defaults`) reads **the current frame's own open-`?` list**. A row joins the
  list of the frame at its target's rank when it is attached (§4.5 *As built by R5, after its
  review*).
  - For each open row, the dependants are lowered to the target's rank again (rank adjustment
    folds a variable's rank from its own position).
  - A row whose target still sits at the frame's young rank is due. A row whose target escaped
    moves to the list of the frame at the target's rank.
  - Every due row is decided as `Result`, oldest first. The loop goes back to step 1 when one was,
    or when anything was readied.
  - So a row is looked at once per frame it passes through (CK-98), not at every boundary of its
    group.
- **Step 7** (`Decide.close`) reads the quantified variables that still carry a set. `quantify`
  collects them in the same pass.
  - The `tuple_index` rows go first: `ambiguous_tuple`, with the result poisoned.
  - Then an `interpolatable` row is `ambiguous_interpolation` unless the variable is a `number`,
    or is the result a tuple's message just poisoned (I12: no cascade; adversarial review F6).
  - An `equatable` row is the flag the variable already carries into its scheme.
  - A `try` row cannot be there (step 3 defaulted it at its target's boundary) and would be
    `internal`.
- **Poison settles.** `Solve.poison` on a flex that carries rows closes each of them as a decision
  on `err` would: its results poisoned, without a trip through the queue. So nothing is readied
  during steps 4 and 6, and the top-level frame asserts an empty queue when it is popped (review
  S7).
- **Merged frames** do not exist before R7; the "skip step 3 when merged" rule arrives with them.
- **N9 (for R6a).** "Applying every default at once is equivalent to one at a time" holds for R5's
  kinds, because no default readies a row that binds another `?` to `Maybe`. R6a's wanteds break
  that premise: R6a drains between defaults, or argues the claim again.

*As built by R6a (2026-09-25): wanteds at the boundary.*
- **Steps 1 and the eager drain** take wanteds from the same `Solve.ready` queue as obligations
  (a wanted id is tagged with `Evidence.queued_wanted`), in one `seq` order (§9.1).
- **Step 3 (N9).** A default can ready a wanted whose resolution decides another `?`, so
  `Decide.defaults` drains after each default it applies rather than arguing the all-at-once
  equivalence again.
- **Step 4** also occurs-checks, with the same epochs, the method type of every wanted and every
  variable of every open obligation riding on a root of the frame's pool (R4b's review, S4): a
  cycle is `infinite_type` at the wanted's origin (the obligation's region), drawn and poisoned.
  An open wanted's receiver is the pool root it rides on, a flex, which no cycle passes through;
  a receiver that was bound was readied, and the resolver's walk met it (§9.5).
- **Step 5, at a `let` frame: rule (a)** (§8.4's `let_constrained_monomorphic` switch, until
  R14). A young root that carries a wanted is lowered, with its method types (`Walk.lowerTo`,
  `owned`), to the enclosing rank before quantification, so the enclosing frame receives it, and
  the binding is recorded for `type_mismatch`'s hint (`Env.monomorphic`). Lowering the method types
  too is what keeps the binding's result tied to the receiver: v1 held back only the receiver.
  So every promotion is a top-level declaration's. *Superseded by R14 (2026-09-27):* the switch is
  deleted, and step 5 at a `let` frame holds only what §8.4 *As built by R14* holds.
- **Step 7, at a top-level frame** (`Resolve.close`): promotion, the cap, `constrained_constant`,
  `ambiguous_method_receiver`, then the proven-undetermined default (§9.4 *As built by R6a*).
  Quantify collects the quantified flexes that carry wanteds (`Resolve.State.wanters`) as it collects
  obligation carriers.
- **Step 7's assert, restated** over the receivers it defaults: in R6a a default answers
  `undetermined` and a promotion answers `promoted` without unifying anything, so the assert is
  that step 7 made no unification at all (`Unify.unifications` unchanged), which is stronger than
  a re-run of the occurs check over what it touched. A structural default that unifies (R8a's
  shapes) must restate it again. *Revised by R6a's review (S8):* it is `Solve.expect`, so a
  release build reports `internal` too, as an assert must (§15).

*As built by R7 (2026-09-26): frames nested and merged* (§10.8). Step 1 drains the frame's own
queue (a `let` frame's is its top-level-kind frame's); a merged top-level-kind frame runs steps 1
and 2 and hands down (`Groups.handDown`), and its root's boundary runs step 4 over the handed-down
binders too. Step 2's counting sort by rank is replaced by a sort when the frame's rank is far
above its pool's size, which a frame nested at demand is (a chain of n nested groups was O(n²)).

### 8.2 Occurs at every binder (CK-04, CK-03)

The occurs check runs in two places:
- at each `binders_end` node, over that lambda's or branch's binders (§6.3);
- at step 4 of every boundary, over the boundary's `binders` and the frame's `touched` segment (§8.1).

Each is one walk. The walk is three-colour over **`Walk.structural`** successors (I2, B1), with the
two epochs of §4.1 and a growable stack. A variable whose only self-reference is through its own
requirement (`x.eq : x, x -> Bool`) is not a cycle.

A cycle is `infinite_type` at the binder, or at the first unified variable on the cycle for one
made in the settle loop. The walk returns the cycle's path, and `Render` prints the structure with
the repeated variable (CK-57): `a = { a | x : a }`, not `a = … a …`. The variable is then poisoned
(`err`). Elm pays the same cost for the same guarantee. §18 has the measurement obligation,
including the nested-`let` case.

**Why both defences.** Resolution during solving, through U0 inline resolution on a concrete
receiver or in the settle loop, can still meet a graph made cyclic since the last check. So §9.5
also makes every resolver walk cycle-safe. Neither defence alone is enough, and both are cheap.

*As built by R4b (2026-09-25): §18's fallback, Elm's placement.* §18's measurement (its *As built*
paragraph) put the walk over the `touched` segment at about 4 % of the check phase on a
dispatch-free 131 000-line corpus, over §18's 3 % line, so R4b took §18's stated fallback: **the
boundary occurs-checks its binders only**, and the frames keep no `touched` list (§8.1 step 4,
N6 and §7.5's `touched_len` are retired for R4b; R7 re-opens the question if a merge needs them).
- `binders_end` follows a **lambda's** body and a **`case` branch's** body — the placement S4 needs
  (`(\y -> y y) "s"` is `infinite_type` at `y`, before `"s"` meets it).
- A declaration's and a `let` definition's parameters are checked at their group's boundary, which
  follows their body directly; a `binders_end` of their own walked the same types twice.
- At the boundary, parameters and pattern variables are checked before headers, so a cycle a
  parameter carries is named by the parameter (`f r = { r | x = r }` is `infinite_type` at `r`,
  7:3, not at `f`'s body).
- A walk never pushes a node with no `structural` successor (a variable, `Int`, `()`, `{}`):
  none can be on a cycle.
- **What is given up** is detection of a cycle no binder's type reaches — a type an expression
  builds and discards, such as a lambda argument bound to `_`. Nothing reads such a type in R4b:
  publication reaches only headers' types, and every walk that could meet the type (the writer,
  `adjustRank`, `copy`, `Render`) is colour- or depth-safe and reports. Elm gives up the same.
  §9.5's resolver walks (R6a) are cycle-safe in their own right.

*Corrected by R4b's review (2026-09-25).* Three things the paragraph above left out or got wrong:

- **Also given up: EARLY detection.** A cycle made mid-group lives until the boundary even when
  a binder reaches it. The walk that meets it first is then `unify`, which the list above omitted;
  §7.3 *As built by R4b's review* makes `unify` coinductive, and a `too_deep` from it looks for a
  cycle before it reports, so it terminates and says `infinite_type`.
- **"Why both defences"** above assumed the `touched` walk. Under binders only, the defences are:
  the binder checks, a cycle-safe `unify` (§7.3) and, from R6a, the cycle-safe resolver walks
  (§9.5). §8.1 step 7's "debug-only occurs re-run over what step 7 touched" and §7.5's
  `touched_len` have nothing to read in R4b and are retired with the list; R6a re-states step 7's
  assert over the receivers it defaults.
- **Owed by R6a** (`plans/checker-rewrite.md` R6a's brief): step 4 also occurs-checks the receiver
  of every wanted riding on `F`'s pool and, from R5, every variable of every obligation. That is the
  CK-03 / row 76 coverage `touched` was for, at no cost in dispatch-free code.
  Discharged by R6a (2026-09-25): see §8.1, *As built by R6a*, step 4.

**How a cycle is reported** (the review's F3, F4 and S5). From a binder, or from a `too_deep`:

- the cycle drawn is the first a search meets **with record fields in name-text order**
  (`Walk.firstCycle`), so which of two cycles is named cannot depend on symbol ids (I13);
- a cycle whose drawing would show a poisoned node (`?`) is a consequence of a message already
  given, and is poisoned without one;
- then **every** cycle reachable from the binder is poisoned, so no use of it meets another and
  reports again.

An `infinite_type` sets its declaration's failure bit but does not gate exhaustiveness (§15.2 *As
built by R4b's review*).

*Amended by R8c (2026-09-26, CK-93, CK-111; restated by R8c's two review rounds): proofs that
outlive a walk.* A `let` chain whose types grow (`x1 = [ x0 ] … xN = [ xN-1 ]`) occurs-checked the
whole chain at every link: O(N²). And `==` on a record nested *d* deep ran the §9.5 cycle test on
each of its *d* nested positions, each over its subtree: O(*d*²). Both now keep a proof past its
walk, and a proof never changes a verdict.

- **What is proved** (`TypeStore.acyclic`, beside the content it is about). A proving run — step
  4's at a boundary, and §9.5's cycle test (`Instances.cyclic`) — records, with the current epoch,
  the root it proves and every leaf (flex, rigid, `err`) it meets; §9.5's run also records every
  node it blackens (`Occurs.interior`). A later walk, of any run, stops at a proved node. So a later
  link of the chain stops at the link below, and a position of a receiver just tested is proved
  already and costs one lookup.
- **The invariant (Inv).** *A proved node's graph is acyclic, and every node without successors in
  that graph is proved.* The second half is what lets a rule about leaves catch every new edge.
- **What voids the proofs** (`voidProofs`: the epoch moves and every proof is void). The store sees
  every content write — `setContent` and `merge` — and voids them on either of two writes:
  - **a proved node without successors given some** (`gains`): a bind of a proved flex, a proved
    `err` given structure; and, conservatively, a proved structure overwritten with another kind;
  - **the `err` rule** (`touchesErr`): any write where one side is `err` — before or after — and
    any side has successors. That covers a node with successors turned `err` (a merge whose
    survivor is `err`, a poison), which leaves a leaf nobody recorded inside any proved graph that
    held the node and lets a record merge carry extra fields absorbed into an `err` row end on
    unwalked; and an `err` given structure, proved or not. It happens only on a program with an
    error. *Why the broad form* (the manager, 2026-09-26): Inv alone would allow the narrower "a
    node with successors turned `err`", since an unrecorded `err` given structure lies in no proved
    graph; but two holes in this section came from arguments that a narrower condition sufficed,
    and the broad rule is the one R8c's second review verified. It costs a content read per merge,
    about 0.8 % of instructions on the dispatch corpus (§18).

  Binding a fresh, unproved variable — each link of the chain does — keeps them. A merge carries a
  proof either side had to the survivor unless it voided them. Out of memory voids them, and so
  does a rollback (v2 never speculates, §7.5).
- **Why Inv holds** (the second review round's argument). A proved leaf gaining successors voids.
  A `func`, `app` or `tuple` merge unifies every child pair first, so the survivor's children are
  the proved side's child classes whichever side's content it keeps (a coinductive skip needs a
  pair that recurs, which in an acyclic proved graph needs an earlier merge that made it cyclic,
  which voided). A same-type alias merge keeps `b`'s expansion over `b`'s arguments, whose classes
  are `a`'s. A record merge's fresh extension and extra-field records reach the proved side only
  through a bind of its row end, which voids — except when that row end is `err`, which absorbs
  them: the `err` rule. A structure turned `err` adds no edge but makes an unrecorded leaf: the
  `err` rule again, which also voids on any `err` given structure. No other write adds an edge: flag-only rewrites of a flex, fresh copies,
  and `Messages`' temporary flex (whose restore voids conservatively).
- **How it got here.** R8c first kept the stamps beside the walks, voided them only in
  `Unify.bind` (a flex given structure) and stamped only flexes, and claimed "only a bind adds an
  edge": false. Its first review found an `err` class given structure by `Unify.flat` (which merges
  with content read before the children were unified) — one INFINITE TYPE of two lost, and with
  CK-126's `err` an infinite type accepted — and a position's proof "inherited" across a Rule U1
  join and a user instance's unification that closed `x = List x`. The first fix moved the proofs
  into the store and voided on a proved leaf gaining successors, and claimed "an edge is added in
  exactly one way" and "`merge` only redirects a class to a survivor whose children were unified
  with the other side's first": both false through `err`. The second review found a record merge
  past a proved `err` row end (an infinite type accepted again) and an unproved interior node
  turned `err` and then given structure (a cyclic scheme); the `err` rule closes both, since both
  begin with a node with successors turned `err`.
  `blackbox_test.zig` holds all five programs ("R8c review …"). `Unify.flat` keeps writing the
  structure, as v1 and `5f18e23` do: the write is seen, not forbidden, so no golden moved.
- **Checked in Debug** wherever a walk stops at a proved node (`Walk.assertProved`): a walk of its
  own that trusts no proof and touches no mark, over at most 1 024 nodes, panics if the node
  reaches a cycle. With the `err` rule switched off it panics on both second-round programs.
  `Resolve.step` also re-walks every proved receiver fewer than 64 positions deep.
- The derivability walk's verdict over a graph with variables below (`Resolve.State.derivable_open`,
  CK-111) is kept while no proof has been voided (`TypeStore.proof_voids`, a count that does not
  wrap as the epoch does): the walk records every leaf it meets, so any leaf given successors, an
  `err` included, drops the memo.

### 8.3 Annotation generality (I1, CK-01)

For each binding of the boundary that has an annotation, and for each rigid of its checked instance
(§6.6), after step 5 all three of these must hold:

- the rigid's root is still `rigid` with its own name;
- no other rigid of the same annotation shares that root. Rigid-rigid merges are already
  `rigid_mismatch` inside `unify`, and this is the assert;
- its rank is `generalized`.

A rigid that fails the third is an **escape**: the annotation says "any type" and the body tied the
variable to an enclosing one. It is reported as `rigid_mismatch` (D7) at the first `Capture` region
recorded for that rigid (§7.1), or at the annotation when none was recorded, because the rank was
lowered by `adjustRank`. The message names the outer binding and says the annotation is too
general. The binding's scheme is then poisoned, so callers are not checked against a false
annotation.

**Top-level declarations.** The check runs there too, because their rigid instance lives in the
frame's pool (§6.6). A top-level rigid has no enclosing binder to escape into except a suspended
frame's live variables through a dispatch back-edge, and §10.4 merges those frames first. So a
failure there is `internal`, never a user error. *Revised 2026-09-24 (S16).*

### 8.4 Generalisation, and constrained `let` bindings (D5)

Rule (a) of `static-dispatch-spike.md` §6.4 is **retired** (D5). Generalisation is plain HM(X) on
levels.

- **Step 5 quantifies exactly the variables whose rank after step 2 is `r`**, whether or not they
  carry wanteds. `adjustRank` computes a structure's rank as the maximum of its children, as in
  Elm.
- **A wanted on an outer-rank receiver** keeps its method type's variables at the outer rank (I15),
  so none of them is quantified. That is the answer to CK-02's `g y = x.combine y`: `y`'s type sits
  in the method type of a wanted on the outer `x`, so `g` is monomorphic in `y`.
- **A wanted on a young receiver** whose method type mentions an outer variable is still
  quantified, with the outer variable **free** in the promoted requirement. That is sound HM(X):
  `g y = y.combine x` gives `g : ∀b. b -> r where b.combine : b, X -> r`, with `X` being `x`'s outer
  type, shared by every instantiation. I15 does not apply once the receiver is generalised
  (S-new-4).
- **The `let` binding's open wanteds on its own quantified variables are promoted** to the binding
  (`Binder.let_def`, §9.4). Uses instantiate them as they would a top-level scheme's (I5).

*Restated 2026-09-24 (round 2, S-new-4). "Provided everything reachable through `owned` is young"
was not what `adjustRank` computes.*

Slices R4–R13 ship with a **`let_constrained_monomorphic` switch** that keeps rule (a)'s behaviour,
so the pre-cut-over corpus compares like with like. R14 deletes the switch (`checker-rewrite.md`).

*As built by R14 (2026-09-27), written before its code.* The switch is deleted
(`Solve.holdConstrained` with it). Step 5 at a `let` frame (`Resolve.holdLet`, then `quantify`,
then `Resolve.closeLet` in step 7):

- **What a `let` generalises over.** A young root that carries an open wanted is quantified by the
  `let` when all three hold, and otherwise it is **held** — lowered with its method types to the
  enclosing rank (`Walk.lowerTo`, `owned`, I15), exactly as rule (a) held every such root — so the
  enclosing frame receives it and its wanteds keep riding on it:
  1. it is reachable, by `Schemes.quantifierOrder`'s walk (the walk §12.1's canonical order reads),
     from the header of an unannotated **function** binding of the frame: a `let_def` with
     parameters, or whose right-hand side is a `lambda`;
  2. it is reachable from no other header of the frame — a `let` **value** binding (no parameters,
     not a `lambda`) or a `let` pattern;
  3. not every open wanted on it is a dot-call's own (`Wanted.field_ok`: a `method_call`'s callee,
     not joined with a scheme's requirement). That is §21.1's D5 row of 2026-09-26, decided by the
     owner: `let call s = s.f 10 in call { f = … }` keeps its field call, and so does
     `check/bad/LetConstrainedTwice`'s `show x = x.render 1`, which stays a `type_mismatch` at its
     second use.

  Rule 1's first half keeps §9.4's proven-undetermined default at the top level for a requirement
  no binder's type reaches (`let e = [] == []`). Rule 2 is the **value restriction** (Haskell's
  monomorphism restriction): a value binding has nowhere to take evidence except by becoming a
  function of it, which would run its right-hand side at each read and break `language.md` §6
  *Evaluation order*'s "`let` bindings: in the order written", evaluated once where written — so it
  stays monomorphic, and `static-dispatch-spike.md` §6.2's `let t = decodeInto "zz" in label t`
  is still pinned by its later use. A pattern binding is held for the same reason. Rule 3 and the
  value restriction are the two places a `let` is not HM(X), with the cap below; `type_mismatch`'s A.30 hint names
  which one held the binding (`Env.monomorphic` gains the reason). *R14's review (B1):* a header
  is a header wherever its `let` stands — inside a lambda or a `case`/`if` branch the generator
  marks its binder `.ended` once its occurs check is placed, and `Generalize.Binder.header` keeps
  the fact (`run/LetHelperBelowLambdaOrBranch`).
- **The cap** (`holdLet`, R14's review B2). A function binding whose own requirements, counted
  as `closeLet` would list them, number more than `max_inferred_constraints` (64, spike §10.11)
  is **held whole**, as every constrained `let` was before D5, with no diagnostic: at the top
  level an annotation lifts the cap, and a `let` annotation cannot carry a `where` clause, so a
  refusal would have no escape hatch (rule 7). A second use at another type gets A.30's hint
  with the cap's reason (`run/LetHelperOverTheCap`, `check/bad/LetHelperOverTheCapTwice`).
- **Promotion** (`Resolve.closeLet`, step 7). For each unannotated function binding, its
  requirement list is `Evidence.requirements` of its generalised header, restricted to the roots
  this `let` quantified (a requirement on an outer root is not the binding's own: I15, CK-02). The
  open wanteds on those roots are answered `promoted { root, method }`, as at the top level; their
  index is computed by P6 per site (§12.3, case 2). A quantified root carrying an open wanted that no
  binding's list holds cannot arise by rule 1, because `holdLet` decides "reached" by the same
  `Schemes.quantifierOrder` walk `Evidence.requirements` lists by; in a module that has reported
  no error it is `internal` (`Solve.expect`), and otherwise it is not asked (review S2).
- **The record.** Each promoting binding is one `LetInfo { inst = its let_def, requirements }`
  (§13.1), its rows appended to `requirements` after every declaration's, sorted by `inst`; its
  quantifier roots are kept beside them for P6 as a declaration's are.
- **Uses.** A use outside the binding's group instantiates its scheme like a top-level one
  (`Instantiate.copy`, I5): an `inst_evidence` row at the `local`, moved by P6 onto the `call`
  that applies it. A use inside the group (a recursive `let`) instantiates nothing and is a group
  call, P6's §12.3 cases with the callee's final list.

### 8.5 Obligations at a boundary (I3, CK-05)

Obligations ride on their variables (§4.5). By kind:

| Kind | A variable became concrete: decided when drained (§8.1 step 1) | Still open on a variable step 5 quantified: step 7 | On an escaped variable |
|---|---|---|---|
| `tuple_index` | check the arity (unifies the result) | `ambiguous_tuple` | stays attached |
| `interpolatable` | check membership | `ambiguous_interpolation` | stays attached |
| `equatable` | the §11.4 walk | fold the flag into the variable | stays attached |
| `try` | §8.6 | never reached: §8.1 step 3 defaults first | stays attached |

At the **module's last boundary**, the top-level group, nothing escapes.

### 8.6 `?` as a deferred obligation (D2, CK-06, CK-51)

`try(e, target_result, region)` is an obligation on both of its variables. `target_result` is the
result variable of the `?`'s **target**: the declaration or the `let_def` named by the instruction
(`checker.md` §6.5). Its two variables share one rank (§4.5). It is decided at the first of these:

- **(a)** When drained, because either variable got a `Result` or `Maybe` head. This can happen in
  any frame's settle step.
- **(b)** Otherwise, **by default to `Result`**, in step 3 of the boundary of the frame at whose
  rank its variables still sit after that frame's rank adjustment. That is the frame that owns them,
  normally the target's own generalisation boundary.
  - An obligation whose variables escaped, as in round 2's N2 program, is defaulted, or decided by a
    later fact, further out.

  In N2's program, `f h = let g u = h (u?) in ( g (Just 1), Maybe.withDefault (h 5) 0 )`, the
  target result escapes `g` to `f` through `h`. It is decided as `Maybe` when `f`'s body meets
  `Maybe.withDefault`, and the program checks.

*Clarified 2026-09-24 (round 1, S3): the target may be a `let_def`, and deciding its `?` after that
`let` generalised would unify generalised variables. Revised (round 2, N2): ownership is read on
adjusted ranks.*

Deciding is today's three unifications (`checker.md` §6.5): `e ~ Shape x a`,
`target_result ~ Shape x b`, and the instruction ~ `a`. They are **not speculative** (§7.5): the
shape is chosen first, from a concrete head or by default, and then the three are unified and a
failure is reported.

A failure reports **which** leg failed, through the categories `.try_leg(subject | enclosing |
error)`, and the message names it:
- "the enclosing definition returns `Result String Int`, and this is a `Maybe Int`";
- "the error types differ: `Int` here, `String` in the enclosing result".

When both sides are concrete and disagree in head, the subject's head chooses the shape, and the
enclosing leg then fails with the message above.

*As built by R5, after its review (2026-09-25).* `Decide.tryShape`.
- **The target.** The generator keeps two things:
  - the result variable of the declaration it is in, when that declaration has parameters;
  - a stack of the `let` definitions with parameters it is inside.

  The `try` node names the one the instruction's `rhs` does (`Generator.targetResult`), resolved
  at generation (I11).
- **The owner is the target** (§4.5 *Amended by R5's review*, D2 as amended in §21.1). The subject
  and the value are lowered to the target's rank, never the reverse. The row joins the open-`?`
  list of the frame at the target's rank, whose step 3 defaults it.
- **Deciding.**
  - The shape is the subject's head when that is `Result` or `Maybe`.
  - A subject that is any other non-variable is the `neither` leg.
  - With a variable subject, the target's head decides. A target that is any other non-variable is
    the `neither` leg too: nothing says the subject is a `Maybe` or a `Result`, so the `enclosing`
    text, which names the subject's shape, would be false there (adversarial review F5).
  - With both variables the row is attached, unless §8.1 step 3 is deciding it, which says
    `Result`.
- **The three unifications** are then made, each reported by its leg with `checker.md` §8.6's
  texts:
  - the subject's (`neither`);
  - the target's (`errors` when the target has the shape's head, so only the error type can have
    failed; `enclosing` otherwise);
  - the value's, an ordinary mismatch.

  A failed leg poisons the subject and the value, as v1's did.
- **The dispatch table's `tries` row** (`checker.md` §6.5) is written when the subject and target
  legs succeed. P9 sorts the rows by instruction.
- **Fixtures.**
  - `tests/corpus/run/TryEscapesToLaterFact.beni` is N2's program (claimed, CK-62): `g u = k
    (u?)` escapes to `f` through `k`, is not defaulted at `g`'s boundary, and is decided `Maybe`
    by `Maybe.withDefault (k 5) 0`.
  - `tests/corpus/run/TryDefaultAtLetBoundary.beni`: `unwrap u = u?` defaults at `unwrap`'s own
    boundary and is used at two error types.
  - `tests/corpus/run/TryTargetKeepsItsSuccessType.beni` (CK-99): an outer subject and a young
    target; the target keeps its own success type.

---

## 9. The resolver

`check2/Resolve.zig` (about 1 100 lines) and `check2/Instances.zig` (about 700). The resolver owns
every wanted from the moment it is `ready` until it is answered.

### 9.1 When resolution runs

- **Inline, Rule U0.** Solving a `method` node whose receiver is already concrete calls
  `Resolve.now(wanted)` before the argument constraints are solved. This is the same function the
  drain uses, and it keeps the message quality of `static-dispatch-spike.md` §6.2.
- **At every boundary**, in step 1's settle loop (§8.1), the resolver drains the frame's queue until
  it is empty.
- **Drain order** (round 4, S4-4). Wanteds and obligations share **one creation sequence number**,
  `seq`, stamped on both tables from one module counter at creation. A queue is drained in ascending
  `seq`, which is creation order and a function of the source (I9).
- **One `ready` queue per top-level frame, and one per fixpoint frame** (round 3, B-1).
  - **Routing is by the frame id recorded when the item is created** (round 4, R4-1), not by
    `origin_decl`.
    - Every wanted and obligation row carries `frame: FrameId`: the frame that was current when it
      was created.
    - A sub-wanted, and an evidence wanted created by an instantiation, takes the frame current at
      its creation.
    - A `let` frame routes to its enclosing top-level-kind frame.
    - A readied item goes on **its own frame's** queue, whichever frame's unification readied it.
  - `origin_decl` could not serve for routing, for two reasons. Two fresh fixpoints (§11.2) share
    `origin_decl = derived(T, m)`, and obligation rows have no `origin_decl`.
  - **Merges.** A merged frame that is still running keeps draining its **own** queue until it hands
    down (§10.4). At hand-down, whatever is left in its queue is appended to the root frame's queue,
    in `seq` order, and its items' `frame` fields are re-pointed to the root.
  - A frame drains **only its own** queue, so a nested group's settle step can never resolve (and so
    nest from) a wanted of the frame below it.
  - The frame stack therefore stays a true **demand chain**: every nested frame was demanded by the
    frame directly beneath it.
- **Eager draining** (round 3, B-1). The solver drains the current frame's queue **after every
  constraint node**, outside `unify`, so I14 is untouched.
  - A wanted is resolved as soon as its receiver is bound, at the same solving step at which a group
    checked first would have given its answer. That is v1's "resolve when the receiver is bound".
  - Round 3's `rq1` and `rq2`, a `case` scrutinee whose method is written after its use, and before
    it, both check.
  - The boundary settle step (§8.1 step 1) is then only the last drain.
- *S-new-5's round-2 text ("one queue per module; answers never depend on which frame drains") was
  wrong once draining can nest groups.*
- *As built by R7 (2026-09-26):* as specified; the routing field is the queue's index, the
  current queue's list is held in `Solve.ready`, and a release build reuses a popped queue (never
  a Debug build) (§10.8).

### 9.2 One step, by the receiver's root

`Resolve.step(w)` looks at `find(w.receiver)`:

| Root | Action |
|---|---|
| `flex` of kind `number`, method `eq` or `compare` | **the `number` bridge** (D9): unify `w.method_type` with `t, t -> Bool\|Order` (category `.where_clause` when the wanted came from a clause), then answer `primitive strict_eq\|num_compare`. This runs when the wanted is first drained, with no waiting, as v1 does. Every `number` is `Int` or `Float`, and both answer the same primitive |
| any other `flex` | leave `open` (re-queued when bound, §7.1). At the boundary that quantifies it, §9.4 |
| `rigid` | 1. a given `(rigid, w.method)`: unify the method types (category `.where_clause`, CK-55), answer `param(binder, k)`; 2. else, a rigid of kind `number` with `eq`/`compare`: the `number` bridge, as for a flex; 3. else `missing_where_constraint` at **`w.origin`** (CK-48), and the wanted is `failed` |
| `err` | `failed`, silently |
| `app T args` / `alias` / record / tuple / unit / `func` | `Instances.lookup(w)` (§9.3) |

*Revised 2026-09-24 (B4, S5).* The first draft put the bridge inside `lookup`, which §9.2 reaches
only for concrete roots, and had no bridge for rigids. `core/Basics.beni:319`'s
`abs : number -> number` with `n < 0`, `max`/`min`, and `tests/corpus/run/DecodeInto.beni:86`'s
`number.eq x y` would have been `missing_where_constraint`, so `core` could not check under v2. v1
has the rigid bridge at `Solve.zig:2750-2753`. D9 is amended accordingly (§21).

*Amended by R15-fix-A (2026-09-28, CK-141).* The `err` row answers **`poisoned`**, not
`failed`: the poison's message may be a dependency's, so the state must not claim this module
reported anything (§12.2 *amended by R15-fix-A*).

### 9.3 Instance lookup: matching a head, with the context as sub-wanteds

`Instances.lookup(w)` returns `answer(term, sub-wanteds)`, `blocked(on)` or `fail(reason)`. It never
returns "unknown, accept" (I8).

1. **Well-known table** (`static-dispatch-spike.md` §3.2), for `eq` and `compare` on a core
   primitive: `primitive p`. First, `w.method_type` is unified with the well-known signature
   `t, t -> Bool|Order` (CK-21).
   *Amended by R9b (CK-131).* A method type that already IS that signature — both parameters
   the receiver's root itself, the result the well-known type (`Resolve.hasWellKnownType`) — is
   not unified again: the unification could only succeed, and would report nothing. This is a
   test of the type's shape, never a unification used as a test (§9.5). `Resolve.step` answers
   such a wanted on a `primitive` row before the cycle test and the sharing memo, neither of
   which can apply to a nullary application (a table primitive is never remembered). The table's
   rows are stated once, `Contexts.tableRow` (R9's review, nit 1).
   *Memos keyed by a variable id (R9b).* `Resolve.State.derivable` (a dense column) and
   `Derivable.Shapes.last` (the last ground encoding) key on a variable's id, which is sound
   only while no id is reused for another type — true because v2 never speculates and so never
   rolls the store back (§7.5). The store counts its rollbacks (`TypeStore.rollbacks`); each memo
   records the count when it is first written, and a read or write after it moved is a panic in a
   safe build (and empties the memo, or misses, in a release one), so a future rollback while they
   are live cannot silently answer from a stale id.
2. *(Moved on 2026-09-24, B4/S5.)* The `number` bridge is now a row of §9.2's receiver table, for
   flex and rigid roots. It creates no evidence parameter, the same ABI as today, and it checks the
   declared type first (CK-21). There is no `appendable` bridge. The step numbers are kept, so
   references to steps 3–6 stay valid.
3. **The module rule.** `T`'s declaring module:
   - **This module.** The P3 index gives declaration `d`:
     - annotated, or its group is `done`: take the scheme;
     - its group is `checking` or `unchecked`: §10.
   - **Another module.** `Interface.findValue`:
     - `pub`: take the scheme;
     - private: `fail(private_method)` (§11.3).
4. **Matching.** Instantiate the method scheme. Unify its **first parameter** with the receiver, and
   the whole scheme with `w.method_type`, with category `.method_signature` naming the method.
   - The instantiation's own requirements are the **sub-wanteds**, created by I5 in canonical
     order.
   - The answer is `top(d, args)` or `ext(m, v, args)`.
   - Because the requirements come from the instantiated scheme, their receivers are whatever
     unification made them. That is the fix for CK-27 and CK-28: `Holder (List a)`'s `a.eq` gets
     the element's `eq`, not the list's.
   - *Amended by R9b (CK-131): the plain-method fast path* (v1's `plainMethodMask`, diary
     2026-09-24 00:17). Another module's method whose interface scheme is PLAIN —
     `T q₁ … qₙ, T q₁ … qₙ -> Bool|Order` over distinct quantifiers of kind `any`, not
     `equatable`, each asked for nothing but the method's own name at `qᵢ, qᵢ -> Bool|Order`
     (`List.compare … where a.compare`) — asked on `T t₁ … tₙ` at a method type that already is
     `root, root -> Bool|Order`, every `tᵢ` a structure or an alias and none younger than the
     frame, is not instantiated: the instantiation and the match could only succeed, and all they
     leave is one sub-wanted per constrained `qᵢ`, made in canonical order (the argument order:
     the quantifiers are discovered in the receiver), `kind` `.where_clause`, on `tᵢ` at
     `tᵢ, tᵢ -> Bool|Order`, with the use's origin, declaration, parent, `seq` and queue, and
     readied at once — as binding `qᵢ` to `tᵢ` readies it (`Instances.plainImported`). The
     resolution order and every diagnostic are the instantiation's. Plainness is read off the
     interface once per module check (`Resolve.State.plain`).
   - *Amended by R15-fix-A (2026-09-28, CK-137, unsound): a memo is keyed by every input of
     the verdict it remembers.* Plainness depends on the receiver's type `T` as well as the
     value — by the module rule one value is the method of every type its module declares, and
     `eq : A, A -> Bool` is plain on `A` and not on its sibling `B` — but the memo was keyed
     `(module, value, method)`. The first use at `A` was reused at `B`, which was answered with
     `A`'s `eq` (`Two$eq` called on a `B`, exit 0) where the module-rule clash is due, and
     acceptance depended on declaration order (I9). The key is `Instances.PlainKey`: module,
     value, type, method. The other resolver memos were checked for the same mistake and key
     what their verdict depends on: the derived-answer memo the receiver's root (§9.5), the
     derivability memos a root and kind, `Elaborate`'s rows a type (or a shape) and kind, and
     the derived contexts a unit of type × method (§11.2).
5. **Derived.** Not found, the method is well-known, and the call is marked (§1.3 of the spike):
   - **nominal `T args`**: `Instances.derivedContext(T, m)` (§11.2):
     - `present(ctx)`: answer `derived(index)` in this module or `ext_derived`, with one sub-wanted
       per context entry `(i, m')` on `args[i]`;
     - `absent(reason)`: fail with the reason's code: `not_equatable`, `no_methods_on_shape` or
       `private_method`;
     - `blocked(group)`: §10.
   - **closed record, tuple, unit**: `derived(shape)` with one sub-wanted per field or element
     (`static-dispatch-spike.md` §9.2 and §9.3, unchanged). A record's closedness is
     `Walk.recordRow` (CK-08).
   - **open record**: `fail(no_methods_on_shape, .open_record)` (CK-54).
   - **`func`**: `fail(not_equatable)` for `eq`, `fail(no_methods_on_shape)` otherwise.
6. **Not found**: `unknown_method` with the edit-distance suggestions.

Sub-wanteds are resolved in the same drain. A rigid inside a derived shape (CK-20) is a sub-wanted
on a rigid, so it reaches the `rigid` row of §9.2, which gives a missing-constraint error at the
comparison, not a structural answer.

### 9.4 Promotion and the undetermined default

At the boundary that quantifies a flex receiver:

| Situation | Answer |
|---|---|
| the binder is annotated | a wanted not covered by a given was already `missing_where_constraint` (Rule U2) |
| unannotated top-level declaration, or a `let` binding (D5) | **promote**. The requirement lists of a binding group are computed per member from each member's own scheme (§12.3). A wanted raised in member `m`'s body is answered `param(m, k)`, where `k` is `(q, method)`'s index in **`m`'s** list. If `q` is not in `m`'s list, §12.3's cases 2 and 3 apply. Several wanteds of one name on one variable are already aliases (§4.2). *Revised 2026-09-24 (round 2, N7): "promote to the binder" was ambiguous for a group.* |
| over `max_inferred_constraints` (64) | `too_many_inferred_constraints`, with each receiver named (CK-58). The binder promotes nothing, as today (spike §10.11) |
| `pub`, unannotated, with ≥ 1 requirement | `ambiguous_method_receiver` warning, unchanged |
| `pub`, zero parameters, inferred requirements | `constrained_constant`, unchanged. Its scope is decided by §12.5 |
| the receiver is **not reachable** from the binder's scheme type, and is not quantified by any enclosing binder (proven undetermined) | the §7.2 default. On a shape, `eq`/`compare` resolve by that shape's structural `derived` function, as `settleUndetermined` does today. On a bare variable they get the `undetermined` leaf (§13.1). For any other method, `missing_where_constraint`-class ambiguity at `origin`. This is the only structural answer the resolver gives, and only on proof |

### 9.5 Termination and cycles (CK-03, CK-37)

- **Cycle-safe walks, and one report per cycle.** Every resolver walk over a receiver (instance
  lookup, derived-context queries, `recordRow`) goes through `Walk.zig` with colours, over
  `structural` successors (I2).
  - **Which defence fires first is fixed** (pinned 2026-09-24 for CK-37). A cycle is closed by a
    unification in some constraint node. Eager draining (§9.1) runs right after that node, before
    any later node, `binders_end` or boundary. So when a wanted on the cyclic receiver exists, the
    **resolver walk** meets the cycle first.
  - That first detection reports **one** `infinite_type`, at `w.origin`, and **poisons the cycle's
    root** (`err`), as Elm does for an infinite type. Every later wanted on it, and the
    `binders_end` and boundary occurs checks that later reach it, see `err` and stay silent. One
    infinite type gives one message.
  - When no wanted is on the cyclic variable, the `binders_end` or boundary occurs check is the
    first to see it, and does the same.
  - **A non-cycle rejection** (`unknown_method`, `private_method`, `no_methods_on_shape`,
    `not_equatable`, `missing_where_constraint`) does **not** poison the receiver. The wanted is
    `failed`, and a `dispatch_rejected` flag is set on its receiver's class, OR-merged on union as
    Roc does (`store.zig:756-771`). It silences only later wanteds *of the same method* on that
    class, so unrelated uses of the receiver still report (CK-37).
  - *Both behaviours are what `7427828` already does* (round 4 probes `cyc1`, `indep`), so CK-37's
    fixtures are regression guards.
- **A lineage rule replaces `cycle_check_depth`.**
  - Each sub-wanted records its parent.
  - Resolving a wanted whose `(method, target)` equals an ancestor's **and whose receiver root is
    the ancestor's receiver root, or reaches it by `structural` successors**, is `infinite_type` at
    the root wanted's `origin`.
  - Receivers are compared by **root identity** and reachability. "Strictly larger" is not defined
    on the cyclic graphs this rule exists for.
  - An equal-root repeat is **not** answered by the ancestor. A cyclic evidence term cannot be
    represented (`Term` is a tree), and P6 would not terminate.

  On an acyclic receiver an equal repeat cannot arise from well-typed input:
  - sub-wanted receivers are images of a scheme's quantifiers, strictly inside the parent receiver;
  - nominal recursion goes through the §11.2 fixpoint, not through resolution.

  *Withdrawn by R6a's round-2 review (2026-09-25, N1): the premise above is false.* A `where`
  clause may constrain a quantifier of ANOTHER parameter, so a sub-wanted's receiver is whatever the
  caller passes there — the parent's receiver itself, or a type that holds it — on a receiver with
  no cycle at all. `describe : Box a, b -> String where b.describe : b, K -> String` called as
  `bx.describe bx` asks `describe` of `Box Int` twice and ends at `K`'s: finite evidence,
  `describe_Box(describe_Box(describe_K))`, which v1 builds and runs. An equal or containing repeat
  therefore does not imply a cycle, and the lineage rule is **replaced by a cycle test**: a wanted
  on a structure is `infinite_type` at its origin exactly when its receiver root lies on a cycle
  (`Instances.cyclic`, an occurs walk over `structural` successors), and the derivability walk
  meets any cycle a derived shape passes through (§9 *As built*). A repeat on an acyclic receiver
  is resolved like any other wanted; one that grows without end (`where b.describe : b, Box b ->
  String` on itself) is non-cyclic and is stopped by the step budget below, which is reported.
  Termination therefore rests on the budget, not on the lineage.
  So the rule only ever fires on the cyclic case. The drain backstop `1 << 20` stays as a reported
  backstop (`nesting_too_deep` plus poison), as `static-dispatch-spike.md` §6.3 requires. It counts
  **resolution steps per module, cumulatively** across every eager drain, frame and fixpoint (round
  4, S4-3).
  *Revised by R6a's review (2026-09-25, F1):* **per top-level group**. A module-cumulative count
  scales with the module, not with a pathology: 4 000 annotated `a == b` over a 100-field record
  spent it and a valid program was refused. A runaway resolution is one group's, so the budget is
  reset at every group (`Solve.group`) and its message says what happened
  (`Messages.resolutionBudget`, still `nesting_too_deep`) rather than naming a type nesting depth.
  *Revised 2026-09-24 (S14): the first draft let an equal repeat be "answered by the ancestor".*

*As built by R6a (2026-09-25).* `check2/Resolve.zig` (the step, attach, promotion, the lineage
rule) and `check2/Instances.zig`'s second half (lookup and the derivability walk); the texts are
v1's, through `Report`.

- **The step** is §9.2's table. A `method` node creates the callee's wanted and steps it at once
  (Rule U0: a record known at the call is a field call); an instantiation's wanteds ride on their
  fresh receivers until `unify` readies them. The bridge unifies the method type with the
  well-known signature for a flex AND a rigid `number` (CK-21), under the category
  `.where_clause` when the wanted came from a clause (CK-55's half; its text is R13's). A given
  unifies its method type with the wanted's, and a mismatch is v1's
  `method_constraint_mismatch`.
- **Lookup** is §9.3 in v1's order and with v1's texts: the table; the module rule (P3's index for
  this module — an in-flight member is the §10.3 link, an unchecked one R7's refusal; another
  module's `pub` value, else `private_method`); matching, which instantiates the scheme with
  `parent` set, so its requirements are the sub-wanteds, and unifies it with the method type — a
  failure is the module-rule clash, v1's `type_mismatch` naming the method's type — at a use AND for
  a requirement of a method's context (review F2: a sub-wanted whose method exists at the wrong type
  is that, never a derivation's refusal) — and only at a DERIVED shape's position the shape's
  refusal, reported once for the lineage root's receiver (row 72's `SpecializedEqWrongReceiver`,
  v1's rule); derivation (below); `unknown_method`. A receiver already on a cycle *when its
  wanted is resolved* is one `infinite_type` at the use, poisoned, and nothing is looked up on
  its head (review F5). A wanted resolved while the cycle is still open — `( x.foo (), x ==
  Just x )`, drained on `Maybe a'` before `a'` is `x` — meets an honest `unknown_method` first,
  and the cycle is reported when it closes: two messages, as v1 gives (round-2 review, nit 1).
- **Derivation** reads the derived shape's positions — a nominal type's arguments (one per
  parameter, R8a replaces it), a closed record's fields in name-text order, a tuple's elements —
  and answers `derived` with one sub-wanted per position, each stepped at once: a flex position
  rides on its variable, a rigid one needs a given and is otherwise `missing_where_constraint` at
  the use (CK-20), a concrete one is resolved in turn.
- **THE derivability verdict** *(rebuilt by R6a's review, 2026-09-25, B1 and B2)* is
  `Instances.derivability(root, kind)`, and every derivation reads it — no shortcut, no second
  opinion: the first round's `walked` bit let a position that was a flex when its shape was walked
  skip the verdict once it was bound (`( h, 1 ) == ( h, 1 )` with `h` a `Handler (Int -> Int)` later
  was accepted), the walk skipped alias nodes (`type alias H = Handler` was accepted), and a
  `derivesNominal` answered "derivable" for every non-foreign type. Now:
  - one **iterative** walk (I4) over `(node, method kind)` pairs, a growable stack of frames, each
    pair coloured grey/black in the walk's own map: a pair met grey again is a cycle —
    `infinite_type` at the use, poisoned — whichever method the boundaries alternate through (an
    `eq` asking its payload for `compare`, whose `compare` asks for `eq`: v1 recursed through
    that and overflowed its stack, CK-101);
  - successors: an ALIAS node's expansion; a node with a `pub` method of the kind (a method
    boundary) its arguments, each for the kinds its requirement bits name — its own kind, `eq`,
    `compare` — as pairs of their own kind on the same stack (v1's remapping kept: a failure under
    a boundary's `eq` requirement is `contains_function`, under `compare` `opaque_type`); every
    other node its `structural` successors for the same kind;
  - a node's own verdict (`gate`): a function; a record wider than the cap; a nominal type whose
    head does not answer the kind — `contains_function` if it holds a function, else
    `opaque_type`; an own type whose method of that name has no scheme yet is R7's refusal;
  - a variable is not a verdict: it rides, and its sub-wanted is asked again when it is bound;
  - linear on a DAG: a pair is walked once per walk, and a pair whose whole subgraph is ground
    (no variable below) is kept in `Resolve.State.derivable` and never walked again in the module.
    *Amended by R9b (CK-131):* that memo is a dense column indexed by the root (one bit per
    kind), not a hash map; and a ground receiver of at most 64 words whose every nominal head is
    §3.2's or another module's is kept by its STRUCTURE (`Derivable.Shapes`, the encoding
    `Walk.encodeGround` makes): its verdict reads nothing but the structure, the table and
    interfaces that cannot change during the module's check, so 6 000 declarations comparing
    `( Int, List Int )` walk it once. The dense column and the shape memo's last-encoding cache
    are keyed by variable ids; §9.3 step 1's *amended by R9b* note says what guards them.
- **Sharing (CK-80)** *(narrowed by R6a's review, B3)*: only an answer that depends on the receiver
  alone is shared — a DERIVED one (`Resolve.State.derived`, keyed by the receiver's root and the
  method). A later well-known wanted there has its own method type checked against
  `root, root -> Bool|Order` by a unification that reports (never one used as a test) and is
  answered `alias`. A method the module rule finds is instantiated per use, never shared: the
  first round shared one instantiation of `m : T, a -> a` across uses at `Int` and `String`.
- **The cycle test** *(replaces the lineage rule; round-2 review, N1)*: before anything is shared
  or looked up, a wanted on a structure whose receiver root lies on a cycle (`Instances.cyclic`) is
  one `infinite_type` at its origin, the cycle poisoned. The first round's lineage rule — an
  ancestor's `(method, receiver root)` repeated, or the lineage root's receiver reached — fired on
  valid programs whose `where` clause constrains another parameter (§9.5's withdrawn premise). The
  lineage (`parent`) remains for failure propagation and the one-message-per-rigid key.
- **The step budget** (`1 << 20` steps per top-level group, review F1) reports
  `nesting_too_deep` once, in its own words, and fails the group's later wanteds.
- **Promotion** (`Resolve.close`) walks each unannotated member's scheme with
  `Evidence.requirements` and answers each wanted it reaches `promoted(root, method)` — the
  requirement, whose index P6 computes per site (§12.3; review S1); over 64 it is
  `too_many_inferred_constraints` and the sets are emptied (§10.11). The default answers an
  unreached well-known wanted `undetermined`; any other method is v1's
  `undeterminedMethodReceiver` (`unknown_method`).
- **CK-37**: a rejection poisons the method type (v1's, so what the call returns is silent) and
  never the receiver, so another method on it still reports. The class flag is
  `Evidence.rejected`, per concrete receiver root, method and surface: a later wanted of the same
  method there fails in silence. *Revised by R6a's review (S3, F3):* it is **OR-merged on every
  union** — `Unify.merge` is the one place `unify` merges, and it moves the dropped root's flags to
  the survivor — so the diagnostics no longer depend on which side of `[ x, y ]` became the root.
  A rejected sub-wanted fails its parent and the whole lineage (a parent is never answered over a
  failed argument).
- **One message per rigid and method at a use** *(review F4)*: a rigid met more than once inside a
  derived shape is one `missing_where_constraint` (`Resolve.State.missing`, keyed by the lineage
  root's origin, the rigid and the method).
- **A lying clause on a `number` rigid** *(review S6)* is checked where it is written: at the
  declaration's `member` node, a given for `eq`/`compare` on a `number` rigid is unified with the
  well-known signature under `.where_clause` (`Resolve.checkGivens`), so the declaration is
  reported at its clause, not only at its callers.
- **No cascades** *(review F6)*: a scheme that failed publishes `<error>` (§14.1) and no
  `ambiguous_method_receiver` (the first round printed `where a.get : ?`); a call whose result
  meets its expectation with a message fails, in silence (`Solve.failInstantiation`), those
  requirements of its callee's instantiation whose method type reaches a variable of the callee's
  result — they were read off the same wrong result — and what the arguments readied is drained
  before the result is unified. *Narrowed by the round-2 review (S1):* the callee's row is taken
  at the call node, a requirement that shares nothing with the result still reports (v1's two
  messages), and a failed wanted is never an alias target — in `Resolve.attach` and
  `Unify.unionWants` a live wanted of the same name takes its place in the set, so a flex's set
  stays its open wanteds (§4.2).
- **Invariants report** *(review S8)*: step 7's "promotion unified nothing" and "no speculation is
  open" are `Solve.expect` — a debug build stops, a release build reports `internal` — never a
  debug-only assert.

---

## 10. Own methods without a scheme: deferral, nesting and merging (D3, CK-36)

This replaces priority groups (`Check.zig:1254-1308`), the capability re-settles between them, and
`method_needs_annotation`.

### 10.1 The situation

Resolution, a derived-context query, or a **value** reference reaches a declaration `d` of this
module. `d` is **unannotated** (§6.6: an annotated `d` is always instantiated from its scheme), and
the effective status of its group `G_d` (§4.4) is not `done`.

*Rewritten 2026-09-24, review round 2 (N3). The round-1 design parked such a use until the frame's
boundary, and that was still order-dependent: the parked result stayed a flex for the rest of the
body, where the other declaration order would have made it concrete at once. Nesting **at demand**
removes that difference, and it deletes parking, park lists, settle-time nesting, pinning and the
value-prefix closure.*

### 10.2 Nesting at demand

There are two cases, by `G_d`'s effective status.

- **`unchecked`: check it now.**
  - `checkGroup(G_d)` runs immediately, in a fresh top-level-kind frame at rank `top + 1`, in the
    middle of whatever is being solved.
  - Its own references do the same, recursively: a value reference to another unchecked group nests
    that group on first reference. That is the whole of the old "prefix" rule, because SCC order
    guarantees nothing about a group reached out of order.
  - When `checkGroup(G_d)` returns **`done`**, `d` has its scheme. Resolution instantiates it and
    continues, at the same solving step at which it would have continued had `G_d` been checked
    first.
  - When it returns **merged** into a frame below (its check found a back-edge), `d` has no scheme
    yet. The demanding site takes the in-flight path instead: §10.3, or for a fixpoint payload
    §11.2's in-flight branch. *(Round 3, S-1.)*
  - **Nesting depth is bounded, and reported** (round 3 S-4; revised in round 4, R7-3).
    - **One budget.** The recursion guards of `Constrain` and `Solve` (`checker.md` §5) become one
      budget for the whole stack of frames, rather than one per walk. The budget is **2 × (one
      declaration's worth, `Parse.max_depth + 104`)**. `check_stack_size` (64 MiB) is already twice
      the 32 MiB that M2b measured for one declaration (`Check.zig:412-421`), so the existing
      argument covers it.
    - **Admission.** Every nested `checkGroup`, and every fixpoint frame (§11.2), charges `nest_cost`
      units. A frame is **admitted only if the remaining budget is at least one full declaration's
      worth plus `nest_cost`**.
      - So a nested group that has started can never run out inside its own expression walks.
      - The refusal is always at the demanding use: `nesting_too_deep` with the hint "annotate
        `<method>`". An annotated method is never a demand for nesting (§6.6). The use is then
        poisoned, and the method's own group is never poisoned by it.
    - **`nest_cost` is a counted constant.** It is calibrated once, in a **Debug** build, where
      frames are largest, recorded in the source, and never measured at run time. So Debug and
      ReleaseFast refuse the same programs, and the result is deterministic for a given source (rule
      5): it is per module and single-threaded.
    - **What reaches it.** Not "only thousands of methods": two declarations can.
      - For example, a method whose body is about 2 500 levels deep, used about 2 500 levels deep
        inside another declaration, is refused when the use is checked first and accepted in the
        other order. That is generated code in practice.
      - The limit is **order-dependent at that extreme**, and this is stated, not hidden (I9's one
        exception).
      - *Corrected by R7 (2026-09-26):* the pair as described is admitted by the rule above; two
        demands in a row, each about 2 150 levels deep, reach it (§10.8, `scenario/NEST-DEEP`).
      - Rule 7 holds. It bounds a real blow-up, a native stack overflow on valid input, and an
        annotation or a reordering lifts it, as with the 64-constraint cap.
    - *Rejected alternative:* an explicit continuation stack. It would have to turn `constrain`,
      `solve` and `resolve`, three mutually recursive tree walks, into a state machine. That is the
      largest complexity cost in the design, paid for input no person writes.
    - **Tested** by generated scenarios (`checker-rewrite.md` R7):
      - a reverse-ordered method chain, under the budget and over it;
      - a pair of deep declarations.

      Over the budget there must be exactly one `nesting_too_deep`, at the demand and with the hint,
      and never a crash.
- **`checking`: a back-edge.** Take the in-flight link (§10.3) and merge (§10.4).

```
checkGroup(G):
    G.status = checking; push frame (rank = top + 1)
    constrain G; solve G      -- any demand on an unchecked group nests right here;
                              -- any demand on a checking group is a back-edge
    boundary (§8.1)           -- or, if G's frame was merged, steps 1–2 and hand-down
    G.status = done; pop
```

**Why nesting at any point is sound, and why it restores I9.**
- A nested group is a top-level group. Its frame is above every open frame, and it shares no
  variable with any of them. The only exception is a back-edge, which §10.4 turns into a merge.
- So it is solved, defaulted and generalised exactly as it would be at top level, and its scheme is
  a function of its members and of the schemes of the groups it depends on.
- The demanding site then sees that scheme at the same solving step as in the order where the group
  came first. So every later constraint of the site's body (a U0 resolution, a `let` generalisation)
  meets the same types in both orders.

Round 2's N3 program is the witness. With the `makeBox` use written before `makeBox`, the scrutinee
is resolved inline to `Box Int`, `g : ∀b. (Int -> b) -> Box b` generalises, and the program checks,
as it does with the declarations reversed.

**Where v2 departs from Roc.** Roc nests only at group boundaries, pinning the waiting relation to
the group's rank (`references/roc/design.md:2201-2208`). So an inner `let` that uses a
not-yet-checked method can be generalised in one order but not in the other. Nesting at demand
removes that dependence.

**Pinning is retired.** Ordinary rank adjustment makes it unnecessary.

### 10.3 The in-flight link

When `d` is unannotated and its group is `checking` (effective status), whether it is the group
currently being solved or one lower on the stack, the use is monomorphic. That is the ML rule for
recursion:

- a dispatch use unifies `w.method_type` with `d`'s header variable, with no instantiation, and the
  wanted is answered `group_call(d)`;
- a value reference is `d`'s header variable, and is recorded as `group_call(d)` for evidence.

§12.3 fills the arguments from the per-member requirement lists after the group's promotion. **A
reference to an annotated `d` never takes this path** (§6.6, round 2 N8).

### 10.4 A back-edge merges top-level groups (D11)

A back-edge from the current nested chain reaches `d`, unannotated, in a group whose root frame is
`j`, lower on the stack. Because each frame drains only its own `ready` queue (§9.1), the stack is
a **demand chain**: frame `j` demanded the next top-level frame, and so on up to the top, and the
top now demands `j`. *(Round 3, B-1: with one shared queue this premise was false, and an unrelated
group could be merged.)* So the groups of the **top-level-kind** frames from `j` up form a cycle
through value or dispatch edges, which makes them mutually recursive.

- **Only top-level-kind frames merge** (round 2, N5). Their groups get `merged_into = root(j)`, as a
  union-find union.
- **`let` frames never merge.** Each generalises at its own boundary. Ranks already keep it from
  quantifying anything that reached a merged frame, because such variables took the lower rank.
  Round 2's N5 program is the witness: `g` inside `weight` generalises `y` whichever of `size` and
  `weight` comes first.
- **A merged top-level frame runs only steps 1 and 2 of §8.1 at its end.** It hands its pool,
  `binders` and `touched` segment to `root(j)`'s frame, lowering their ranks to that frame's, and
  pops. It applies **no `?` default** (round 2, N4). Defaults, occurs, quantification, the
  generality check and promotion happen once, at the root's boundary, when every member's facts
  are in.
  - Round 2's N4 program checks in both orders: `bm`'s `m?` waits for `am`'s `Box (Just n)`.
  - Debug assert: no group is nested after a frame has applied its first default, whether the
    frame is a top-level root or a `let` frame (round 3, N-2). A default only makes a `Result`, whose
    methods are `core`'s and already `done`.
  - *Corrected by R7 (2026-09-26):* the premise is false. A derived `Result` asks its positions'
    methods, which may be this module's and `unchecked`, and the assert is not added (§10.8).
- **All members of a merged group share one failure bit** (§15.2) and are generalised **together**.
  Their calls to each other are group calls (§12.3).
- **A back-edge to a group already merged into a root merges from that root** (S-new-3).

This is how `eq a b = compare a b == EQ` together with a `compare` that uses `==` on its own type
checks, whatever order they are written in.

### 10.5 Properties

- **Terminates.** A group enters `checking` once. Nesting follows demands, and a demand on a
  `checking` group is a back-edge, not a nesting, so the nesting depth is at most the number of
  groups.
- **Order-independent (I9)**, by the three rules I9 names. *(Restated 2026-09-24, round 3.)*
  - **Outside a recursive group.** A group's scheme is determined by its members and by the schemes
    of the groups it depends on, by value or by dispatch. Every such group is `done` when the scheme
    is needed: checked earlier at top level, or nested at the demand.
    - A nested check is exactly a top-level check in a fresh frame (§10.2).
    - Per-frame queues keep the stack a demand chain.
    - Eager draining gives every use its answer at the solving step at which the other order would
      have given it (§9.1).
  - **Re-entrant derived queries** run a fresh fixpoint, so they see the same inputs in every order
    (§11.2).
  - **Inside a recursive group** (a value SCC of two or more members, or a merged group), members
    are solved in source or demand order, so one member can see another's partial facts early in
    one order and late in the other. D14 (§10.7) makes every such observation pessimistic, which
    makes it order-independent. Where a merge begins is a function of each member's own body
    prefix (§10.7).
  - Merging depends only on which top-level groups form a cycle through value or dispatch edges to
    unannotated declarations. That is a function of the program.
  - The remaining choices are made in id order.
  - R7's permutation scenario tests this over every counterexample of review rounds 1–3
    (`checker-rewrite.md`).
  - **One stated exception:** the nesting budget of §10.2. A generated pair of very deep
    declarations, or a long reverse-ordered chain, can reach it in one order and not the other
    (round 4, R7-3).
- **Deterministic (rule 5).** Everything above is per module, single-threaded, and ordered by
  source-derived indices.
- **What still needs an annotation:** nothing, for ordering reasons (D3). Two things need one for
  non-ordering reasons, as in Elm:
  - **Polymorphic recursion through an unannotated recursive group**, where a member is used at two
    types inside its own group, by value or through dispatch. It is monomorphic by §10.3, so it is a
    `type_mismatch`, with §10.6's hint. An annotation lifts it (§6.6).
  - **A derived instance whose parameter-indexed context depends on an in-flight inferred method**
    (§11.2): `method_needs_annotation` (D3 as amended, §21.1).
  - **A method call on a group-level receiver inside a recursive group, whose result a `let`
    helper would need to be polymorphic in** (D14, §10.7). An annotation on the member that
    produces the receiver lifts it, and the hint names that member.

  In every other case `method_needs_annotation` is no longer emitted. Its code stays in
  `diagnostic.Code` and in `language.md` §10's catalogue.

### 10.6 Worked examples

Every program below is a planned fixture (`checker-rewrite.md` R7). All are written in valid beni: a
method needs at least one argument besides its receiver, because `x.m` alone is a field access
(`static-dispatch-spike.md` §11). Round 2's programs are corrected accordingly, as `.size ()`.

**Nesting inside a `let`** (round 1, B6):

```elm
type Box a = Box a
f u = let g x = (Box x).size () in ( g 1, g "s" )
pub size (Box _) u = 1          -- unannotated, written after f
```

`(Box x).size ()` demands `size`'s group while `g`'s body is being solved. `size` is checked nested
(`Box a, b -> Int`), the wanted resolves, and `g` generalises. The program checks, as it does with
`size` written first. The same holds for `g : a -> Int; g y = (Box y).size ()`, which must not report
a spurious escape. v1 refuses the unannotated order with `method_needs_annotation` (CK-63).

**Order-dependent refusal made strict: D11 is stricter than Roc** (round 1, S17). Take a module with:
- `type K = K Int` and `type Box a = Box a`;
- an unannotated `pub show (K n) u` that compares `Box 1 == Box 2` and `Box "x" == Box "y"`;
- an unannotated `pub eq (Box a) (Box b)` whose body mentions `\w -> (K 0).show ()`.

`show` and `eq` form a cycle through dispatch, so v2 merges them (§10.4). Inside the merged group
`eq` is monomorphic, so its uses at `Box Int` and `Box String` are a `type_mismatch` in **every**
declaration order.

Roc lets a nested group generalise whatever does not reach the suspended frame
(`design.md:2221-2225`), so it accepts this program in one order and rejects it in the other.

v2 keeps D11. It is deterministic (I9), and the program needs one annotation (`eq`'s), which the
message says:
- `type_mismatch` at the second use;
- plus the hint "`eq` is used at two types inside a group that is recursive through method calls
  (`eq` → `show` → `eq`); an annotation on `eq` lets each use instantiate it".
- The printed cycle starts at the member whose name is smallest by text, so the message is
  byte-identical in every declaration order (round 2 nit).

Rule 7 is kept: the refusal stands only where the alternative is order-dependent, and it names its
escape hatch. v1 refuses it with `method_needs_annotation`, so the fixture is pending (CK-70).

### 10.7 Recursive groups: canonical pessimism (D14)

*Added 2026-09-24, round 3 (B-3). This is decision D14, taken under the owner's standing
instruction to take the reviewers' recommendations, and flagged to the owner.*

**The problem.** Inside a recursive group, members are solved in an order: source order for a value
SCC, demand order for a merge. A `let` helper that makes a method call on a **group-level**
receiver, meaning a variable whose rank is the group's top-level rank, such as another member's
result, sees different facts in different orders. Round 3's `sccA`/`sccB` shows it:

```elm
pub combine (Box a) z = Box a
f n = let r = g n
          q z = r.combine z
      in ( q 1, q "s" )
g n = if n > 100 then Box n else let _ = f (n + 1) in Box n
```

- **`g` written first:** `r : Box number` is already known, the call resolves inline, `q`
  generalises, and the program is accepted.
- **`f` written first:** `r` is `g`'s unsolved result. The call attaches to a flex, I15 lowers `z`,
  and `( q 1, q "s" )` is a `type_mismatch`.
- **v1:** `check` accepts both orders. `build` then stops with two *different* internal errors, one
  per order (CK-72).

**The rule, over wanteds** (restated 2026-09-24, round 4, R7-1). The round-3 rule looked only at a
method-call node's receiver. Two kinds of wanted slipped past it:
- **instantiation evidence**: `useMix r z` with `useMix : a, b -> a where a.mix : …` (`evA`/`evB`);
- **sub-wanteds of an inline resolution on a young receiver**: `(Box r).combine z` with
  `combine … where a.mix …` (`subA`/`subB`).

Either could be resolved inline in one order and attached-and-lowered in the other. The rule is
therefore stated over **every wanted and every obligation**, at the one place all of them pass
through: **`Resolve`'s single resolution function**, used both inline and by the drain, together
with the attach path of §7.1.

> In a recursive group — a value SCC of two or more members, or a group that has merged (§10.4) —
> whenever **any wanted** is **resolved or attached** while its receiver's root has rank ≤ `R`, run
> `lowerTo(its method type, R)`. That covers a method node's callee, instantiation evidence and a
> sub-wanted alike. For an **obligation**, a deciding variable (the tuple, the interpolated
> variable, the `?` subject or target) at rank ≤ `R` lowers **all** the obligation's variables.
>
> `R` is the rank of the top-level-kind frame of the member whose body contains the wanted's
> creating node. That is the member's own frame rank, even inside a merged group before hand-down,
> where members sit at different ranks with `let` ranks in between (S4-1).

- **Why this is order-independent.** In the order where the receiver is still a flex, the same
  wanted is attached to the same group-level root, and I15 lowers the same closure. In the other
  order, this rule lowers it at resolution. Eager draining (§9.1) resolves right after the creating
  node in both orders, on the same side of the member's merge point, so the "inside a recursive
  group yet?" answer is the same.
- **The result.** In every order the answer is the pessimistic one: `q` is monomorphic, and
  `sccA`/`sccB`, `evA`/`evB` and `subA`/`subB` all report the `type_mismatch`.
- **Single-member groups are untouched.** Round 3's `capt`, which v1 accepts, stays accepted: its
  receiver's facts come only from its own body, so their order is fixed.
- **Where it is built.** An R7 hook in R6a's `Resolve` resolution function. It is local and
  additive.

**Why the rule is order-independent.**
- **Value SCCs** are known before solving, from the SCC decomposition.
- **Merges.** Take each member of a cycle. The node at which it demands the next member of the cycle
  is fixed by its own body, and the merge becomes known while every member is paused at that node,
  in every order. Before that node, a member's body sees no other member's facts, in any order; after
  it, it is inside the merged group, in every order.
  - So "is this node inside a recursive group" is a function of the member's own body prefix.
  - This is argued, not proven. §23 carries it, and R7's permutation scenario tests
    it on 3-cycles.

**The message.** The `type_mismatch` D14 causes carries a hint:
- "`r` comes from `g`, which is in a recursive group with `f`, so its type is not known here yet.
  Annotate `g` and each use can instantiate it".
- **The named member is chosen syntactically** (round 4, R7-2), so the diagnostic is byte-identical
  in every declaration order.
  - The constraint generator records, for each variable a `let` binding or a parameter introduces,
    the group member whose **reference** produced its value in the current member's body:
    `r = g n` records `g`.
  - The hint names that member when the lowered wanted's receiver came from exactly one such
    reference.
  - Otherwise it names **every unannotated member of the group, sorted by text**. The group is the
    value SCC, or the members merged so far, which is prefix-determined per the argument below.
  - The round-3 rule, "the member whose header variable the receiver's root came from", depended on
    union-find class membership, which depends on order. Annotating the member it named could even
    leave the receiver group-level.
- Solving records which variables D14 lowered, so the reporter knows when to add the hint.

**Rule 7.** The refusal buys a guarantee, I9's order-independence. Without it, a program's
acceptance would depend on declaration order, which is exactly what CK-36 and its family exist to
remove. The escape hatch is always available: annotating the member instantiates its scheme (§6.6),
so the receiver is no longer group-level. The annotated `sccA`/`sccB` is accepted in both orders, as
it is by v1. It is the same kind of limit as monomorphic recursion in Elm.

**Alternatives considered**, from the review:
- **HM(X) for outer receivers.** Principal, but it is Roc's side table, which §3 rejects, and it
  reverses CK-02's expectation.
- **Restating I9 with an exception.** It gives up the guarantee.

### 10.8 As built by R7 (2026-09-26)

*Added by R7, and revised by R7's reviews the same day. The sections above stand; this records
how they were built, and the places where building or reviewing them showed the text wrong or
silent (each marked **Correction**).*

**Files.** `check2/Groups.zig` (the groups, their status, a top-level-kind frame's life, nesting at
demand and the `demand` node, the merge and the hand-down, the budget), `check2/Recursion.zig`
(D14's two hooks, and when a mismatch is D14's) and `check2/Producers.zig` (the syntactic reading
of the Bir that D14's hint and §10.6's cycle print, error paths only). `Generalize.zig` holds the
frame stack's primitives (push, pop, a merged frame's queue handed down) beside `Queue`, and step
6's generality check, as §19.1 lays out.

**Groups and status (§4.4).** P4 is `Groups.checkAll`: every group of `Module.bindingGroups`
whose effective status is `unchecked`, in SCC order. A group is `checking` from its generation
(its members' variables exist from `Decl.group` on), and `done` when its boundary ran. The union
find uses path halving. `frame_of` holds a `checking` group's frame index; a merged group's is
cleared at its hand-down, and status is read only through the root.

**Nesting at demand (§10.2).** `Groups.demand(decl)` is the one entry, used by the module rule
(`Instances.ownMethod`), by a derived query that finds an own `eq`/`compare` whose group is
`unchecked` (`Instances.derivable` demands it and asks again), and by a value reference:
- A value reference to a group that is not `done` when the referring group is GENERATED becomes
  a `demand` node (`Tree.Node.Tag.demand`), resolved when it is SOLVED. Only a nested group can
  make one: in SCC order every value dependency is `done` first, so a top-level group pays one
  status test per `.top` reference. A reference to a schema of such a group is a `demand` node
  too, then typed as any schema reference.
- A nested group is generated right before it is solved, at rank `frames.len + 1`, into a tree
  of its own nesting level (reused: nested checks finish innermost first). A check asserts I14
  (no open speculation), since a `demand` node reaches it without `Resolve.step`'s guard.
- `Solve.depth` is not reset by a nested check, so it is the solver depth of the whole stack; the
  per-declaration guard counts from the group's own start (`depth_base`).
- A declaration with no type at all (its annotation or body could not be read, already reported)
  answers a demand `missing`, which poisons in silence; only the budget's refusal is reported.

**The budget (§10.2).** Admission is `depth + resolve_depth + nest_units + nest_cost +
declaration_worth ≤ budget`, with `budget = 2 × declaration_worth = 8 400`. `resolve_depth` counts
resolution recursing into a derived shape's positions (`Resolve.position`), which spends native
stack the solver's depth does not see. `nest_cost` is 3, calibrated once in a Debug build: one
solver depth unit costs at most 2 528 bytes of native stack (a `let` chain, `solve` → `let_` →
`solve`; 2 048 through `and_`, which is also the path of `case` branches, record fields and call
arguments — a call node itself does not recurse), one level of `Resolve.position` 2 496 bytes,
and one nesting of a reverse-ordered method chain 15 552 bytes, of which 4 depth units are the
method body's own nodes and the remaining 7 360 bytes are 2.9 units. A reverse-ordered chain
therefore nests about 599 deep; `scenario/NEST-OVER` (1 000 links) is refused exactly once, at
the 601st method's use, with the hint.

**Correction (the "pair of deep declarations").** §10.2's example — a method about 2 500 levels
deep, used about 2 500 levels deep — is ADMITTED by the rule as written: the demand at depth
2 500 leaves 5 900 units, more than one declaration's worth plus `nest_cost`, and the parser
bounds a declaration at 4 096 levels, so no single demand is ever refused. What reaches the
refusal is accumulated depth: two demands in a row, each about 2 150 levels deep (`use` → `m` →
`m2`), refused once at the second in the order that nests them, and checked in the other
(`scenario/NEST-DEEP`). The limit stays I9's one stated exception.

**The in-flight link and the merge (§10.3, §10.4).** A demand on a `checking` group is in flight:
the member's own variable, answered `group_call` for a method. When that group's frame is below
the current top-level-kind frame, it is a back-edge: every top-level-kind frame above it is marked
merged and recursive, and its group joins the root's class. A merged frame keeps solving, then
runs steps 1 and 2, lowers its whole pool to the root frame's rank (`Walk.lowerTo`, so what a
`let` frame between them shares with it is lowered too) and moves it, its open-`?` list, its
binders (copied out of its tree: the tree is reused), its members and its queue's leftovers to
the frame of its group's root; its wanteds and rows are re-pointed to the root's queue. The
root's boundary runs every step once over all of them: step 4 over its own binders and the
handed-down ones sorted by kind, source position, declaration and name, so which binder names a
cycle does not depend on which member was the root; promotion over every member
(`Resolve.close`); one failure bit (`Report.failGroup`). P6 reads each declaration's group as its
merge root, so §12.3's cases treat a merged group as one. An annotated declaration is a singleton
SCC, never nested or merged, so a merged frame has no generality check to hand down (asserted).
There is no `touched` list to hand down (§8.1's fallback, R4b).

**A merge during a boundary.** *Correction (round 3, N-2's debug assert, and R7's first text
here).* "No group is nested after a frame has applied its first default: a default only makes a
`Result`, whose methods are core's" is false. A default readies a wanted on the `Result`, whose
derived answer asks each POSITION's method — an own unannotated `eq`, say, whose group is
`unchecked` and is nested there (`tests/corpus/check/good/NestAfterDefault.beni`). R7 does not
add the assert. And R7's first reason — "the nested group shares no variable with the defaulted
frame" — is false once the nested group back-edges into the frame that is running its boundary
(R7's structural review, B1; `tests/corpus/run/MergeAtBoundary`). As built:
- Steps 1–3 run first (`Solve.settle`), and the members, the binders and the pool a boundary
  reads are read after them, so a group that joined during them is promoted, failed and settled
  with the rest; before this, its requirements were never promoted and P6 reported `internal`.
- A frame merged into one below it DURING its own steps 1–3 stops there: it applies no more
  defaults, hands the rest of its open-`?` list down with its pool, and its root defaults them
  (§10.4's N4).
- **Why the result is still order-independent.** The joining group is demanded only because of a
  default already applied, so no order sees its facts before that default: the default is
  decided by the facts before it, in every order, and every later fact of every member arrives
  before the class's own remaining defaults and its generalisation, in every order. Whether the
  frame that defaulted is the root (it was checked first) or a member that merges into the
  joiner's frame (the joiner was checked first and nested it), the same defaults are applied on
  the same facts and the class is generalised once.
- **Default order is confluent** (round-2 review, S4). After such a merge the joined class's
  defaults are applied in an order that varies — the root's own `?` rows then the handed-down ones
  in one declaration order, the reverse in another — with a drain between two. The result does not
  depend on it: a `?` default only ever decides its own target as `Result`, so what it readies can
  only decide another `?` as `Result` too, or by facts that hold in every order.

**Per-frame queues (§9.1).** One `ready` queue per top-level-kind frame (`Generalize.Queue`); a
wanted and an obligation row carry `frame`, the queue current at their creation
(`Obligations.current_queue`; a sentinel between frames, asserted at every creation), and
`Unify.enqueue` puts a readied item on it. A merged frame's hand-down (`Generalize.handQueueDown`)
re-points its items (the module's wanteds and rows from its push on that carry its queue:
`Evidence.repoint`, `Obligations.repoint`) to the root's queue, as §9.1 says. `Decide.drain`
takes the queue, which is always the current frame's. For speed the current queue's `ready` list
lives in `Solve.ready` while its frame is current (swapped by push and pop), and a release build
reuses a popped queue, since nothing routes to it again; a Debug build never does, so
`Unify.enqueue`'s check that an item's queue is live keeps its full strength. The reuse path is
therefore exercised only by release builds: the ReleaseFast steps (`test-pending-perf`,
`test-perf`), and the permutation scenario run once under ReleaseSafe in R7's round-2 evidence.

**D14 (§10.7).** The hooks are `Recursion.wanted`, at the top of `Resolve.step` (inline and drain
alike, before the attach path), and `Recursion.row`, where an obligation is attached (before its
`?` list is chosen, so the list is its lowered target's) and where one is decided. `R` is the
rank of the frame the item's queue routes to, when that frame is recursive: a value SCC of two or
more members from its push, or any frame of a merge from the merge on. A frame count keeps the
hooks free where no frame is recursive.
- **Whether a mismatch is D14's** is read when it is reported, before it poisons both sides
  (`Recursion.involved`): a wanted, or an obligation other than `equatable`, made since the lowest
  open recursive frame was pushed, whose frame is recursive, whose receiver (a deciding variable)
  is at rank ≤ `R`, and whose method type (variables) reaches either side. That covers the order
  where the wanted rode on a group-level flex unresolved and I15 lowered it when the flex met
  another, where no hook runs. A receiver rule (a) held back at a `let` (§8.4's switch) is not
  D14's, and its mismatch gets no hint (R7's adversarial review, F4).
- **The hint is written when the class is final** (`Recursion.finish`, at the root's boundary),
  from the program's text and the final class only — R7's first cut wrote it at the mismatch, from
  whichever lowered item met it and the members merged so far, and both depended on the order
  (R7's adversarial review, F2 and F3; structural S1). The mismatch's declaration is the one whose
  instructions hold its region. Its context is the body of the `let` function the refused call
  calls, when the mismatch is a call argument (`q "s"` names `q`'s body), else the innermost `let`
  function around the region, else the region. The members of the class referenced there — by
  value, or by a method call of a member's name — and, through each local the context names, those
  its source references (a `let` constant's body, or the `case` scrutinee or `let` value a pattern
  destructures; followed transitively) are its producers. Exactly one: "`r` comes from `g`, which
  is in a recursive group with `f` … Annotate `g`", naming the local when the member came through
  exactly one. Otherwise every unannotated member of the final class, sorted by text.
- **Codes.** In the round 3 and round 4 programs the refused use is `q "s"` after `q 1`, and a
  number literal meeting `String` is `kind_mismatch` by v1's rule; the pending fixtures' `.codes`
  were amended from `type_mismatch` accordingly.

**A dot-call's field-or-method choice (CK-105).** *Correction.* static-dispatch-spike.md §1.2 and
§11 made `x.m a` a field call when `x` was known to be a record at the call and a method
constraint otherwise, fixed at first sight. Inside a recursive group the first sight is the
declaration order: a member's parameter typed by another member's in-flight call is known in one
order and not the other, so the program was accepted in one and refused in the other (R7's
adversarial review, F1; by value recursion too, predating R7). The *Deferred receiver* rule is
amended (static-dispatch-spike.md §11, 2026-09-26): a dot-call's own requirement whose receiver
becomes a record before the constraint is generalised is the field call (`Instances.onRecord`).
Every member's facts arrive before the class is generalised, in every order.
- *Revised by the round-2 review (X1).* A dot-call joined by Rule U1 with a scheme's requirement
  on the same variable is not a field call (the requirement has no field accessor to be): a bit
  on the older wanted of a join, `Wanted.field_ok`, is set only for a dot-call's own wanted and
  cleared by any join with another (`Evidence.joinField`, written where `Unify` and `Resolve.attach`
  make the alias), and the refusal is reported at the joined requirement's use. Before it, the
  order in which the two were created decided between an internal I7 miscount and the refusal.
- The refusing half — a constraint already generalised, met by a record at a caller outside the
  group — is pinned by `check/bad/DeferredReceiverGeneralised`, and its recursive twin, accepted,
  by `tests/corpus/run/DeferredReceiverRecursiveTwin` (a caller in the same group decides what
  `x.m a` means, as it decides a parameter's type under monomorphic recursion). v1 miscompiles the
  twin (it passes `f` evidence `f` does not take, and prints `EQ`), so it is a claimed pending
  fixture; v2's message for the refusing half renders the record before the lambda's body is
  constrained (§9.1), an expected difference until R11, which re-blessed the golden.

**A `number` receiver's method in a group (CK-106).** A requirement on a `number`-kinded
variable whose method is not `eq`/`compare`, which some member's type does not reach (that member
fixed it with a literal), has no answer: outside a group the caller reports `unknown_method` at
the instantiation (§9.4); inside one the call is a group call and §12.3's case 3 has no
structural answer for the method, which gave two `internal`s (v1: one). Step 7 now reports it as
`unknown_method` at the requirement's use and poisons the variable (`Resolve.undeterminedInGroup`),
in every order.

**§10.6's message.** A method call answered in flight whose method type does not unify, in a class
formed by a merge, is `type_mismatch`: "`eq` is used at two types inside a group that is recursive
through method calls (`eq` → `show` → `eq`) …", with the hint to annotate it. The cycle is the
shortest one through the member whose name is smallest by text, breadth first in text order, over
edges read off the members' Bir (value references and method calls by a member's name), so it is
the same in every declaration order. A value SCC that did not merge keeps v1's
`methodSignatureMismatch`.

**I9's scope, stated** (approved by the owner 2026-09-26; R7's adversarial review, F5; I9's own words are "whether a program
checks, and what it computes"). Order-independent: whether each declaration order is accepted;
for an accepted program its types, its interface and its output; for a refused one, that it is
refused, and — for any given diagnostic — the text this section appends to it (D14's hint, from
its region and the final class; §10.6's; the nesting refusal's). NOT promised: which FURTHER
diagnostics a refused recursive group reports (a first error poisons the variables it met, and
later errors meeting them are silent; which error is found first inside a recursive group depends
on the order — the call-graph fuzz of R7's review round found programs reporting one
`kind_mismatch` in some orders and two in others, on the reviewed tree and after), and a
refused program's message text where it renders a TYPE (v1's shared texts render a type as it stands when the
refusal is found, and inside a recursive group how far another member had got depends on the
order: `not_equatable` shows `a -> a` in one order and `a -> b` in another), and a refused
program's `dump --stage=types`. Nor, for a refused recursive group, WHICH error it reports first: its
one error may be a different code in a different declaration depending on the order (the round-2
in-flight fuzz, seed 28: `not_a_function` at `x 1` in `ma` in 30 orders, `type_mismatch` at the
call in `mc` in 90), because which side of a conflict is met first sets both, as in any HM checker
— Elm hides it behind a fixed source order, and v1 behaves the same. PERM holds its own programs to
more than this. Rendering those after the class is generalised would show the
poisoned types (`?`) the refusal left, and a canonical renaming cannot recover facts that arrived
later; R13 owns diagnostic quality. The one other exception is §10.2's budget.

**Evidence.** `scenario/PERM` (claimed): 41 programs, 2 752 declaration orders — every order up
to 120, else 120 spread evenly over the whole permutation space by rank — each built and run
against its oracle twin's output, or checked, or refused with one diagnostic whose message and
spanned source text are byte-identical in every order (one program, `t102`, is held to its code
and spanned text only, per I9's scope above); for the programs that check, `dump --stage=types`
of six orders compared declaration by declaration. It covers every program R7's brief lists,
round 3's and round 4's (CK-70, CK-72, CK-73, CK-76), 3- and 4-cycles, a member that demands its
cycle at two nodes, a value back-edge, a group nested two `let`s deep, one nested after a default
and one merged during its root's boundary, CK-105's field calls, and D14's hints. §23 items 1, 7
and 8 are carried by it.

---

## 11. Capabilities, derived contexts and privacy

`check2/Instances.zig`.

### 11.1 One question, one answer (I10, CK-26)

"Can `T args` answer `m`?" is `Instances.lookup` succeeding. There is no separate capability table:

- `Types.Entry.answers_eq`, `answers_compare`, `public_eq`, `public_compare`, and the
  `eq/compare_param_requirements` bitmasks are deleted;
- so are `Types.settleDispatchCapabilities`, `Solve.settleOrdinaryCapabilities`,
  `restoreDerivedCapabilities` and `summarizeCapabilityTarget`.

The session `Types` table becomes `*const` everywhere, with no `@constCast`. Each module's derived
contexts live in the module worker's own state, and are **published** in the interface (§14.2).

*As built by R8a (2026-09-26).* Nothing in `src/check2/` reads or settles v1's capability API
(`check2/rules_test.zig`'s S4 fence, its reader list now empty). The `Types.Entry` fields and the
settle stay while v1 does: a cache HIT of a module the OLD checker checked still rebuilds v1's
bits, now on v1's side of the switch (`Check.restoreCapabilitiesOnHit`, called through
`Driver.v1CapabilitiesOnHit`), because v1 dependents read them; a module v2 checked installs its
record and nothing else. `Types` is not yet `*const` in v2: `Groups` and `Solve.settleSchemas`
still write a schema endpoint's properties through it (R8b, §11.5), and `Publish` its `ref_ids`.
`js/Lower` and `Dispatch.requirementCount` read an `ext_derived` target's published row
(`Dispatch.publishedContext`), whichever checker wrote it; only a record with no row (the old
checker's, for a private type) falls back to v1's bits and arity.

*Amended by R8b (2026-09-26).* Nothing writes a schema endpoint's properties through `Types` any
more (§11.5 *as built by R8b*): `Publish`'s `ref_ids` is the one write left before `Types` can be
`*const` in v2.

### 11.2 Derived contexts by fixpoint (D4, CK-25, CK-23)

For an own nominal type `T` with parameters `p₀ … pₙ₋₁` and a well-known method `m` that `T` does
not define, the **context** `ctx(T, m)` is a set of `(i, m')` pairs: "to answer `m` on `T args`,
`args[i]` must answer `m'`".

- **Computation.** Each constructor payload type is resolved as a wanted `(payload, m)` in a context
  where each `pᵢ` is a rigid carrying one given per method name. A given `(pᵢ, m')` that gets used
  adds `(i, m')` to the context. Resolution of the payloads uses §9.3 in full. A payload's custom
  method, `Holder.eq where a.key`, contributes its instantiated requirements: `(0, key)`.
- **The unit is (type-level SCC) × {`eq`, `compare`}** (round 4, R8-2). One fixpoint computes
  `ctx(X, m)` **jointly** for every own nominal type `X` in one strongly connected component of the
  "payload mentions" graph, and for both methods.
  - Each entry lives in the lattice `present(∅) ⊂ present(larger sets) ⊂ absent(reason)`. Every
    entry starts at `present(∅)`, and entries only move up.
  - A worklist re-resolves `X`'s payloads for `m` when an entry they read has changed.
  - The lattice is finite and every step is monotone, so the fixpoint terminates. This is GHC's
    `deriving` inference, taken over both methods at once.
  - **Why joint.** Derived contexts depend *across* methods: `H.eq where a.compare` makes `eq` on a
    wrapper of `H.Holder T` need `T`'s `compare`. A per-`(T, m)` fixpoint would memoise
    `ctx(T, compare) = present` permanently after reading a partial `(T, eq)` approximation. It
    would then answer `a < a` with a derived `compare` whose payload needs an `eq` that turns out
    absent (round 4's `xm`/`xm2`).
- **Reading the approximation, or running fresh** (round 4, R8-1). Let `F` be the fixpoint frame of
  unit `U`. A query for `(X, m)` with `X` in `U`:
  - **reads `F`'s current approximation** when no top-level-kind group frame lies above `F` on the
    stack. That is always true of `F`'s own payload resolution, and of any query made directly by
    it. Such a read is not a new query;
  - **runs a fresh fixpoint** for `U` (a new frame, worklist and approximation) only when a
    top-level-kind group frame **was pushed above `F`**, because `F`'s resolution nested a group
    whose body asks again.

  *The round-3 text said "fresh on re-entry". Read literally, that made `F`'s own payload queries
  re-enter `U` fresh forever: `xm` recursed without bound.*
- **Well-foundedness.** Take any stack of frames.
  - **Between two fixpoint frames of the same unit** there is always a group frame, by the rule
    above. Every group frame was pushed for a group that was `unchecked` at that moment, because a
    demand on a `checking` group is a back-edge (§10.3) and pushes nothing. And no group is ever
    pushed twice. So the number of fixpoint frames per unit on the stack is at most (number of
    groups + 1).
  - **Between fixpoint frames of different units with no group frame in between**, each query
    follows a type mention from one unit to another. The units form a DAG (they are the SCCs of the
    mentions graph), so such a chain is at most the number of units long.
  - **So the stack depth is bounded** by (units × (groups + 1)) plus groups. In practice the budget
    of §10.2, which fixpoint frames also charge (`nest_cost`), bounds it far sooner and reports.
  - This replaces round 3's argument, which was false for the literal reading.
- **Absent.** If any payload wanted **fails**, the instance is `absent(reason)`:
  - a function with no method boundary: `not_equatable` / `no_methods_on_shape`;
  - a private method of another module: `private_method`, per §11.3;
  - a schema endpoint's exclusion: the endpoint's own reason (CK-24).

  The reason is kept for the use-site message.
- **Blocked.** A payload can need an own unannotated method, or a schema endpoint whose conversion
  group is not `done`. **A context computed while any input was in flight is memoised only under its generation, with a
  replay list** (see "Memo generations and replay" below). The cases:
  - **The group is `unchecked`:** it is checked nested at demand (§10.2), from inside the query.
    The fixpoint frame is simply lower on the stack. Then the query continues.
  - **The group is `checking`** (in flight): the payload wanted resolves to an in-flight method `d`.
    Look at the payload receiver:
    - **It mentions no parameter of `T`.** It is closed, as in `type W = W (H.Holder T)` with
      `H.eq where a.key`, where the in-flight method is `T`'s `key`. Then it contributes **no
      context entry**, whatever `d` infers.
      - **The method-type check is an ordinary wanted in the asking frame** (round 4, R8-3). The
        receiver type is instantiated in the frame of the wanted that asked the query (its creation
        frame, §9.1), not in the fixpoint frame, whose variables are discarded. A `(receiver, key)`
        wanted is created there and **resolved by the ordinary resolver**.
        - `d`'s group is `checking`, so that resolution takes §10.3's in-flight link **and §10.4's
          merge** whenever the asking frame belongs to a different top-level group. The round-3 text
          "unified with `d`'s header" skipped the merge, and broke §10.2's premise that a nested
          group shares variables only through a back-edge.
        - Round 4's `cbA`/`cbB` show it: `pick` compares `W`s, and `key` uses `pick 1` and
          `pick "s"`. `pick` and `key` now merge in both orders, and `pick "s"` is a
          `type_mismatch` in both. Annotating `pick` or `key` lifts it.
      - The derived body's term for that position is `top(d, args)`, with `args` filled from `d`'s
        final list after its group's promotion, as for a group call (§12.3).
      - Nothing else is refused (rule 7).
    - **It mentions a parameter of `T`.** An example is `type W a = W (H.Holder (T a))` with an
      unannotated `key (T x) u` whose body compares `W` values. Then a context entry of `W` is
      indexed by that parameter and depends on `d`'s final requirements, which depend back on the
      instance. There is no sound monomorphic reading of a *derived* instance, which is not a member
      of the group.
      - So it is refused with **`method_needs_annotation`**, naming `d`. An annotation on `d` always
        lifts it.
      - The refusal is order-independent: whichever declaration comes first, the cycle is the same.

  *Added 2026-09-24 (round 1, S1). Narrowed in round 2 (S-new-1). The round-1 example,
  `type U a = U (T a)` beside an unannotated `T.eq`, cannot occur under the module rule: `U`'s `eq`
  would be that same `eq`.*
- **Frame and rank.** The fixpoint runs in its **own frame**, pushed on top of the stack at rank
  `top + 1`.
  - Its rigids, givens, payload instantiations and wanteds are created there.
  - None of them is unified with a variable of any other frame. Payload types are instantiated
    fresh from the declarations, and the asking wanted's receiver is never passed in: only the unit is.
  - When the fixpoint finishes, the frame is popped with its variables **discarded**. Its product is
    the list of `(i, m')` pairs, not a type.
  - A debug assert walks the frame's pool and checks that no variable of it is reachable, by
    `owned`, from any variable older than the frame.

  So the fixpoint cannot run at `generalized` or leak variables into an inner `let`, which is
  CK-10 item 2's trap. *Added 2026-09-24 (S1).*
- **Fresh fixpoints, and the result for CK-74** (round 3 B-2, amended in round 4). Round 3's
  program (`key` compares `W`s, `same` compares `W`s, `other = (T 1).key "s"`) gives the same
  result in both orders:
  - with `same` first, `W`'s fixpoint `F` nests `key`, whose query runs fresh (a group frame is now
    above `F`);
  - with `key` first, `key`'s query is the first;
  - either way, `key`'s query reaches the in-flight `key` through the closed branch. That creates an
    ordinary wanted in `key`'s own frame, which is the in-flight link within one group, so no merge
    is needed;
  - so `key : T, () -> Int`, and `other` is a `type_mismatch` in both orders. CK-69's refusal fires
    in both orders too.
- **Memo generations and replay** (round 3 S-6, amended in round 4 R8-3).
  - A **unit** result computed from `done` inputs only is memoised permanently.
  - One computed while an input was in flight is memoised under the current **generation**, a
    counter bumped whenever any group completes, and a lookup hits only in the same generation.
    Such an entry also **stores the list of in-flight methods its closed branches reached**.
  - A hit **replays**, for its asker, one ordinary method-type wanted per listed method, in the
    asker's frame. So every asker in the generation merges exactly as the first did (R8-3), and
    whether a second asker merges does not depend on who asked first.
  - A result that read a partial approximation of **another** unit is never memoised: that other
    unit was on the stack below, so its reader is inside it, and it is recomputed with it.
- **Explicit ranks** (round 3, S-2). `Instantiate` and every function that creates variables take
  an explicit rank and pool, and none uses "the top frame" implicitly. The closed in-flight branch
  creates its method-type wanted with the **asking** frame's rank, pool and queue, even though the
  fixpoint frame is on top.
- **Worklist** (N12). The fixpoint keeps, per own type in the unit, the set of types whose payloads
  mention it. When `ctx(X, m)` grows, only the `(type, method)` entries that read it are re-resolved. It iterates until the
  worklist is empty.
- **Memoised** per **unit** for the module once computed from `done` inputs only (above). P5 reads
  the memo for the eager rows. Nothing is ever re-settled (CK-40).
- **ABI (D4).** The derived function takes **one evidence parameter per context entry**, in
  `(i, m'-text)` order. `static-dispatch-spike.md` §9.4's "one per type parameter, used or not" and
  A.20 are superseded.
  - `type Outer a = Outer (Holder a)` with `Holder.eq where a.key` gives
    `Outer$eq = ($m$0 /* a.key */, x, y) => Holder$eq($m$0, x.a, y.a)`.
  - A phantom parameter contributes nothing, so `Tag (Int -> Int)` is comparable (CK-23).
  - Types whose every parameter is compared with the method being derived, which is nearly all of
    them (`Maybe a`, `Result x a`, `List`), get exactly today's parameter list. So their emitted
    JavaScript does not change (§20.3).
  - **The calling convention past 4 096 entries** is one array `$m`, for every shape (spike §9.2
    *The wide form*, A.87, CK-81): the context is the same, only its JavaScript spelling changes,
    decided by the entry count in `Convention` (R2b).
- **Structural shapes** (record, tuple, unit) keep "one parameter per field or element, same
  method" (spike §9.2 and §9.3). Their context is positional and trivially known. Past 4 096
  positions they take one array, as every shape does (the D4 bullet above).

*As built by R8a (2026-09-26).* `check2/Contexts.zig` (the units, the memo, the fixpoint, replay)
and `check2/Derivable.zig` (the one verdict, reading it). The points the text above leaves open,
and where the build departs from it:

- **The entry's method type.** An entry is `(i, m', τ)`, not `(i, m')`: for a method that is not
  `eq` or `compare` (`H.eq where a.key : a, () -> Int` gives `(0, key)`), the use needs `key`'s
  TYPE at the argument, or an importer could pass a `key` of any type. `τ` is the open wanted's
  method type, frozen over the type's own template parameters (`Instantiate.freeze`: the whole
  graph copied at rank `generalized`, the markers replaced by the parameters) and instantiated at
  a use with its arguments (`Instantiate.substitute`). Published as a scheme (§14.2 *as amended by
  R8a*). For `eq` and `compare` `τ` is the well-known type and nothing is kept.
- **A pass reads the answer off the resolver's own state.** Markers are FLEX variables, not the
  rigids-with-givens of the first bullet: what a payload asks of parameter `i` rides open on marker
  `i`, and Rule U1 joins two asks of one name (their types unified). A marker that becomes
  anything but a distinct plain flex — a specialised instance, `Holder.eq : Holder Int, …`, bound
  it — makes the entry `absent`; so does a position that failed, or a wanted of the pass left open
  on anything but a marker. The absent REASON is what the pass met: a function (`absent_function`,
  `not_equatable`'s "a function in there" and `compare`'s `contains_function`), another module's
  private method (`absent_private`: `private_method` at the use, the reason §11.3 wants), the
  parametric in-flight case (`needs_annotation`), or anything else (`absent_other`).
  *Amended by R13 (2026-09-27, CK-116):* a payload's method that exists and has the wrong type
  for what the pass asks of it — a payload's own `eq`, or a requirement its method's `where`
  clause makes — is `absent_requirement`, with the `TypeId` whose method it is and the method's
  name, so the use says which method failed (`static-dispatch-spike.md` §10.13) instead of
  `absent_other`'s *"a function anywhere inside it"*. A private method met first keeps
  `absent_private`. A use that decides the same failure itself (a present context's entry at a
  concrete argument) names the method and both types.
- **The frame** is a new kind, `.fixpoint`: a queue of its own, no group, never merged
  (`Groups.topFrame` skips it). Every pass reports into ONE quiet report per module; a group a pass
  nests is checked with the module's report (`Groups.solveGroup` swaps it back); an `internal` is
  still said. A run charges `nest_cost` (§10.2) while it is open but is never refused: the chain a
  run can recurse through is bounded by the unit DAG, and dependency units are run first, in order
  (`ensure`), so a chain of `n` types does not recurse `n` deep natively.
- **Which frame reads F's approximation.** Exactly as the round-4 bullet says: the innermost run of
  the unit, when no top-level-kind frame lies above its frame. A read by a pass of the same run
  records a dependency (the worklist); a read by any other run marks that run `partial` (never
  memoised). A memo read (not an approximation) replays.
- **The in-flight branch** (`Contexts.inFlight`, from `Instances.ownMethod` when a run is active
  and the method's group is `checking`): never `Groups.demand`, so the fixpoint itself never
  merges. The closed case answers the wanted `group_call` without unifying and records the frozen
  `( receiver, method type )`; the replay instantiates it in the asker's frame and resolves an
  ordinary `where_clause` wanted there, which links (§10.3) and merges (§10.4) as any other.
  Replay happens on every memo read, so a run that reads another unit's generational result
  inherits its items (it replays into its own frame, where they are its own in-flight items).
- **Memo generations**: `permanent` when the run met nothing in flight, read no generational
  result and was not partial; `generational` (with the replay list) otherwise; `none` when
  partial. `Groups.check` bumps the generation when a group — a merge class's root — is done.
- **The verdict** (`Derivable.derivability`) keeps v1's walk and messages but reads the answer: at
  a nominal head, the context (this module's, or the published row), or — when the module rule
  answers — the `pub` method's requirements read off its scheme (own: `decl_scheme`; imported: the
  interface scheme's first parameter term), which is what v1's `methodParamRequirement` bits
  encoded; a private own method and an own method in flight are no boundary it descends. A head
  whose context is not computed yet stops the walk (`query`); `derivable` runs it and walks again
  (and computes the receiver's own head before the first walk, the common case). A ground verdict
  is kept past its walk only when it read nothing volatile (an approximation, or a result not
  memoised permanently). A record past 4 096 fields is no longer refused (CK-79): D4 and the wide
  form of `static-dispatch-spike.md` §9.2 carry any width.
- **P5** (`Eager`) settles every unit not memoised permanently (`settleAll`, dependencies first),
  and a type gets a row exactly when its context is `present`. A permanent run's last passes ARE
  the rows' bodies (every entry they read was final: the worklist re-ran any pass whose read
  grew), so P5 reads no payload again; a unit memoised only for its generation is run again.
  Every other row body failure is `internal` — no probe, no propagation, no one-entry-per-parameter
  rule: `Eager.marker` maps an open wanted on marker `i` for method `m'` to the entry's index `k`,
  `param derived row k`.
- **`own_method`** stays "a `pub` value of the method's name" (§14.2 as amended): a private `eq`
  still derives rows, which D1 (R8b) decides.
- **Schema endpoints** (§11.5) are R8b's: their verdict still reads the schema's settled
  properties (`Types.schemaPropertyBits`) and a derived answer on one is `undetermined` (`build`
  refuses a schema before anything is emitted). What R8a changed is WHEN the properties are
  settled (CK-40): after a schema group completes they are marked stale, and settled at the next
  read by the verdict or the `equatable` marker walk, and once after P4 (`Solve.settleSchemas`) —
  never after every group.
- **Not built:** the debug assert of the Frame-and-rank bullet (a walk of every older variable per
  run is quadratic even in Debug). What holds the property instead is construction: payloads are
  read fresh at the frame's rank, and every type that leaves the frame is `freeze`d.
  *See R8a's review round, below: a linear form was tried and fails on a real channel (CK-117).*

*Amended by R8a's review round (2026-09-26).*

- **A marker's `equatable` flag is an entry (CK-108).** Flex markers are not rigids-with-givens
  for anything that rides on a flex other than a wanted: a payload method whose scheme asks
  `equatable` of `a` as a FLAG (an unannotated `eq` calling `Basics.eq x y`) leaves the flag, or
  an open equatable obligation row, on the marker and no `eq` wanted. `collect` makes such a
  distinct marker the entry `(i, eq)` unless an `eq` wanted already is. `number` and `appendable`
  kinds make the marker non-plain, so `absent`, as before.
- **One template per answer (CK-109).** An answer keeps ONE frozen tuple of the method types of
  its non-well-known entries (`Answer.template`), and an entry its index in it (`slot`), instead
  of one frozen `τ` per entry; a use substitutes the tuple once. The published form follows
  (§14.2, *amended again*). Marker distinctness is one mark pass, not pairwise.
- **P5's lookup is a map.** `Eager.markerKeys` builds, once per row, the map from an open
  wanted's `(receiver root, method)` to its entry index `k`; `Eager.marker` reads it. The index
  `k` is a `u32` end to end (`Dispatch.Param.k`, Lower's evidence indices): D4 lets entries
  outrun parameters.
- **Bodies are the run's (S4).** A pass writes its positions to its RUN (`Run.bodies`); `run`
  commits them with the answers, and only when the result is memoised permanently. A fresh
  nested run of the same unit (R8-1) no longer leaves its bodies beside the outer run's answers.
  A kept body was resolved in P4 under P4's derived memo: sound because `Builder.read` gives every
  pass fresh variables, so no root of a kept body is one the memo holds.
- **A template changes only with its entry set (S5).** `same` compares status, culprit and the
  `(param, method)` set, not templates. The argument: every leaf of a template is one of the
  type's parameters (a marker, frozen) or ground; a marker that is bound is `absent`; and an
  annotation cannot hold a free variable (`UNKNOWN CONSTRAINED VARIABLE`). So a pass whose set
  did not change has an isomorphic template. Debug asserts it (`Walk.sameShape`, O(size)).
- **The frame assert, tried and withdrawn (CK-117).** The review proposed a linear assert: at
  `popFrame` of a `.fixpoint` frame, every variable of its young pool has its class at the frame's
  rank or deeper, or generalized. Built, it fails on three CLAIMED fixtures
  (`check/bad/DerivedContextMergesAsker`, `…ReentrantSameFirst`,
  `run/DerivedContextClosedOwnMethodPermuted`) and in `scenario/PERM`: a pass that demands an
  unchecked method group (not in flight, so not the in-flight branch) checks it nested, that group
  links to the asker's and merges down (§10.4), and the pass's variables join classes at the
  asker's rank. "Nothing escapes by construction" is therefore false for that channel. The
  fixtures' outputs are right today; whether such a pass is sound, or must be `partial` or
  answer through replay, is recorded as CK-117 and not decided here, and the assert is not
  shipped.

*Amended by R8b (2026-09-26): CK-117 decided, the frame assert shipped.*

- **What R8a's review saw was two things.** The pool-rank assert failed on three fixtures and in
  `scenario/PERM` because a pass that instantiates a *done* method's scheme shares its ground
  structure: `Instantiate.copy` copies only what is generalised, and the generaliser can leave a
  ground node (a `T`) at rank 1, so a pass variable unified with it lands in a rank-1 class that
  holds no variable. That is sound. The channel CK-117 names is real too, but none of those
  fixtures reached it: a pass demands an *unchecked* method group, the group is checked nested,
  links to the asker's and merges down (§10.4), and the demand then returns the member **in
  flight** — which `Instances.ownMethod` unified with the pass's method type, binding a variable
  of the asker's group from inside the discarded frame (`run/DerivedContextPassMergesDown`: `key`'s
  unused `u`).
- **The rule.** A pass never links an in-flight method, however it came to be in flight: a demand
  from a pass that returns a member in flight takes the same closed or parametric branch as a
  method already in flight when asked (`Contexts.inFlight`). The link, and any merge, is the
  asker's replayed wanted, in the asker's frame.
- **The assert, linear, at the point of change.** While a fixpoint frame is the current frame (a
  pass, or P5's rows), no unification may change a flex of an older frame
  (`Unify.assertContained`, per merge) and no wanted may ride on one (`Resolve.attach`). A group
  checked nested above the frame is its own current frame and merges down legitimately. O(1) per
  merge and per attach, Debug only. It panics on `run/DerivedContextPassMergesDown` without the
  rule; with it, every fixture, `test-v2` and `scenario/PERM` pass.
- **A read of another run's approximation joins the runs** (§11.5's `via` mentions, below). When a
  run reads the approximation of a run below it (no group frame between), every run above that one
  is `partial`, and the pass in progress in the run below records a dependency on the slot read, so
  it runs again — re-running the partial runs — when that slot grows. The unit graph is a superset
  of the true mentions for `type`s; for a schema endpoint a `via` target's mentions are known only
  once its group is done, and this makes the fixpoint over them joint all the same.
- **`own_method` is D1's now** (§11.3 *as built by R8b*): a module's value of the method's name,
  `pub` or not.

### 11.3 Private methods (D1, CK-22)

*Amended 2026-09-24 (R0's finding on CK-22). The first text claimed "`M`'s derived `Holder` eq uses
`M`'s private `eq`". Under the module rule no such derived function exists.*

**The module rule is unchanged by privacy** (`static-dispatch-spike.md` §3.3 step 1). A module's
values, `pub` or not, are **one namespace**, so a private `eq` in `M` is `M`'s `eq` for **every**
type `M` declares.
- `M`'s other nominal types get no derived `eq`. Inside `M`, `Holder (T 1) == Holder (T 11)` is the
  module-rule clash: a `type_mismatch`, because `eq : T, T -> Bool`.
- From another module, `M.Holder … == …` reaches `M`'s private `eq`, so it is `private_method`.
- `7427828` already does both, so neither is a finding.

**Inside `M`**, the private `eq` answers every wanted whose `origin` is in `M`. That covers:
- direct `T` comparisons;
- **structural shapes derived in `M`**: `( a, 0 ) == ( b, 0 )` at `T`, a record, a list;
- `M`'s derived rows of structural shapes whose positions reach `T`.

**Outside `M`**, any wanted that reaches `(T, eq)` is `fail(private_method)`: directly, or through a
derived context computed in that other module (a `W M.T`, a tuple, a record, a list). So no
comparison anywhere gives an answer that differs from `M`'s. Where one would differ, it is refused.
That is D1's coherence guarantee, and the part `7427828` gets wrong (CK-22).

`static-dispatch-spike.md` §3.3 and A.63 ("a private `eq` still lets every other module derive")
are superseded.

*As built by R8b (2026-09-26).*

- **The module rule counts a private value.** `Contexts.module_has` is "a value of the name, `pub`
  or not" (`module_pub` says which): no type of `M` derives the method, and P5 writes no row for
  it. `dispatch/PrivateEqStillDerives` loses its `derived … eq` row (`v2-expected.md`).
- **Inside `M`** nothing changes: the private method answers every wanted of `M`'s, structural
  shapes' positions included (`run/PrivateEqInsideModule`, permuted in `scenario/PERM`).
- **The record says so** (§14.2 *as amended by R8b*): the row of a type of `M` is
  `private_method` naming that type, and the row of a type whose context reached another module's
  private method is `private_method` naming the type that module declares (`absent_private`'s
  culprit is a `TypeId`, published as a `type_refs` row). So `C` comparing `B.Wrap`, where `B`
  wraps an `A.T` whose `eq` is private, is `private_method` too — a verdict (`Derivable`) and a
  derivation (`Instances.derivedNominal`) read it off `B`'s row, and a context `C` computes is
  `absent_private` with the same culprit.
- **The absent reason at the use.** A receiver that is the private method's own type keeps v1's
  text (`x.eq`); any other names the private method, the type it belongs to and the value that
  holds it (`Messages.privateMethod`): "This needs the `eq` of `A.T`, which is inside: `Wrap` …
  it cannot be used from here, directly or inside another value." A position of a derived shape
  (a tuple's element, a list's) reports once, at the use, for the lineage root's receiver
  (`Instances.refusePrivate`), as `refuseDerived` does.

### 11.4 The `equatable` marker (CK-16, CK-17, CK-19)

The marker stays what `static-dispatch-spike.md` §3.4 says: a structural guarantee for explicit
`Basics.eq` and `Basics.neq`, and **never** an `eq` method. The resolver never consults it, which
deletes `builtinRigidTarget`'s arm (CK-19). The `equatable` obligation's walk:

- uses `Walk.zig` over `structural` successors: growable and cycle-safe (CK-17). A flex that carries
  an `eq` wanted is therefore not "a function" through its own method type (B1);
- descends, at a nominal `T args`, only into the arguments whose parameter **occurs in a
  constructor payload** (D10). That is `payload_params(T)`, a bitset per type:
  - an own type computes it from its constructors;
  - an imported type reads it from interface v3 (§14.2), so an opaque type's hidden payloads need
    not be read;
  - a `foreign type` has every parameter set, which is today's behaviour.

  So a phantom function argument is fine (CK-23, for the marker). Through payloads that mention
  another nominal type, the walk continues with that type's own `payload_params`. *Revised
  2026-09-24 (S15): "descend into payloads" could not be done for an imported opaque type.*
- **propagates the flag** to a flex it meets inside a structure. It **requires** the flag of a rigid
  it meets, and without it reports `not_equatable` at the obligation's region (CK-16);
- answers `no(function at …)` or `yes`. It has no `unknown`.

*As built by R5, after its review (2026-09-25): `check2/Instances.zig`, the marker walk only.*
- **Where a question is asked, and so where it reports.** The flag is the marker. A question about
  a flagged variable is an `equatable` row, which is created in one of three places:
  - **At the comparison.** A flag from a scheme's quantifier (`Basics.eq : ∀(a: equatable)`)
    that meets a call's argument at the top of the unification makes a row at that argument. So
    `Basics.eq r r` answers at `r`, not where `r` later becomes a record (adversarial review F7).
  - **Where it meets a structure.** A flag with no row that meets a structure makes a row there,
    readied. This is v1's region, which v1's goldens pin; the function passed in a record's field
    to a comparing function is reported at the lambda (`check/bad/EqFunctionFieldThroughCall`).
  - **By the walk.** A flex the walk flags gets a row that continues the walk's own question.

  A row carries its `origin`, the row that asked the question first.
- **When it runs.** A readied `equatable` row is decided at the next boundary's step 1 (§8.1 *As
  built by R5, after its review*). The walk runs over the type the flagged variable then is, at
  the row's region.
- **One question, one message.**
  - The walk writes nothing until its answer is `yes`. Only then does every flex it met get the
    flag and a row of the same origin. A failure leaves nothing behind, so how many flexes the walk
    reached first, which depends on symbol ids, changes nothing (I13).
  - A "no" marks the origin `reported`, and no row of that origin reports again. So one comparison
    whose argument holds two bad parts, or whose flags were merged, says `not_equatable` once.
  - Fixtures: `tests/corpus/check/bad/EqOneQuestionMerged`, `…/EqOneQuestionPerSite`, and the
    symbol-order twins `tests/corpus/check/bad/EqOneQuestionRecord` and `…NamesFirst` (structural
    review B1).
- **Nominal types.** At `T args` the walk first asks the session's gate for `T` itself,
  `Types.isEquatable`: no function anywhere in `T`'s declaration, and a `foreign type` declared
  `equatable`. When the gate says no, it refuses with `opaque_type`, v1's one sentence for both.
  - It then descends only into the arguments whose `payload_params` bit is set (D10).
  - For a type of this module, the bits are computed from its constructors now, with
    `Publish.payloadParams`, the same function P8 publishes with.
  - For another module's type, they are read from its interface v3 row.
  - Every bit is set for a type with no row (a private type reached through an alias), for a
    record not yet filled, and for a schema endpoint: the side that asks more, never less.
  - The answers are memoised per `TypeId` in a dense array.
- **Order.** Tuple elements and application arguments are walked in order, and record fields in
  symbol order. When the walk finds a failure, a second, read-only walk visits every record's
  fields in name-text order to choose the failure it reports.
- **Rigid.** A rigid without the flag is `rigid`: `not_equatable` with v1's "ANY type" sentence
  (CK-16's `same`, at `[ x ]`). A flex whose row is open may meet such a rigid: `unify` binds it,
  and the row reports. A flag with no row meeting such a rigid is `unify`'s own
  `not_equatable_rigid`, at the unification (the direct control `Basics.eq x y`).
- v1's `.equatable` constraint node, dead in v1 (CK-18), has no v2 counterpart.

*Amended by R8b (2026-09-26).*

- **A tagged schema endpoint's gate** is not a declaration's (it has none): for one of this
  module, no function is reachable from its schema's payloads (`Schema.State`'s, a `via` payload
  being its conversion's target as inferred so far), through every other type's own gate and every
  other endpoint's payloads (`Marker.endpointEquatable`), memoised per generation (§11.2); for
  another module's, its hidden row's `is_equatable` (§14.2 *as amended by R8b*), which that module
  wrote with the same function; for an endpoint of a record the old checker wrote, which has no
  hidden row, that checker's own bit (`Types.isEquatable`, v1's settled property — the one read
  of it, and only for the old checker's module, as its ABI is read for its other types).
  `Schema.settleProperties` is no longer on this path.
- **`payload_params` of a hidden type** is read from its hidden row (`Interface.typeFacts`), not
  set to every bit: a private type reached through a published scheme with a phantom parameter is
  walked only where a payload can hold a value. An exported opaque type's row was read already.

*Amended by R8b's review round (2026-09-26), CK-120.* The gate of an `adt` is not the table-build
bit any more: it is "no function reachable from its payloads" (`Marker.functionFree`), walked
through this module's `type`s and schema endpoints (their `via` targets as inferred so far) and
the gate of every other module's type — its record's `no_function` (§14.2 *amended by R8b's
review round*), or the old checker's table bit for a record it wrote. Memoised per local type in
`Contexts` per generation (for good in a module without schemas); a walk that finds no function
proves it of every type it met. The table-build bit could not see a `via` target, so `==` on a type
wrapping such an endpoint was refused and `Basics.eq` on it accepted. The gate is the same fact the
derived contexts read for `==` (a function reachable), asked structurally; the marker walk has no
second opinion.

*Amended by R8b's round-2 review (2026-09-26), CK-120.* "No second opinion" held only for
schemas already done: `functionFree` did not demand the schemas it walked, so an unchecked
schema's unfilled `via` target read as "no function" and was memoised — `Basics.eq` on a type
holding it was accepted or refused by declaration order, and one in flight was accepted where `==`
refused. Now `functionFree` takes the solver and first `complete`s the graph around the type, which
demands every schema with a `via` the walk can reach; if one is still in flight the gate is
UNKNOWN and nothing is memoised. An unknown gate lets the walk pass for now and is asked again of
the type in P5, when every group is done (`Contexts.deferred_gates`, `checkDeferred`): a function
then is `not_equatable` at the obligation's region, once per question. After P4 (publication)
every group is done and the graph complete, so the gate is always known there.

### 11.5 Schema endpoints (CK-24)

A schema endpoint type is a nominal type whose payloads come from the plan. Its derived context is
computed by the same §11.2 function, and its exclusions are that function's `absent`. A wrapper
around it asks the same memoised question, so it inherits the answer. `Schema.settleProperties`
and its per-group calls are deleted. The schema **plan**, which needs the endpoints' properties,
reads them from the memo in P9.

*As built by R8b (2026-09-26).*

- **A tagged endpoint is a unit member** of `Contexts` like a `type` (`derives`): the program and
  the encoded endpoint are two nominal types. A record endpoint is an alias; its expansion answers
  wherever it is met, as any alias's does.
- **Its payloads** are its schema's (`Schema.State.payloads`, in variant order, a variant with
  none holding nothing), written over the schema's generalised parameters and read in the pass's
  frame with the markers for them (`Instantiate.substitute`). A `via` payload is its conversion's
  target.
- **Mentions.** A schema's references are its payloads': another tagged schema's two endpoints, a
  record schema's own references. What a `via` target mentions is known only once its group is
  done, so it is no edge; the lazy join of §11.2 *as amended by R8b* makes the fixpoint over it
  joint (`check/good/SchemaViaMutualOwnType`, `check/bad/SchemaWrapperExclusionThroughOwnType`).
- **Its schema's group is done before a pass reads it.** `Contexts.ensure` demands, from the frame
  that asked and before the unit's frame is pushed, every schema the unit's declarations read
  (its endpoints' own, and every schema their payloads name, through aliases and record schemas;
  in declaration order). A schema group checked nested therefore merges only into the asker's
  frames. A comparison made INSIDE the schema's group — its `via` conversion compares the
  endpoint — cannot read the target being inferred: the entry is `needs_annotation` naming the
  schema, `method_needs_annotation` at the use with its own text ("give the conversion a type
  annotation"), which an annotation on the conversion lifts (`check/bad/SchemaEndpointInFlight`).
- **Every pass gets fresh variables for an endpoint a payload names**
  (`Schema.State.lookupFresh`, the builder `readPayloads` uses): the shared root of an endpoint of
  no arguments let the resolver answer a later pass from an earlier pass's approximation, an
  `internal` in P6. Annotations keep the shared root, so a record endpoint read before its `via` is
  inferred stays linked to it.
- **Derivation** of an endpoint is ordinary: `Instances.derivedNominal` reads its context (or the
  published row), P5 writes its rows (`Eager`), P8 publishes a hidden row for every endpoint a
  published term names (§14.2 *as amended by R8b*). `build` still refuses a schema before anything
  is emitted.
- **The plan's property bytes** (`schema.md` A.6) are read in P9 off the one verdict
  (`Derivable.propertyBits` over each endpoint, after P5 settled every unit): bit 0 when `eq`
  derives, bit 1 when `compare` does, bit 2 when either is refused for a function. Nothing writes
  the session table's schema bits for a module the new checker checks — not the settle, not a
  cache hit (`Incremental.install` restores them for a module the old checker checked only, on its
  side: `Check.restoreSchemaPropertiesOnHit`). `rules_test.zig`'s S4 fence lists the settle, the
  bits' readers and writers and `settleSchemas`; nothing in `src/check2/` names them.
- **An endpoint of a record the old checker wrote** has no hidden row: the importer reads v1's ABI
  for it (derives, one entry per parameter), as for any type of such a record (§14.2 *as amended by
  R8a*). Under `--checker=v2` that is a module of another package, until R9. *R9 (2026-09-27):*
  gone — every record a v2 build reads is v2's, so another package's endpoint has its hidden row
  like any other, and the fallback is deleted (§22.1 *as built by R9*).

*Amended by R8b's review round (2026-09-26).* The two reviews found the lazy `via` join
exponential (CK-119) and three rules to change; each change below replaces the bullet of *as
built by R8b* it names.

- **The unit graph is exact before a unit runs** (replaces *Mentions* and §11.2's lazy join).
  A type that reads a schema with a `via` — an endpoint its own schema, a type a record schema it
  names — records it (`via_refs`). Before `ensure` runs a unit, `Contexts.complete` walks the
  types reachable from it; every such schema it meets is demanded (§10.2) by the frame that asked,
  and once its group is done its `via` targets' own-type mentions become edges of every type that
  reads it, and the walk goes on through them. If an edge was added the units are rebuilt: a unit
  that ran, runs or is memoised keeps its members (every `via` it reaches was added before it ran)
  and its state; members are in ascending order, so a member's slot is stable. P5 completes the
  whole graph first. So no run ever reads another run's approximation, and `partial` and the
  cross-run join are deleted; a cross-run read is `internal` (a Debug panic). Linear in the types,
  edges and payloads reached.
- **A budget that runs out inside a pass is no answer.** A pass whose resolution ran out of the
  step budget, or had a nested check refused at demand, is `absent_budget`, and the use says
  `nesting_too_deep` — never an absent that reads as "does not support". The worklist asserts
  (Debug) that every pass climbs the lattice, and a run past 2²² passes is `internal`.
- **A closed type compared while a schema its payloads go through is in flight is deferred**
  (replaces the in-flight refusal). Only a schema with a `via` can be in flight in this sense, and
  only for a program endpoint or a type naming a record schema: an encoded endpoint holds no
  conversion target and is never in flight. A type with no parameters is answered `present(∅)`
  and the pass records a deferred item, which a memo read replays like a closed in-flight
  method's; an asker outside a pass registers a check of its method on that type at its use,
  made in P5 against the one verdict once every group is done (`Contexts.checkDeferred`): a
  refusal is said there and the use rejected. A type with a parameter keeps the refusal
  (`method_needs_annotation`, whose hint names the conversion when it is a top-level value:
  "annotate `conv`, or compare outside the schema's group"). Rule 7: the refusal is kept only
  where the entries would depend on a type being inferred.
- **Internals of a nested run are said once**, by the outermost run (`sayInternals` of a run
  inside another's pass reported into the same quiet list it read, losing them).

*Amended by R8b's round-2 review (2026-09-26).* Two claims above were wrong, and are corrected:

- **"Linear" was not.** Each `complete` that met a new schema rebuilt every unit, so a module of
  n schemas each compared by its own function was O(n²) in time and memory (8 000: 10.7 s, 11.6
  GB). Now `complete` walks only types not yet `completed` (a type whose every reached schema is
  done and added; a walk stops at one), and merges units locally: the region it walked is the only
  place a new edge can close a cycle (a completed type reaches no type that gained an edge), so its
  strongly connected components are computed there, and each one that spans several units becomes
  one new unit, the old ones retired. Unit ids are never renumbered; `ensure` walks the members'
  edges, not a precomputed dependency list; P5 invalidates every result not memoised permanently
  and `ensure`s each unit. Each type is walked, and each `via` target read, once in the module.
  `test-perf` "CK-119 many" holds it (the comparisons' cost over a control without them).
- **Only what a query reaches is demanded.** The review proposed completing from every local type
  at the first `ensure`. Not done, and recorded: demanding every schema from whichever group first
  compares anything would nest a schema whose `via` depends on that group, merging them (§10.4),
  where another declaration order — the schema checked first — would not; that is an order
  dependence in acceptance (I9). A demand that follows what the comparison reaches is made in
  every order where that comparison is checked.
- **A run has a step budget of its own** (S1): what a type derives is the type's, not whoever
  asked first. `run` saves the resolver's count, runs from zero, and restores it. A result with an
  `absent_budget` entry is never memoised (P5 computes it again), and one that survives to P8 is
  `internal`, not a published `unanswerable` (CK-125).

*Amended by R8c (2026-09-26, CK-122).* **An alias of an endpoint is the endpoint.** "Its expansion
answers wherever it is met" held for a record endpoint written directly, but not for a `type
alias` whose body names an endpoint (`type alias RW = R.Type`, `List R.Type`, a record of
endpoints): the alias body is read by a reader of its own (`Types.Builder.aliasBody`), and that
reader had no schema lookup, so the body was a silent `err`. A comparison of it was an `internal`,
a wrapper of it a false `not_equatable`, and any other use a hole (`r + 1` checked). The rule, in
the shared reader and so for both checkers:

- the body of an alias declared by the module being checked is read with that module's schema
  lookup (the caller's: `lookupOpaque` for an annotation, `lookupFresh` in a pass);
- the body of another module's alias names that module's schema by declaration; the endpoint is
  read from its member scheme in that module's interface (`Types.schemaMemberOfDecl`), exactly as
  `Other.R.Type` written in the importer is;
- a **private** schema is in no interface. Its tagged endpoints are nominal, whole in their
  `TypeId`, and read as such. A private **record** schema's endpoint has no shape outside its
  module — the interface carries no alias bodies (`checker.md` §7's `alias_body`) and no private
  schema — and is still a silent `err` in an importer: CK-126, pending, whose fix is an interface
  row, not a reader rule.

The interface is unchanged: an alias row never prints a body (`alias RW`, like `alias Q` for
`type alias Q = P`); a record alias's row prints only its constructor.

---

## 12. Evidence and elaboration

`check2/Evidence.zig`, about 500 lines.

### 12.1 Canonical order, one function

`Evidence.requirements(scheme) → []Requirement{ quantified, var_name, method }` computes the list
of a scheme in `static-dispatch-spike.md` §7.2's canonical order: quantifiers in `Schemes.Writer`
discovery order, then method name text. It is **the same function** for:

- promotion (§9.4), which writes `DeclInfo.requirements`;
- local instantiation (I5);
- `Schemes.Writer`, which writes the interface `where` blocks.

An importer reads the list in stored order. Because exporter and importer derive it the same way,
they agree (Roc's property 1).

**Quantifier discovery order is v1's** (N10). The writer discovers quantifiers by a
`Walk.structural` walk of the scheme's body, in v1's order: fields by text, parameters left to
right. Only then does it write each quantifier's constraint types. A variable reached only through a
constraint's method type is not a quantifier. §2.4 of the spike (A.21) requires every variable of a
constraint type to occur in the annotated type, and the same holds for an inferred scheme, whose
constraints ride on its own quantifiers.

The `owned` edges therefore cannot reorder the list. R6's exit criteria include a byte comparison of
every `core` and corpus interface's `where` blocks under both checkers.  *Added 2026-09-24.*

*Amended by R15-fix-A (2026-09-28, CK-135, I4).* The walk behind the list
(`Schemes.quantifierOrder`'s `orderWalk`) recursed and stopped **in silence** at the writer's
depth, 512: a variable 2^10 tuple levels down was left out of the order while `Instantiate`
counted its requirement, and an instantiation's requirement was paired with no wanted. It is an
explicit-stack preorder with no cap — a node marked when popped, its successors pushed in
reverse, which is exactly the recursive order. The writer keeps its bound: a type too deep to
WRITE is `nesting_too_deep` (§14.1), and the declaration fails, so the two can disagree only on a
scheme that is never published.

### 12.2 Elaboration (P6)

For every instruction with `inst_callee` or `inst_evidence`, P6 follows each wanted's answer,
through `alias` chains, and writes a `Dispatch.Term` tree (§13):

- `param(binder, k)` → `param`, after checking that `binder` encloses the instruction;
- `top`, `ext`, `derived`, `ext_derived` → the same node with its `args` elaborated recursively;
- `primitive`, `undetermined`, `field` → leaves;
- `group_call(d)` → `top(d, args)`, per §12.3.

**An `open` or `ready` wanted at P6 is `internal`**, and never a structural answer (I6).
A `failed` wanted means an error was reported, so the module has errors, the backend never runs,
and P6 writes nothing for that instruction.

*Amended by R15-fix-A (2026-09-28, CK-141).* "An error was reported" did not mean "this module
reported one". A dependency's `<error>` value (a type error or a NAMING ERROR in `A`, the
ordinary state of a project being edited) is `err` in its importer, and a wanted on it failed in
silence (§9.2's `err` row) in a module that reported nothing — so P6's `internal` and the I7
assert, both gated on "no error in this module", fired: a Debug panic, INTERNAL ERRORs in
release. A wanted rejected against `err` is therefore its own state, **`poisoned`**
(`Evidence.State`), distinct from `failed` (rejected with this module's message, or as its
consequence). It is set by §9.2's `err` row, by `Solve.poison` for the open wanteds riding on a
variable it poisons, when a published derived row's scheme is `<error>` (§14.1 *amended by
R15-fix-A*), and for a dependency's `unchecked` row; its lineage is poisoned with it, and an
ancestor already rejected keeps its own state. Every reader that asked "rejected?" asks
`State.rejected()` (either state). P6 writes no site for a poisoned wanted, reports nothing, and
returns the instruction (`Elaborate.Output.poisoned`); `Module.assertEvidence` does not hold
those instructions to I7. This is sound because the `err` has a message wherever it was made,
so the build that would lower the module stops at that error and never reaches the backend —
and `Lower` still refuses a missing site, the backstop if an `<error>` were ever published
without a message (CK-142 was such a path).

*Amended by R15-fix-C (2026-09-28, CK-169, CK-170): "the `err` has a message wherever it was
made" is made true, and checked.* It was false in one place: `TypeStore.resolved` answered `err`
for an alias chain past 1 024 links — no message, and `err` unifies with anything — so `p == p`
over a 1 200-link chain checked clean and `build` said INTERNAL ERROR, and `String.isEmpty p.0`
over a number built. `resolved` now has no bound (§7.1 *amended by R15-fix-C*). Every producer of
`err` in `src/check` was then audited, and each either reports where it makes the `err` or is
downstream of a message already written:

| Producer | Why its `err` has a message |
|---|---|
| `TypeStore.resolved`'s guard | **removed** (it was the silent one) |
| `Builder.read` past `max_depth` | sets `too_deep`; `readAnnotation` reports `nesting_too_deep`, and so do `Publish`'s constructor reading, `Contexts` (`null` → at the use) and `Instantiate.ownCtor`; `Marker`'s and `Publish`'s second reading of the same constructor arguments are covered by the first |
| `Builder.read`'s other tags, `named` with no type, `apply` at a wrong arity or inside its own expansion, `aliasBody` with no body | an earlier phase reported (unresolved name, parser placeholder, `wrong_type_arity`, `recursive_alias`, `import_cycle`, a parse error): the module is quiet, or the alias's module is a dependency with an error |
| `Builder.named`, a private record schema's endpoint through another module's alias | **not covered**: CK-126, still pending; the check below catches it in Debug (its red is now `crash=ABRT`) |
| `Builder.schemaMember`, `InterfaceTerms`/`Schemes` readers (`.err` term, a scheme `none`, a depth past the writer's bound) | the dependency's message: its publisher reported the `<error>` (§14.1 *amended by R15-fix-A*) or the depth (`nesting_too_deep` at the same bound); an index out of range is a malformed record, which no compiler-written interface is |
| P2 and a `let`'s Elm-curried annotation (`Module`, `constrain/Decl`) | reported at the body (CK-56) |
| `Schema.State` placeholders and malformed-plan rows | never read (a declaration that is not a schema), or the parser/resolution reported; `copyHelp` past 512 levels is the publisher's `nesting_too_deep` for a published endpoint (CK-13) — a private one deeper is a residual for the schema slices, with no runtime path |
| `Solve.poison` | after the report at the same site (mismatch, arity, not-a-function, occurs, escape, `internal`), or on a reference whose scheme is refused (this module's failed declaration, reported) or missing (a dependency's) |
| `Decide`, `Resolve.reject`, `Instances` | after a rejection reported here, or as a `poisoned` lineage (above); inside a derived-context pass (§11.2) a rejection is an answer ("not derivable") on the pass's own variables, which it discards |
| `Unify` (`merge(…, .err)`), `Instantiate` (copy of `.err`) | propagation: one side was `err` already |

**The check** (`Module.assertErrorsReported`, Debug only, as I7's panic is): a module that reported
no error, and whose dependencies — transitively — reported none (`Driver.tainted`, `Input.
dependency_errors`: an earlier phase's error, a poisoned graph node, or a checker error), must end
with no `poisoned` wanted and no `err` reachable from any declaration's or local's type. One walk
over those types. It runs over every gate; on `346268b`'s `resolved` it fires on CK-169's
fixtures. (The whole store is not walked: a derived-context pass leaves `err`s on the variables of
its discarded frames, which are answers, not holes.)

### 12.3 Calls inside a binding group (CK-30, CK-31)

A reference from one member of a group to another, or from a member to itself, or through an
in-flight link (§10.3), does not instantiate a scheme, because the callee is monomorphic in flight.
The solver records it as `group_call(callee)`. After the group's promotion, P6 elaborates it:

**Every member's requirement list** is `Evidence.requirements(member's scheme)`. It is computed
after the group's generalisation from the member's **own** generalised type, reading the `wants` of
the quantified variables that type reaches. It does not depend on which member's body *raised* the
wanted.

In CK-30's `m1b` (`f x y = if x == y then True else g x y`, `g x y = f y x`), `g` raises no wanted
of its own. But its type `a, a -> Bool` reaches the shared `a`, which carries `f`'s `eq`, so both
lists are `[a.eq]`. Several wanteds of one name on one variable are aliases (§4.2), so they give one
entry. *Clarified 2026-09-24 (S2).*

For each requirement `(q, m)` of the callee's **final** list, the argument is found by these cases,
in order:

1. **`q` is quantified by the caller.** Within the group, the callee's `q` is the very variable the
   caller uses, because in-group references share variables. The caller's own list contains
   `(q, m)` at some index `k` of its canonical order, and the argument is `param(caller, k)`.
2. **`q` is quantified by an enclosing binder of the caller** (a generalised constrained `let`
   around the call, D5). The argument is `param(that binder, k)`, where `k` is `(q, m)`'s index in
   that binder's list. §9.4's middle row covers this too.
3. **Otherwise**: `q` is reachable neither from **the site's own member's** scheme nor from an
   enclosing binder. It is then undetermined *for this site*, and the argument is the `undetermined`
   leaf (§13.1).

   This is sound by parametricity. The site's member cannot produce or consume a value of `q`'s
   type except through the callee, and the callee is polymorphic in `q`.

   Round 2's N7 program shows the case: in `f u = if g [] then 1 else 0` with
   `g xs = case xs of [] -> f 0 == 0; a :: _ -> a == a`, `g`'s `a` is quantified by the group
   but is not in `f`'s type. So `f`'s call `g []` passes `undetermined` for `a.eq`, and the list is
   empty.

The case "in the member's type, but not in its list" cannot arise, because of how the lists are
computed above. The elaborator asserts it (`internal`). *Revised 2026-09-24 (round 2, N7): the
first revision sent the N7 program to that assert.*

The number of arguments is the callee's requirement count by construction, and the index is the
**caller's** (CK-31). A requirement answered concretely, such as the `number` bridge or a type found
later, is never promoted. So neither the callee nor the call carries it (CK-30a). A requirement
promoted after the reference was solved is covered too, because nothing is emitted at reference
time (CK-30b).

*As built by R6b (2026-09-25):*

- **What records a group call.** An in-flight member's reference instantiates nothing, so it has no
  `inst_evidence` row; P6 finds it as a `top` reference to a declaration with requirements and no
  row (its site on the applying `call`, §13.1), and an own method answered in flight as the
  `group_call` answer. Both take the callee's FINAL list (`DeclInfo.requirements`, with the roots
  `Resolve.close` recorded beside it), never a count taken at the reference.
- **The caller's list.** Case 1 matches `(root, method)` against the SITE's declaration's list by
  root identity: an unannotated member's roots are what promotion recorded; an annotated member's
  are its givens' rigids, the variables its body was checked against (§6.6), not the P2 scheme's.
  A `promoted` answer is matched the same way, per site. Case 3 answers `undetermined` for `eq` and
  `compare` — at a site root, the structural function itself (§13.1) — and `internal` for any other
  method, which no structural answer can stand for. Case 2 is R14's.
  *As built by R14 (2026-09-27):* a site's binders are its declaration and the promoting `let`
  bindings whose `let_def` subtree holds it (`Elaborate.LetScopes`, from the Bir by
  `constrain/Decl.pushChildren`), innermost first. A `promoted` answer and cases 1 and 2 search
  them innermost first and name the first list that holds `(root, method)`: `param let <inst> k`
  for a `let`, `param k` for the declaration. Case 3's reachability test reads the innermost
  binder's type (the `let`'s header, else the declaration's scheme). A reference to a `let`
  function binding from inside its own group instantiated nothing and is a group call, found as a
  `local` naming a `let_def` with requirements and no `inst_evidence` row.
- **Failure (§12.2 as built).** A wanted whose alias chain ends in a `failed` one is failed (R6a's
  round-2 nit): the site keeps its callee term only, when that is a value (`top`, `ext`), so
  `Cycles` still sees the edge, and in a module that reported nothing it is `internal`. P6 never
  writes a partial tree.
- *Revised by R6b's reviews.* Case 3 is taken only when the site's declaration's type does not reach
  the requirement's variable (`Walk.reaches` over its scheme); if it does, the lists disagree with
  the types and it is `internal` (S1). A `promoted` answer is used only inside the group that
  promoted it, else `internal`. P6's `internal`s are reported with the I7 assert, after the last
  pass that can report an error (S4); an R8a refusal is said at once.
- The CK-30 and CK-31 `run/` fixtures, and CK-66's `GroupVariableOutsideCaller` (case 3), pass
  under v2 with it and are claimed by R6b; R7 keeps the demand-driven half of §10.

*As built by R7 (2026-09-26):* a merged group is one group here: P6 reads each declaration's group
as its merge root (`Module.groupOf`), so a promoted answer and case 1 work across the members of a
merge, and an in-flight member's call is a group call whichever member nested which (§10.8).

### 12.4 Derived bodies

The body of an own derived function for `(T, m)` is one term per constructor argument position. It
is resolved in §11.2's context, and `param(derived i, k)` names the context entries.
`static-dispatch-spike.md` §9.4's emitted shapes (tag switch, padding, order tables, recursion by
name) are unchanged. Only the parameter list follows D4.

### 12.5 One calling convention (CK-33, CK-34)

`check/Convention.zig` is shared by `Cycles`, `Edges`, `js/Reach` and `js/Lower`. It lands in **R2b**
on the old checker, together with the tree record, and is kept.

It needs `value_arity` and `evidence` per declaration in the checker→backend record. Today's
`Dispatch` has no such column, so it rides on R2a's `DeclInfo` record, with its own `dispatch_bytes` bump in R2b (round 3 split). *Moved from R1
2026-09-24 (S8): R1 would have needed its own record change and format bump, and it touches the
same four files as R2.*

```zig
pub const Convention = union(enum) {
    plain,                              // no evidence
    function: struct { evidence: u16 }, // params > 0, or a lambda body, or a zero-parameter value of
                                        // FUNCTION type (its arity is the type's): defined as
                                        // ($m…, $p1…$pn) => …, called flat f(ev…, args…)
    thunk: struct { evidence: u16 },    // zero parameters, NON-function type: defined ($m…) => value,
                                        // every read is f(ev…) — it RUNS at each read
};
pub fn of(decl_params: u32, body_is_lambda: bool, value_arity: u32, evidence: u16) Convention
```

- The checker writes `value_arity` (the type's arity, 0 for a non-function) and `evidence` into
  `DeclInfo`. Every consumer calls `of`.
- `Cycles` treats `thunk` as **running**, not deferring (CK-34), and `function` as deferring.
- `Lower` defines and calls through the same answer, so the definition and the call agree (CK-33).
- `constrained_constant` keeps its scope, unannotated `pub` zero-parameter values, because the
  convention now makes every other form correct.

*Amended 2026-09-24 by R2b, which found these points the text above leaves open (the code is
`src/check/Convention.zig`):*

- **The column is the tag alone.** `DeclInfo.convention` is `enum(u8) { plain, function, thunk }`
  (byte 10 of the `decls` row, `dispatch_bytes` 3). The counts the union above carries are not
  repeated: the evidence is `requirements.len` and the arity `value_arity`, one source each.
  `dispatch_bytes` refuses a row whose convention is `plain` exactly when it has requirements, or the
  reverse. `of` takes `u32` counts and is exactly the three rules above: no evidence is `plain`;
  parameters, a `lambda` body or a non-zero `value_arity` is `function`; otherwise `thunk`.
- **An import has no `DeclInfo`**, so `Convention.ofImport` computes the answer with the same `of`
  from what the interface publishes: `Dispatch.extRequirementCount` and the arity of the scheme's
  body, **looking through `alias` terms** as `TypeStore.paramCount` does for the exporter (CK-84:
  `pub same : Pred a` with `type alias Pred a = a -> Bool` has arity 1 on both sides). It passes 0
  parameters and no lambda, and gets the exporter's answer, because a checked value's parameter
  count, and a lambda body's, is its type's arity. So the interface needs no convention column.
- **A caller's arity** (`Convention.Use.arity`) is the written parameter count when there is one and
  `value_arity` otherwise.
- **The readings are four functions**, and every consumer calls them rather than reading parameter
  counts:
  - `definition(convention, params, body_is_lambda)` → `constant` (plain, no parameters, not a
    lambda: `const f = value`), `params` (`($m…, p…) => body`), `lambda` (`($m…, x…) => e` for a body
    `\x… -> e`, with or without evidence — §8's narrow rule of `backend.md`), `applied`, and `thunk`
    (`($m…) => value`). **`applied`** is the zero-parameter `function` whose body is not a lambda:
    `($m…, $p1…$pn) => body($p1…$pn)` over `value_arity` fresh parameters, the body evaluated at each
    call. When the body is a reference to a constrained function of that arity (`h = maxOf`) the call
    goes straight to it, `maxOf($m$0, $p$1, $p$2)`, not through its eta-expansion.
  - `defers(definition)` for `Cycles`: only `params` and `lambda` defer. `constant` runs at load,
    `thunk` at every read (CK-34), and `applied` is a node that RUNS too (see the review amendment
    below).
  - `call(convention)`: `flat`, `f(ev…, args…)`, for `plain` and `function`; `applied`,
    `f(ev…)(args…)`, for a `thunk`. A thunk's type is not a function, so no checked program calls
    one; the answer is what its definition implies.
  - `referenceArity(use)` for a reference in value position, and for a `top`/`ext` evidence term:
    `null` is the bare name (`plain`), 0 the evidence applied (`thunk`, A.85), and `n` the
    eta-expansion over the arity (`function`, A.25).
- **`Edges` and `js/Reach` read none of these.** An edge is a reference whatever the callee's
  convention, and reachability does not depend on when a body runs, so neither needed a change;
  they are listed above because the brief assumed they did.
- **The wide form is a fifth reading** (spike §9.2, A.87): `derivedEvidence(count)` answers
  `positional` or `array`, and `max_positional_evidence` (4 096) lives in `Convention.zig`.
  `Lower.derivedArrow` and every caller that packs a derived function's evidence ask it; `Lower`
  keeps only the mechanics (the `$m` parameter and the array literal).

*Amended 2026-09-24 by the manager on R2b's review, before the code changed:*

- **`applied` RUNS for `Cycles`; the bullet above that makes `function` deferring is withdrawn for
  it** (review B1). `language.md` §7 states the initialisation rule over the SOURCE: a value
  written without parameters and without a `lambda` body is a VALUE, and may not be reachable from
  its own initialiser. A `where` is a type annotation; it must not change which programs are
  accepted. With `applied` deferring, `h = compose h g` under a `where` was accepted and overflowed
  the stack at its first call, while its twin without the `where` is `cyclic_value` — which is also
  what its twin would throw at load. So `defers` is true for `params` and `lambda` only, and a
  point-free member of a recursive group (`biggest = go` with `go` calling `biggest`) is refused
  exactly as without the `where`; written `biggest = \xs acc -> go xs acc` it defers. `Lower`
  still DEFINES an `applied` value as an arrow: only the cycle reading changed. Fixtures:
  `check/bad/EvidenceFunctionConstantCycle*.beni` (direct, mutual, partial application, through a
  lambda-valued declaration) and the accepted controls `run/EvidenceFunctionRecursionAccepted.beni`.
- **The `cyclic_value` message names the per-use case.** "A top-level value is computed once, when
  the module is loaded" is false for a `thunk` and an `applied` value, which are computed at each
  read or call; when the circle holds one, the message says so and names it. Other circles keep the
  old text byte for byte.
- **An `applied` body is evaluated at EACH CALL, and that is observable** (review S1): a
  `Debug.log` in it prints per call, and a table it precomputes is rebuilt per call, where the same
  value without the `where` computes it once. Kept for now and documented in `language.md` §6
  *Evaluation order*; `run/EvidenceFunctionBodyPerCall.beni` pins the count. Hoisting it once per
  call site is CK-85 (unassigned). *R8a (2026-09-26):* CK-85 is fixed differently — the body runs
  once per EVIDENCE, the last evidence and its value kept in two module-level `let`s
  (`static-dispatch-spike.md` A.85 *as amended by R8a*; `language.md` §6).
- **`constrained_constant` is narrowed to NON-function types** (review S3, rule 7). The bullet
  above keeping its scope assumed only unannotated `pub` values were at risk; an unannotated `pub`
  of function type (`pub equals = (==)`, `pub eqs = \a b -> a == b`, `pub bigger = maxOf`) is
  defined, called and imported as the function it is, so the refusal bought no guarantee. It now
  refuses only a zero-parameter unannotated `pub` whose type is not a function (a thunk). Spike
  §10.10 and the message's hint are amended with it.
- **`boundary.md` §4 check 4 reads `Convention`** (review S2): a `foreign`'s expected parameter
  count is `use.evidence + use.arity`, and "not a function" is `use.arity == 0`, so an alias-typed
  `foreign` is counted as its calls are made.
- **"Is the body a lambda" is asked in one place**, `Convention.bodyIsLambda`, and
  `Convention.definitionOf(dispatch, bir, decl)` is what `Cycles` and `Lower` read (review N2).
  `dispatch_bytes` also refuses a `thunk` row with a non-zero arity (N1), and the flat call sites
  that never meet a thunk (`receiverCall`, `typeDispatchExpr`, `applyEvidence`, `namedPartCall`)
  assert `Convention.call` is `flat` (N3).

---

## 13. The checker → backend contract

### 13.1 The record

`Dispatch` is rewritten (`check/Dispatch.zig`, about 600 lines), and is still flat, index-based,
per module and immutable once built.

```zig
pub const Term = union(enum(u8)) {
    param: struct { binder: Binder, k: u16 },
    top: struct { decl: Bir.DeclIndex, args: Range },          // Range into `args` (term indices)
    ext: struct { module: Graph.Index, value: Interface.ValueIndex, args: Range },
    derived: struct { index: u32, args: Range },
    ext_derived: struct { module: Graph.Index, type: Types.TypeId, kind: Derived.Kind, args: Range },
    primitive: Primitive,                                      // strict_eq | num_compare | char_compare | string_compare
    undetermined,                                              // §9.4's proven-undetermined default, lowered as
                                                               // today's structural answer (`Basics$eq`, or
                                                               // `num_compare` for compare). v2 writes it only on
                                                               // proof; v1's converter (R2) maps a legacy `err`
                                                               // PART to it, preserving today's bytes
    field,                                                     // a callee only
};
pub const Site = struct {
    inst: Bir.Inst.Index,
    callee: TermIndex.Optional,     // `method_call` / `type_dispatch` only
    evidence: Range,                // roots, one per requirement of the instantiated scheme, in order
};
pub const DeclInfo = struct { requirements: Range, convention: Convention, value_arity: u16 };
pub const LetInfo = struct { inst: Bir.Inst.Index, requirements: Range };   // D5 only
pub const Requirement = struct { quantified: u16, var_name: SymbolIndex, method: SymbolIndex };
pub const ContextEntry = struct { param: u16, method: SymbolIndex };
pub const Derived = struct {
    kind: Kind, shape: Shape,
    context: Range,                 // into `contexts`: its evidence parameters (D4); positional for shapes
    body: Range,                    // NOMINAL: one term per constructor argument position; else empty
};
terms: []Term, args: []TermIndex, sites: []Site (ascending inst), decls: []DeclInfo,
lets: []LetInfo (present and EMPTY from R2, so R14 owes no format bump — N6), requirements: []Requirement, contexts: []ContextEntry,
derived: []Derived (sorted by emitted name text, §8.5 of the spike), tries: []Try, symbols: []Symbol
```

**No `err` term exists.** A module with errors never reaches the backend. A module without errors
has every wanted answered (I6).

**`undetermined` is the one structural leaf, and it is not a hole.** v2 writes it only for a wanted
§9.4 *proved* undetermined. Its receiver is reachable from no scheme and quantified by no binder, so
no value of that type can reach the comparison except through a crash (`Debug.todo`, the payload of
an empty list).

During R2–R10, v1 still produces flat sites, and `Dispatch.finish`'s converter maps v1's `err`
**part** to `undetermined`. That is exactly how `Lower` answers such a part today, so emitted
JavaScript does not move in R2. It also keeps CK-20's wrong answer on v1 until v2 replaces v1. That
is deliberate: R2 changes the contract, not behaviour. v1's `err` **site** (not part) maps to no
term, and `Lower` refuses it as `internal`, as it does since row 75.

**`Dispatch.finish`** sorts `derived` and remaps indices, as today. It then walks every term and
asserts I7:
- `top d`: `args.len == decls[d].requirements.len`;
- `ext`: the interface value's requirement count;
- `derived`: `context.len`;
- `ext_derived`: the interface's published context length.

A violation is `internal` at the site.

*Amended 2026-09-24 by R2a, which found these points the text above leaves open:*

- **`DeclInfo` in R2a is `{ requirements, value_arity }`.** `convention` joins it in R2b with
  `Convention.zig` (§12.5), which is also when `dispatch_bytes` goes 2 → 3 (§14.3). `value_arity` is
  the parameter count of the declaration's solved type (`TypeStore.paramCount`), 0 for a
  non-function, filled by v1 and read by nobody until R2b.
- **`Binder` is `decl | let(inst) | derived(i)`.** `decl` carries no index: a site belongs to exactly
  one declaration, the one whose instruction range holds it, and a `param` term inside it names that
  declaration's `k`th requirement. `derived(i)` indexes the SORTED `derived` table.
- **The tree is acyclic by construction.** Terms are allocated in pre-order, so every argument's
  `TermIndex` is greater than its owner's. `dispatch_bytes` verifies exactly that on load, which is
  what lets every walker recurse without a depth guard against a corrupt table.
- **I7 also covers the roots.** A site on a `method_call` or `type_dispatch` has a callee; a
  `derived`/`ext_derived` callee carries its evidence as its own `args` and the site's `evidence` is
  empty, a `top`/`ext` callee has no `args` and `evidence.len` is its requirement count, and
  `primitive`, `field` and `param` take none. A site on a `call` has `evidence.len` equal to the
  requirement count of the Bir callee (a `top` or `ext_value` reference; 0 otherwise), and a site on
  a bare reference likewise for the value it names. A `method_call` or `type_dispatch` site with no
  callee, a v1 `err` site that the converter dropped, and a MISSING site where the Bir needs one
  (a `method_call` or `type_dispatch` with none, a `call` of a constrained callee with none) are
  violations too — the answer `Lower` gives, one phase earlier. **It is not "what `build` would
  say" everywhere:** `Lower` only meets the code DCE (`backend.md` §9) keeps, and the assert walks
  every declaration. So a v1 miscount (CK-30, CK-72, CK-76) in a declaration nothing reaches, which
  built and ran before R2a, is refused by `check` since R2a — `tests/corpus/run/DeadMiscount.beni`
  is that program. The manager kept this on purpose (review of R2a, S1): the table is wrong whether
  or not it is emitted, and v2 removes the miscount itself.
- **The assert runs only on a module that reported no error.** A module with errors never reaches
  the backend, and v1 still leaves `err` sites in one; asserting there would add an `internal` to
  every `check/bad` golden that has a dispatch-bearing error. It therefore runs LAST in the
  module's check — after `fillInterface`, `reportTooDeep`, `Cycles` and the dispatch round trip —
  so an error any of those reports gates it too (review of R2a, S2; `check/bad/CycleNoEvidenceNoise`).
- **Which method an `undetermined` leaf answers** is the kind of the nearest enclosing `derived` or
  `ext_derived` term (or row, for a body position) — exactly the `kind` `Lower` threaded through
  `partValues` before R2a. An `undetermined` with no such ancestor is `internal` in `Lower`: v1's
  converter never writes one, because an `err` SITE becomes no term.
- **`Lower` asserts I7 again**, cheaply, with the same counting function (`Dispatch.requirementCount`),
  and its message is the old "hidden arguments do not add up".

- **During R2–R10 it is `internal` in every build, never a panic.** v1 has known miscounts that
  `check` accepts today: CK-30 is caught only by `build`. A Debug panic in `Dispatch.finish` would
  turn `check` of such a fixture into exit 134 and change the red reasons R0 recorded. R2 greps the
  corpus with the assert on before landing.
- **From R11 (v2 only)** a debug build panics, because a violation is then a v2 bug with no known
  exception.
  *As built by R11 (2026-09-27):* `check2/Module.zig`'s `assertEvidence` panics when
  `std.debug.runtime_safety` holds and `Dispatch.checkI7` names an instruction; a release build
  still reports the `internal` and writes nothing. Nothing in `tests/corpus/` or `tests/pending/`
  reaches it under v2 (every fixture that did under v1 was promoted green), and v1's own assert is
  unchanged (`internal`, never a panic) until R12 deleted it (2026-09-27).

*Revised 2026-09-24 (S10).*

*Amended 2026-09-25 by R6b (spec first, before P6's code):*

- **A term may be SHARED.** The table is a DAG, not only a tree: v2 writes one term per distinct
  answer of a site (the resolver's memo of §9.5 makes a receiver's derived answer ONE wanted that
  later wanteds alias), so `==` on a type that is a doubling DAG — `f x = ( x, [ x ] )` applied
  n deep, CK-80 — is linear in its distinct nodes in `check`. The acyclicity rule is unchanged and
  is still what `dispatch_bytes` verifies: every argument's index is greater than EVERY owner's.
  v2 gets it by writing each unit (a site's callee and roots, or a derived row's body) in reverse
  post-order; a unit without sharing reads in pre-order, as v1's converter writes every table.
  Sharing is within a unit only.
- **A walker visits each term once.** `Dispatch.checkI7` judges every term once, from the last to
  the first (a term is sound when its own count is and every argument is, both already known), and
  `Edges.termsEdges` walks the terms below a declaration's sites, or a derived row's body, with a
  seen set: on a tree both answer exactly as the recursive walks did. `Lower` and the dump still
  EXPAND a shared term at each use: the emitted JavaScript of such a program is as large as v1's
  (exponential in the DAG's depth), which is `build`'s half of CK-80 and unassigned.
- **Where a reference's evidence rides.** A site's instruction is the `call` that applies a
  reference when there is one, else the reference itself (R2a's reading, now stated): P6 moves an
  instantiation's row, recorded at the reference, to its call.

*Revised by R6b's reviews (2026-09-25), before the code changed:*

- **Where an `undetermined` leaf may stand.** `Lower` reads the leaf's method off its nearest
  `derived`/`ext_derived` ancestor (or row, for a body position), so the leaf is legal only below
  such an ancestor, and only in a slot that asks for that ancestor's method. Everywhere else — a
  site root, an argument of a value's evidence (`List.eq`'s element: `[ [] ] == [ [] ]`, B1), or a
  `compare` slot under an `eq` ancestor (CK-103) — the table names the structural function for the
  slot's own method: `ext Basics eq` or `primitive num_compare`. P6 carries each node's nearest
  derived kind (`Unit.Ctx`) and writes the leaf only where it matches the wanted's method. The I7
  assert checks the rule (`Dispatch.checkI7`'s placement pass, each `(term, ancestor kind, slot
  method)` once): a slot's method is its owner's `k`th requirement — a declaration's list, an
  imported scheme's constraints in canonical order, a derived row's context — so `check` refuses
  what `Lower` would. v1 never wrote a leaf without a derived ancestor; it did write CK-103's, and
  its `check` now refuses that program (`internal`), which is harmless at run time (no value of the
  slot's type exists) but a table wrong by its own contract.
- **`Lower` binds a shared evidence closure once.** A term named by more than one owner is lowered
  once per statement list and bound to a `const` (`Lower.termValues`, `hoistEvidence`'s rule: only
  an `arrow` moves), and `Lower.termShapeOk` judges each term once. So `build` of a doubling DAG is
  linear too (CK-80's `build` half; `perf_test.zig` "CK-80 build"). v1's tables share nothing and
  no byte of theirs moves. The dump still prints a shared term at each use.
- **A declaration's edges go through the rows it names** (CK-104). `Edges.declEdges` walks the
  body of every derived row of this module a site names, so emission order (`Lower.siteTops`) and
  the value-cycle check see that a constant calling `Main$W$$eq` depends on the `Main$key` its body
  reads (`backend.md` §5). Both checkers built such a program and it threw at load.

*Amended 2026-09-27 by R14 (D5), before its code:*

- **`lets` is filled**, one row per promoting `let` function binding (§8.4 *As built by R14*),
  sorted by `inst`, each a range of `requirements` placed after every declaration's rows. No format
  bump: the column and its bytes existed since R2a (N6), and `dispatch_bytes` already verifies its
  ranges.
- **A `local` naming such a binding counts its requirements.** `Dispatch.referenceCount` reads the
  reference's declaration (a `local`'s index is the declaration's), and the local's `let_def`; the
  I7 assert and `Lower` both call it, so a `call` of a constrained `let` with no site, or a site of
  the wrong width, is refused as for a top-level callee. The placement pass reads such a callee's
  slot methods from its `LetInfo`.
- **`param let <inst> k`** names the `k`th evidence parameter of the `let_def` at `inst`, which must
  enclose the site; `Lower` spells it `$l<inst>$<k>` (§13.3).

### 13.2 `dump --stage=dispatch`, format v2

```
module <Name>
  decl <name> evidence=<n> convention=<plain|function|thunk>
    requirement <k> quantified=<q> var=<v> method=<m>
  let <inst> evidence=<n>                                   (D5 only)
    requirement <k> quantified=<q> var=<v> method=<m>
  try <inst> <maybe|result>
  derived <i> <eq|compare> <shape> context=<n>
    context <k> param=<i> method=<m>
    body <j> <term>
  site <inst> [callee <term>]
    evidence <term>
      <arg terms, indented two more spaces, recursively>
```

Terms print as:
- `param <k>` inside a declaration, `param let <inst> <k>` or `param derived <i> <k>` elsewhere;
- `top <decl>`, `ext <Module> <value>`, `derived <i>`, `ext_derived <Module>.<Type> <kind>`;
- `primitive <p>`, `undetermined`, `field`.

A tree is printed as a tree, so the pre-order-versus-index discussion of A.68 is gone. The existing
`tests/corpus/dispatch/` goldens are re-blessed **once**, in R2, when the format changes, and
reviewed against the old goldens one by one.

*Amended 2026-09-24 by R2a.* In R2a the `decl` line is `decl <name> evidence=<n> arity=<a>`, where
`arity` is `DeclInfo.value_arity`; R2b appends ` convention=<…>` when `Convention` exists, and
re-blesses the `decl` lines then. Every value declaration prints a `decl` line, in source order, as
in format v1, and a module whose table is entirely empty prints its `module` line alone. A term's
arguments print one per line, two spaces deeper than the line holding the term. A callee's OWN
arguments (a derived callee's evidence) print under the `site` line as `arg <term>` lines, before
the first `evidence <term>` line, so the two keywords keep them apart (review of R2a, N6); below
them, arguments are bare terms.

*Amended 2026-09-24 by R2b.* The `decl` line is now
`decl <name> evidence=<n> arity=<a> convention=<plain|function|thunk>`; every `tests/corpus/dispatch/`
golden moved in its `decl` lines and nowhere else, and `dispatch/Conventions.beni` shows all three.

*Amended 2026-09-28 by R15-fix-B (CK-136).* A table SHARES terms (§13.1 as amended by R6b), and a
tree printed as a tree is exponential in a doubling DAG: `==` on a type 32 levels deep never
finished, and depth 7 of CK-135's program wrote about 2 GB. A term that more than one owner names
(an argument, an evidence root, a body position or a site's callee, counted as `js/Lower.zig`'s
`readTable` counts them) AND that prints arguments under it is printed in full the first time the
dump reaches it, as `<term> #<n>`, and every later occurrence is `<term> = #<n>` with nothing under
it; `n` counts 1, 2, … in print order within the module, so it is as stable as the lines around it.
A term with no arguments prints its one line either way and takes no label, which is why no golden
written before the amendment moved. `dispatch/SharedEvidenceDag.beni` shows the form.

### 13.3 What `Lower` changes

| Today (`js/Lower.zig`) | After R2 |
|---|---|
| `siteRangeOf`, pre-order reading with a cursor, `Site.parent` | `sites[inst]` gives the callee term and the evidence roots |
| `targetEvidence`, `externalEvidence`, `ownEvidence`, `valueEvidence`: recounting | deleted. A term's argument count is in the table; the callee's count is only asserted |
| `evidenceShapeOk` → "hidden arguments do not add up" | the I7 assert. Its message stays for the assert's `internal` |
| `partValue`'s `.err → Basics.eq / num_compare` | becomes the `undetermined` leaf's lowering: same output, a different input. There is no `err`, and a missing site where the Bir needs one is `internal` |
| `declaration`'s zero-parameter branch, `callExpr`'s flat call, `externalArity`, `targetArity` | one `Convention` (§12.5) |
| derived bodies from `Derived.parts` with `evidence k` leaves | from `Derived.body` with `param derived` leaves. Emitters unchanged |
| evidence parameters `$m$<k>` | unchanged for a declaration and a derived function. A `let` binder's are `$l<inst>$<k>` (D5), so an inner binder never shadows an outer `$m$k` it also captures |
| eta-expansion of a constrained value in value position (spike §8.2) | unchanged: computed from the term plus `Convention` |

`Edges.zig` and `js/Reach.zig` walk `sites` and nested `args` instead of flat sites plus `parts`.

### 13.4 What stays in the contract

The primitive table (spike §8.3), the naming and emission order (§8.5), every derived body emitter
(§9), the `?` rows, the operator pinning, and "the backend sees no types".

---

## 14. Publication

### 14.1 One routine (CK-13)

`check2/Publish.zig`: `publishScheme(root) → SchemeIndex` is the only way a solved type enters an
interface. In order it runs `hasError` (three-valued, budgeted, kept verbatim), `writer.add`, the
`too_deep` check, a report on failure, and `<error>` instead of a truncated scheme.

It serves value schemes, schema member types, schema constructor types and constructor terms
(`fillCtorTerms`). Its callers pass a region and a name, and nothing else.

*Amended by R15-fix-A (2026-09-28, CK-142).* A fifth path bypassed it: a derived row's template
scheme (§14.2 *as amended by R8a*) was written with a bare `writer.add`, with no scan and, on
`too_deep`, an `<error>` with no report — so a row too deep to write was published silently, and
an importer comparing through it met an `err` no module had reported. As built, the routine is
`Publish.Publisher`: `scheme(root, decl)` is `clean` (the `hasError` scan; `unknown` is
`nesting_too_deep` at `decl`), `writer.add`, then `written` (`too_deep` is `nesting_too_deep` at
`decl`), and `<error>` on either failure. **Every** write goes through it: value schemes, schema
members and constructors, a row's template (`Facts.templateScheme`, at the type's declaration),
and constructor terms, which write with `addCtor` between the same `clean` and `written` steps.
*Decided:* `ctorTerms` scans. A constructor whose argument reads as `err` (a type that did not
resolve, a wrong arity, a recursive alias: each reported) keeps `no_terms`, so an importer's use
poisons as a whole, and no `<error>` term is ever published inside a constructor's type. An
importer that instantiates a row whose scheme is `<error>` answers the wanted `poisoned` (§12.2
*amended by R15-fix-A*), in silence: its publisher said why.

### 14.2 Interface v3

`iface_bytes.format_version` 2 → 3, `Digest.digest_version` 1 → 2 (R3). The changes:

| Change | Why |
|---|---|
| `Type.arity: u16` (and `Types.Entry.arity`) | CK-38. A saturating `u8` cast becomes an error at 65 535 |
| constructor rows gain `result: enum { nominal, record_alias }`, and a `record_alias` row carries its **field names in declaration order** (a `SymbolIndex` range, argument `i` is field `i`) | CK-39. `Schemes.instantiateCtor` builds the record alias for the second. The names are what the backend needs to emit an imported alias's constructor as the record and to read its pattern's arguments (`backend.md` §4, D12); the alias body's record term cannot give them, because its fields are canonicalised and the constructor's argument order is the declaration's. *Amended 2026-09-24 by R1's review (S6).* |
| per exported nominal type, per `eq`/`compare`: `derived: { present, context: [](param u16, method SymbolIndex) sorted by (param, text) }`, or `absent: reason` *(R8a: every nominal type an importer can reach, and a third word per entry: see the amendment below the table's notes)* | D4, I10: importers resolve `ext_derived` against the published context, and a cache hit installs it without recomputing |
| per exported nominal type: `payload_params: bitset over its parameters` (the parameters that occur in a constructor payload; all set for a `foreign type`) | D10 and S15: the marker walk descends only where a payload can hold a value, without reading an opaque type's constructors  Accepted consequence: a change in which parameters an opaque type's payloads use changes its interface digest (round 2 nit) |
| value `where` blocks | unchanged in bytes. `Evidence.requirements` writes them in the same order as today | (§12.1) |

R3 lands on the old checker, which writes contexts as "one entry per type parameter, method = the
derived method". That is exactly its ABI, so the format is shared by both checkers.

*As built by R3 (2026-09-25).* The points the table left open:

- **Where the rows live.** The per-type facts widen the `types` row (16 → 32 bytes: `arity: u16`,
  then `payload_params`, `eq` and `compare` as `extra` ranges and two status bytes) rather than
  adding a column: one row per exported type, sorted with it. They exist for every exported type;
  an alias's say `alias` and have no bitset. The constructor row grows 20 → 28 bytes (`fields`,
  `result`). `checker.md` §7's serialized-form table has the layout.
- **"Absent: reason"** is a status byte, one vocabulary (settled by R3's review, N1), decided in
  the order v1's eager pass decides (`Solve.deriveOneParts`), the first that applies:
  - `unchecked` — the module was never checked; `alias` — a type alias, not nominal;
  - `present` — the module emits the derived function;
  - `primitive` — §3.2's table answers the method with a JavaScript operator (`Int`, `Float`,
    `Char`, `String`, `Bool` both methods, `Order`'s `eq`; A.18). `Order`'s `compare` and
    `Never`'s two are derived, so `present`;
  - `own_method` — the type's module declares a `pub` value of the method's name: the type's own
    method or, under the module rule (§3.3 step 1), one for another type of the module;
  - `foreign` — a `foreign type` of ANY arity that neither of those answers: no body to derive over
    (A.55; `Schema.Conversion`, of two parameters, is one);
  - `function` — a function is reachable in a payload; `unanswerable` — a payload cannot answer the
    method for any other reason.

  v1 writes `present` exactly when its eager pass (A.23) put the row in
  its dispatch table, with that row's evidence count as the context, so the record states the ABI
  every `ext_derived` is already written against. Nothing in v1 READS the rows yet; R8a's importer
  does, and D4's inferred contexts change the entries, not the format.
- **`payload_params`** is computed from every constructor of the declaration through the
  annotation reader, so a parameter an ALIAS's expansion drops (`type alias Ph a = Int`) is not in
  a payload, and a parameter under a nominal application's argument is. A declaration too deep to
  read (already reported) sets every bit — "may hold a value" is the safe side of the marker walk.
- **The 65 535 error** is a new code, `too_many_type_parameters`, reported by lowering at the
  65 536th parameter (`language.md` §10). The declaration keeps its first 65 535, so no `u16` below
  it ever saturates. Lowering's duplicate-parameter check was pairwise, 35 s of a Debug build at
  that width; it sorts now.
- **`Schemes.Writer` on epoch marks** (CK-41): a slot of the memo is live while its stamp is the
  current epoch, a new scheme is one increment, and the arrays grow at least ×2. The CK-41 scenario
  is the first promoted into `test-perf` (`plans/checker-rewrite.md` §2.5).
- **A gap this table does not close — CK-89.** The rows exist per EXPORTED type, but `==` in an
  importer can reach a PRIVATE type through a `pub` scheme (`pub make : a -> Hidden a`, then
  `A.make 1 == A.make 1` in another module — v1 answers it with `ext_derived` to `A`'s own derived
  function). "Importers resolve `ext_derived` against the published context" has nothing to
  resolve against there. R8a must publish a context for every type a `type_refs` row of the record
  names (the set the dependency digest already uses), or decide otherwise, before v2 reads the
  rows. *The manager assigned it to R8a (2026-09-25): this section is amended first, so the rows
  cover every nominal type reachable from a published scheme, before R8a reads them.*

*Amended by R8a (2026-09-26), before v2 reads the rows (CK-89, D4).* Three changes, and
`iface_bytes.format_version` 3 → 4:

- **Rows cover every nominal type an importer can reach.** An exported type keeps its row on the
  `types` table. Every OTHER nominal type of this module that a `type_refs` row of the record names
  (a private `type` or `foreign type` reached through a `pub` scheme, a constructor term or a schema
  member) gets a row in a new column, **`hidden_types`**, sorted by name text: its name, arity,
  kind, `payload_params`, and the same two derived rows. It is not a declaration: resolution never
  reads the column, so a hidden type stays unnameable by an importer. A type no published term
  names cannot be reached by an importer, so it has no row anywhere. The importer finds a type's
  row by its declaring module and name: `types` first, then `hidden_types`.
  - A module the OLD checker published has no `hidden_types` rows. An importer that finds no row
    reads v1's ABI for that type: `present`, one entry per parameter naming the derived method
    (v1 derives every declared type eagerly). This is the fallback of the importer only, and it
    disappears with v1 (R12).
    *As built by R12 (2026-09-27):* gone. A missing row counts no evidence
    (`Dispatch.publishedCount` is 0, `publishedMethod` null), which the I7 assert refuses as
    `internal`, and `Lower.derivedBodyExists` answers `false`, which is its dispatch-bug wall;
    `Instances.derivedNominal` already said `internal` from R9. No record a build reads can lack
    the row, so nothing in the corpus moved.
  - *Amended by R8a's review round (2026-09-26, CK-110).* An alias body is in no record, so a
    private type reached only through a `pub type alias`'s body was named by no `type_refs` row
    and had no row. The hidden set is closed over this module's own alias bodies (the exported
    aliases, and every alias the writer names), as `cache/Digest.zig` closes its type set. And the
    fallback reads v1's ABI only for a record the old checker wrote: under `--checker=v2` that is
    a module of another package (`Options.usesV2` is a function of the package), so v2 asks
    `Context.oldCheckerWrote`. A record v2 wrote with no row for a type it reaches is `internal`.
- **A context entry is three words: `(param, method, type)`.** `type` is `none` for `eq` and
  `compare`, whose method type is the well-known `a, a -> Bool | Order` of the argument. For any
  other method — the `a.key` a payload's custom method asks for, CK-25 — it is a `SchemeIndex`
  whose body is the tuple `( p₀, …, pₙ₋₁, τ )`: the type's parameters, in order, then the method
  type `τ` the entry requires of parameter `param`. Writing the parameters first fixes their
  quantifier numbers (`Schemes.Writer` numbers by first appearance). An importer instantiates the
  scheme, unifies element `i` with the use's argument `i`, and gives the sub-wanted element `n`
  as its method type — without it, an importer could pass a `key` of any type (a runtime error,
  which the guarantee forbids).
  - *Amended again by R8a's review round (2026-09-26, CK-109).* One scheme per entry repeats the
    n parameters in every entry: a row of n parameters and m methods is n × m entries and
    n² × m scheme words (656 × 100 took 74 s and 3.1 GB). The row carries ONE scheme instead: its
    context range is a leading **row scheme word**, `none` when every entry is `eq` or `compare`,
    else a `SchemeIndex` whose body is `( p₀, …, pₙ₋₁, (τ₀, …, τₖ₋₁) )` — the parameters, then one
    tuple of the method types of the row's non-well-known entries, in entry order. An entry is
    `(param, method, slot)`: `slot` is `none` for `eq` and `compare`, else its method type's
    index in that tuple. An importer instantiates the row's scheme once per use. `verify` refuses
    a range whose length is not 1 + 3k, a row scheme out of range, and a slot in a row with no
    scheme.
- **`own_method` keeps R3's meaning**, "the type's module declares a `pub` value of the method's
  name". A module with a PRIVATE `eq` still derives and publishes its types' `eq` rows, as v1 does
  (`dispatch/PrivateEqStillDerives`): an importer never reaches them (the module rule makes every
  comparison from outside `private_method`, §11.3), and whether they are written at all is D1's,
  so R8b's.

The old checker writes three-word entries with `type = none` (its contexts only ever name the
derived method), so the format is still shared. *(R8a's review round: a row scheme word of
`none`, then entries with `slot = none`.)*

*Amended by R8b (2026-09-26); `iface_bytes.format_version` 4 → 5.*

- **A derived row may be `private_method`** (D1, §11.3): the method is a private method of some
  module, which no other module may use. Its `context` is a range of two words `(type_ref,
  method)`: a `type_refs` row naming the type whose declaring module declares the private method
  (this row's own type when the module's value of the name is private; the type a payload's
  context reached otherwise), and the method's `SymbolIndex` (`Interface.privateCulprit`).
  `verify` refuses any other shape. A row of a module whose value of the name is `pub` keeps
  `own_method`.
- **Tagged schema endpoints get hidden rows** when a published term names them (§11.5 *as built
  by R8b*): name `Schema.Type` or `Schema.Encoded`, kind `adt`, every `payload_params` bit, the
  two derived rows, and `is_equatable` = the endpoint's §11.4 gate (`Marker.endpointEquatable`).
  `Interface.TypeFacts` carries `is_equatable` for the marker walk.

*Amended by R8b's review round (2026-09-26).* A `types` or `hidden_types` row carries
`no_function` (bit 2 of the type row's flag byte, bit 1 of the hidden row's): §11.4's gate for an
`adt`, which an importer cannot compute because a `via` target is in no record. The new checker
writes it; the old one writes `false`, and an importer of its record reads its table bit.
`is_equatable` is again a `foreign type`'s declared bit only (R8b had put an endpoint's gate
there). The raw interface dump prints ` no_function` when it is set.

*Amended by R13 (2026-09-27, CK-116); `iface_bytes.format_version` 5 → 6.* A derived row may be
**`requirement`**: a payload's method exists and has the wrong type for what the context asks of
it (§11.2's `absent_requirement`). Its `context` is `private_method`'s two words, `(type_ref,
method)` — the type whose method it is, and the method (`Interface.privateCulprit` reads both) —
so an importer's message names it (`static-dispatch-spike.md` §10.13); `verify` refuses any other
shape, and the raw interface dump prints `requirement <kind> type_ref=… method=…`. Before, such a
row was `unanswerable`.

### 14.3 Cache and table versions

- `dispatch_bytes` 1 → 2 (R2a, the tree record with `DeclInfo.value_arity`), then 2 → 3 (R2b,
  `Convention`). *Amended by R2a: `value_arity` rides with the tree record, as §12.5 and the R2a brief
  say; only `convention` is left for R2b.*
- `entry_bytes` 2 → 3 (R2a).
- The schema plan stays 1.
- A version mismatch is a miss, as today (`fast-compiler.md` §8.3).
- **The checker is part of the cache key, R4–R11** (S22). v1 and v2 write the same entry format
  into the same `.beni-cache`. After R8, D4 gives a derived function a different evidence ABI
  under v2, so a warm cache must never mix one checker's output with the other's callers.
  - From R4a, the compiler-identity component of the cutoff key (`cache/Key.zig`) includes the
    checker id, `v1` or `v2`.
  - R12 removes the component together with the flag. A single checker needs none, and the build
    id already changes with the binary.
    *As built by R12 (2026-09-27):* `key_version` 5, the own-terms blob back to the build id alone
    (`cache/Key.zig`, `fast-compiler.md` §8). `cache_test.zig`'s row 10b now holds that
    `--checker` is refused (exit 2, nothing written), and the checker-crossing scenario is gone
    with the second checker.
  - A "warm under v2" result in R10 is therefore written by v2 by construction.
  - *As built by R4a:* the id is the text `v1` or `v2`, written as `checker_len: u32, checker`
    right after the build id in every module's own-terms blob, core's included, and `key_version`
    is 3 (`fast-compiler.md` §8). `--cutoff-compare`'s transitive key shares the blob, so it moves
    with the flag too.
  - *R9 note (R4a review, N5):* the text `v2` means "v2 checks the root package, v1 checks `core`"
    from R4a to R8, and "v2 checks everything" from R9. A `--cache-build-id` pins the build id
    across that change, so R9 must also change the id text (say `v2c`) or bump `key_version`.
    Otherwise a `core` entry v1 wrote under `v2` could be read by a v2 that checks `core`.
    *As built by R9 (2026-09-27):* `key_version` 4 (`cache/Key.zig`, `fast-compiler.md` §8); the
    id text stays `v1`/`v2`.
- *R8a (2026-09-26):* `iface_bytes.format_version` 3 → 4 (the `hidden_types` column and the
  three-word context entry, §14.2 *as amended by R8a*) and `dispatch_bytes` 3 → 4 (a context
  entry's `param` is a `u32`, CK-82; and, from R8a's review round, a `param` term's entry index
  `k`, in bytes 8–12 of its row, CK-109). Both are misses of every older entry, as any bump is. A
  warm build after an edit that moves a payload's method rebuilds exactly what a cold build
  writes (`cache_test.zig`, "checker v2: a warm build after an edit that moves a derived
  context …"), and one that moves no interface re-checks the edited module alone.
- *R8b (2026-09-26):* `iface_bytes.format_version` 4 → 5 (a derived row may be `private_method`,
  with its two-word culprit; tagged schema endpoints have hidden rows: §14.2 *as amended by R8b*).
  The schema plan stays 1: its property bytes keep their layout and meaning, read off the derived
  contexts under the new checker (§11.5 *as built by R8b*).
- *R13 (2026-09-27):* `iface_bytes.format_version` 5 → 6 (a derived row may be `requirement`,
  §14.2 *as amended by R13*). Every older record is a miss.
- *As built by R10 (2026-09-27).* No format moves: `iface_bytes`, `dispatch_bytes`,
  `entry_bytes`, the schema plan, the dependency digest and `key_version` are as R9 left them.
  - **Every incrementality scenario runs under v2.** `zig build test-v2` runs `cache_test.zig`,
    `cutoff_test.zig`, `digest_test.zig` and `matrix_test.zig` whole with `BENI_CHECKER=v2`; a
    scenario that compares the checkers names each run's checker, and one whose expectation is a
    legitimate v2 difference asks `World.underV2`. Those differences, all of this section's
    making: `digest_test.zig`'s row 10 (a private type's payload becomes a function) moves
    `Leaf`'s interface HASH under v2, where v1 moves only its digest — the type is reached by
    `make`'s scheme, so it has a `hidden_types` row whose derived rows go `present` → `function`;
    and `cache_test.zig`'s private-`eq` scenario says `private_method` (D1, §11.3) where v1 says
    `not_equatable`. The cutoff table (`cutoff_test.zig`, now pinned) re-checks exactly what v1's
    does on every one of its 18 rows; a 19th, "add a private eq", runs under v2 only, because
    v1's key cannot see it (CK-132, v1 only, frozen): v2 moves the module's hash through the
    `private_method` rows and re-checks the same four modules any interface edit does.
  - **Evidence, not only types.** A dependency's derived context changing — a function payload
    added, a payload's parameter dropped, a payload's `eq` changing its `where` clause, a method
    flipped `pub` ↔ private, a schema `via` target gaining a function or a private `eq` — moves
    the dependency's record, so every dependent is re-checked and re-elaborated; a warm build
    after each such edit writes byte for byte what a cold build writes (`cache_test.zig`,
    "checker v2: an edit that moves a dependency's derived context …", and the adversarial
    review's `k1`–`k8` under both checkers).
  - **I10 on the hit path, as a counter.** `derived_context_runs` (`Check.Counters`, the trace's
    counter of the same name) is the number of unit fixpoints `Contexts.run` ran, summed over the
    modules v2 CHECKED. A hit runs none: `Incremental.install` replaces the record, the table
    and the plan and recomputes nothing. A warm build of a clean project reports 0
    (`matrix_test.zig` asserts it on every warm run of every clean fixture), and so does a warm
    build that re-checks only a module declaring no type while it compares imported ones — the
    rows it reads are the installed records' (`cache_test.zig`, "… runs no fixpoint (I10)").
  - **CK-107** was the dispatch sidecar's writer: `type_refs` and `module_refs` searched
    linearly per row. Both are indexed now; `test-perf` holds it.

---

## 15. Diagnostics and recovery

### 15.1 One emit path, `quiet` once (CK-14)

`Report.emit(diagnostic)` is the only way to append to a module's diagnostics. It:

- drops the diagnostic if the module is `quiet`;
- stamps the declaration attribution;
- sets the failure bit (§15.2) if the severity is `error`.

Schema errors, `verifyReads` and `internalAlways` go through it. The 37 hand-written guards are
gone. `Session`'s `quiet[m]` counts errors only (CK-12, R1).

*As built by R4b (2026-09-25): the texts are v1's functions, staged.* §19 keeps `Diagnostics.zig`'s
texts verbatim, and they live in `Diagnostics.Reporter`'s methods, which append to a list and read
their context (store, Bir, a declaration's locals for a callee's name) from a
`Constrain.Env`. `check2/Report.zig` therefore owns a **staging** `Reporter` that is never quiet,
whose list only `Report` reads, and whose `Env` it fills (`Report.at` sets the declaration a
message is about, and with it the locals the texts name a callee by). Every message v2 raises is a
`Report` method that calls the text and then moves what it staged through `Report.emit`, the one
path to the module's list. The texts §15.3 lets v2 change (§8.2's infinite type, §8.3's escape)
are written in `Report.zig` itself, per `checker.md` §8.5, and v1 keeps its own.

*Revised by R4b's review (2026-09-25, S2, S7).* The shared texts no longer depend on v1's
`Constrain.zig`: `Category` moved to `check/Category.zig`, `Env`, `PlainMethod` and `Monomorphic`
to `check/Env.zig`, and the Tarjan pass (`sccGroups`, `IndexGroups`) to `check/Scc.zig`, all pure
moves that `Constrain.zig` re-exports so v1 reads as before; `Counters` moved from v1's `Solve.zig`
to `check2/Check.zig`. v2 imports neither `Constrain.zig` nor `Solve.zig`
(`check2/rules_test.zig` refuses it). P0's refusal, which runs before P1 builds a `Report`, goes
through `Report.appendTo`, the one path's list half. **Owed by R13:** `Diagnostics.Reporter.env`
narrows from a whole `Env` (whose `dispatch`, `plain_methods` and `monomorphic` v2 leaves empty)
to the fields the texts read. *Done (R12, R13):* R12 deleted `dispatch` and `plain_methods` with
v1, and R13 `artifacts` and `schemas`, which no text reads; `monomorphic` stays, because v2
fills it (§8.4's switch, `Solve.holdConstrained`) and A.30's hint reads it.

### 15.2 Failure is state (I12, CK-11)

`decl_failed: DynamicBitSet` over declarations. The reporter sets the bit of the declaration being
solved, which is the frame's current member, or the wanted's `origin` declaration for resolver
errors. At the group's boundary, if any member failed, **every member** of the group is marked,
because they share variables. **Groups merged by §10.4 are one group for this rule:** a failure
anywhere in the merge marks every member of every merged group (N11). P7 exhaustiveness and the P9
plan gate read the bits. Nothing tests
a diagnostic's region against an instruction range.

*As built by R4b's review (2026-09-25).*
- **Attribution.** A boundary's `infinite_type` goes to its binder's declaration, and an escape to
  the annotated binding's declaration (each `Binder` and annotated binding records it), not to
  whichever member came last. A type too deep to read (`Types.Builder`, the generator's guards,
  a constructor's payload) records its declaration with the note, and the notes are reported at the
  end of P4, so the bit is set before P7 reads it; publication's own notes are reported after P8.
  The group rule is `Report.failGroup`, the bits' one owner.
- **What P7 skips** is a second bitset, `failed_patterns`: the same, except that an
  `infinite_type` does not set it. Exhaustiveness reads no solved type (CK-61), and an infinite
  type says nothing about a pattern, so a `case` beside one is still checked (the review's F9:
  `tests/corpus/check/bad/InfiniteTypeKeepsUsefulness.beni`). Every other error sets both.

### 15.3 Stable texts

Every diagnostic code keeps its code and its text, except:
- the CK entries whose fix is the text: CK-48 to CK-59;
- `rigid_mismatch`'s escape variant (§8.3);
- `try_shape`'s legs (§8.6);
- `infinite_type`'s rendering (§8.2).
- the D14 hint on its `type_mismatch` (§10.7), written in R7;
- the nesting-budget hint on `nesting_too_deep` (§10.2), written in R7;
- a derived-context variant of `private_method`, written in R8b. Spike §10.2's text says "`x.<m>` cannot reach it", but `[ M.t1 ] == [ M.t2 ]` in another module names no `.m`, so the variant names the type and the derived shape that reached it. *(Round 4, S4-2.)*

`method_needs_annotation` is retired except for §11.2's one case (§10.5). Exact wordings are written in
the slice that changes them, blessed there, and reviewed:
- **R4**: the escape and cycle rendering, CK-01 and CK-57 (S20);
- **R5**: `?` legs;
- **R6**: `.where_clause` and `.method_signature`;
- **R7**: the recursive-dispatch hint;
- **R13**: the rest.

### 15.4 Regions and categories

- The resolver reports at `w.origin`, the instruction in this module (spike §6.2's promise).
  `s.region` is gone (CK-48).
- Unification categories gain `.where_clause`, `.method_signature` and `.try_leg(enclosing |
  subject | error)`. Their messages name the clause or leg (CK-55, CK-51).
- The module-rule clash hint is printed only when the module declares at least two types and the
  method's first parameter names a different one (CK-52). CK-49, CK-50, CK-53, CK-54, CK-56, CK-58,
  CK-59 and CK-60 are R13's, written against this reporter.

---

## 16. Exhaustiveness, cycles and the schema plan

- **`Exhaustive.zig` is kept verbatim.** Only its gate input changes, to failure bits. CK-61
  corrects `checker.md` §6.6's sentence about solved types.
- **`Cycles.zig`** is adapted to `Convention` and the tree walk. Its algorithm and messages are
  unchanged.
- **The schema plan** is built in P9 after `Cycles`, gated on "no error in the module", and reads
  endpoint properties from the §11 memo.

---

## 17. Determinism (rule 5)

Unchanged across modules: ids before threads, one writer per slot, concatenation in graph order.
Within a module, every order the checker chooses is one of these:

- SCC order, tie-broken by source;
- demand order for nested checking (§10.2), which is the order of the demanding constraint nodes, a
  function of the source;
- ascending `WantedId`, which is creation order, a function of the tree walk, which is a function
  of the source;
- name text for fields, requirements and contexts (I13).

The `--jobs=1` versus `--jobs=8` determinism test and the matrix test run under `--checker=v2` from
R9 (§22).

*As built by R9 (2026-09-27):* `zig build test-v2` runs, beside the corpus, the `--jobs`
determinism scenarios with `BENI_CHECKER=v2`, selected by name from `blackbox_test.zig` (every
test named "… --jobs=1 and --jobs=8": the streams, the interface record, the dispatch table,
resolution, the graph dump, an unreadable file), `build_test.zig` ("byte-identical at every
--jobs", with and without cross-module evidence) and `abuse_test.zig` (the 600-module and the
5 000-module scenarios); `world.zig`'s `checkerFlag` adds `--checker=v2` to each `build`, `check`
and `dump`. All pass with `core` under v2. The matrix test is R10's.

*As built by R10 (2026-09-27):* `test-v2` also runs the four incrementality files whole —
`cache_test.zig`, `cutoff_test.zig`, `digest_test.zig` and `matrix_test.zig` (§14.3 *as built by
R10*). The matrix's cold-with-cache and warm runs, at `--jobs=1` and `--jobs=8`, are byte-identical
to the plain run for every checker-driven fixture under v2.

---

## 18. Performance

**Budget.** `fast-compiler.md` §2 asks for more than 250k LOC/s per core for checking. At
`7427828` the check phase of `zig build bench -- --generate=100000` runs **55.2 ms**, about 1.8 M
LOC/s. The diary's last entry (2026-09-24 00:17) records the dispatch-heavy medians the rewrite is
held to, ReleaseFast, `--self-profile`, median of 7:

| Program | ms |
|---|---|
| `s_tup6000` | 21.7 |
| `s_int6000` | 15.7 |
| `gen` | 76.0 |

**Rule.** v2 must be ≤ 1.10× each of those at R9 (the `test-v2` parity slice) and at the cut-over
(R11). It must be linear on the three perf scenarios (CK-40, CK-41, CK-42). R12 re-measures after
v1 is deleted.

**What gets cheaper**

- No speculative probes (`TargetProbe`, `localMethodAcceptsApplication`, commit copies).
- No repeated capability settles: up to eight per module today.
- No per-group schema settling.
- No site-list copying on join (aliases instead), and no quadratic `siteOrigins`/`appendSite`
  de-duplication.
- An O(1) own-name index instead of linear scans.
- Epoch marks instead of memsets.

**What gets dearer, and how it is bounded**

- **Occurs at every binder** (§8.2). One walk per `binders_end` node or boundary, over the binders'
  reachable graph (`structural`), with a shared epoch, so each node is visited once per walk. Nested
  `let`s and nested lambdas revisit outer structure once per nesting level, the same cost Elm pays.
  R4 measures three things:
  - `bench`;
  - a 5 000-lambda flat scenario;
  - **a nested scenario**, 200 `let`s deep, each binding a 50-field record type built from the one
    above it. This is the quadratic case (S4). If it exceeds 3 % of the check phase, the fallback is Elm's exact placement, occurs only
  on binders whose variable was unified since the last boundary, which the journal can tell.

  *As built by R4b (2026-09-25): measured, and the fallback taken.* Method: two ReleaseFast
  compilers from the same tree, one with every v2 occurs walk switched off, `check --checker=v2
  --no-cache --jobs=1 --self-profile`, the sum of the root package's `check` events (core is v1's in
  both), runs interleaved, median. Three programs, generated by the R4b slice's scratch scripts and
  described in `plans/checker-rewrite.md` R4b *As built*: **bench** (a dispatch-free 131 127-line
  corpus of 90 modules), **flat** (5 000 declarations, each a lambda over a `case`, 55 000 lines) and
  **nested** (one declaration 200 `let`s deep, level *i* binding a 50-field record whose field `p`
  is level *i − 1*'s, so each level's type holds every level above it).

  | Design (each a median) | bench | flat | nested |
  |---|---|---|---|
  | as §8.1 was written: binders + `touched`, 7 runs | 102.8 vs 91.9 ms, **+11.8 %** | 24.6 vs 22.3 ms, +10.4 % | 183.4 vs 158.6 ms, +15.6 % |
  | + no walk into a leaf, fewer binder walks, 7 runs | 98.2 vs 92.3 ms, **+6.4 %** | 23.4 vs 22.6 ms, +3.5 % | 162.3 vs 154.5 ms, +5.0 % |
  | **as built** — binders only (§8.2's fallback), 15 runs | 94.2 vs 91.7 ms, **+2.8 %** | 22.4 vs 21.5 ms, +4.5 % | 163.9 vs 159.6 ms, +2.7 % |

  The `touched` walk was the larger part (about 4 % of bench on its own), so it went (§8.2, *As
  built by R4b*). What is left on **flat**, just over the line, is `binders_end`'s own walk of each
  lambda's and branch's binders — the placement CK-04's expected output needs — on a program that
  is nothing but lambdas. The nested case is not quadratic in the occurs walk: one boundary walks
  its header's type once (a shared epoch), so 200 levels cost 200 walks of a type growing by 50
  fields a level, 2.7 % of a check the copying of those same types dominates.

  *Re-measured after R4b's review (2026-09-25), and the flat case accepted (S9).* After the review's
  changes (coinductive `unify`, the error path's cycle search), same method, medians of 15 and 21
  runs: bench **+0.3 % and +4.8 %**, flat **+6.0 % and +5.6 %**, nested **+5.4 % and +4.1 %**. Two
  byte-identical binaries measured the same way differ by up to **3.4 %** (flat) and 1.5 % (nested),
  so the line is inside this machine's noise, and the walks that remain start at binders whose
  types are almost all leaves (a leaf costs a `find` and a tag test). The flat case is **accepted
  over the line** rather than reduced: what it measures is `binders_end` after every lambda and
  `case` branch, the placement CK-04's expected output needs (`(\y -> y y) "s"` is
  `infinite_type` at `y` before `"s"` meets it), on a program that is nothing but lambdas and
  branches; the only reduction left is to drop that placement. The manager may overrule.
- **`Walk.owned` yields constraint method types, and attaching lowers them (I15).** A variable's
  `wants` is almost always empty, so the cost is one branch. An attachment walks a two- or
  three-node method type.
- **The settle loop** (§8.1) re-runs until nothing changes. Each iteration after the first is
  triggered by a default (§8.1 step 3), so there are at most three iterations of O(pool) each. Eager
  draining after each constraint node is linear in the number of readied items.
- **Obligations ride on their variables** (§4.5). Each is attached once, readied at most once and
  closed at most once.
- **Rank adjustment runs once per settle iteration** (§8.1 step 2). A second iteration happens only
  after a default, and there is at most one round of defaults per `?`. In practice there are at most
  two iterations.
- **The I15 debug assert** checks only what the boundary's own generalisation walk meets, so it is
  linear even in Debug, and cannot flake the performance ratios (S-new-6).
- **Elaboration (P6)** is linear in sites plus terms.
- **The derived-context fixpoint** iterates at most (#params × #methods) times per type-level SCC,
  and the typical SCC has one type and one iteration.
- **The resolver's cycle checks** *(noted by R6a's review, 2026-09-25)*. Two walks guard
  §9.5, and none is free. (The first round's `repeatsAncestor` and its `Walk.reaches` are gone:
  round-2 review, N1.) `Instances.cyclic` runs one occurs walk from every structure receiver
  resolved; `Instances.derivability` walks a receiver's pairs once per derivation, and a ground
  pair once per module. On a DAG each is linear in the distinct nodes it reaches, but they are run
  per wanted, so a derived chain of depth *d* costs O(*d*²) node visits — the parser bounds *d*,
  and a type's distinct nodes are few in practice (CK-80's depth-24 doubling DAG and the
  alternating-boundary DAG of `perf_test.zig` stay flat). If a profile ever shows them, the
  first fix is to run `cyclic` only for a readied wanted (an immediate one's receiver was checked
  when it was bound).

*As built by R8c (2026-09-26): the per-operation overhead, and the last bullet above.* R8a's
structural review profiled v2 at 1.15× v1's cycles on the generated corpora — the same work done
dearer — and R8b's tree read 1.07–1.08× in whole-process cycles. Each change below was measured
on its own (ReleaseFast, `perf stat -r 11`, whole process, `check --no-cache --jobs=1`, both
`zig build bench -- --generate=100000` corpora, two interleaved rounds; the table per change is
`plans/checker-rewrite.md` R8c's *As built*):

- **Rank adjustment** (§8.1 step 2), the largest. A node's `owned` successors are read in one
  decode (`Walk.eachOwned`) and pushed on a stack, not re-decoded once per successor through a
  cursor; a successor that can be answered at once — a node that is not young, or a young leaf
  with nothing riding on it — is answered from its parent's frame, as Elm's recursion answers it
  (neither answer depends on what the walk has seen, so taking it early changes no rank); a pool
  of one rank skips the counting sort; and step 2 leaves only roots in the pool (`adjustRanks`'
  `compact`), so steps 4–5 do not `find` merged-away variables again (a frame handed down keeps
  its pool whole). About −37M instructions and −15M cycles on the dispatch corpus.
- **Unify**: the pair stack's bounded scan (§7.3 *amended by R8c*), a flex-flex join with nothing
  on either side merged directly, `reportJoins` skipped when there is nothing to report. About
  −5M instructions.
- **P6** builds no call map in a module with no evidence rows and no group call, and a dense one
  otherwise (it hashed every `call` of every module). About −6M instructions.
- **§18's last bullet came true** as CK-111: a record nested *d* deep compared once was O(*d*²) in
  the derivability walk and in the cycle test; both are linear now (§8.2 *amended by R8c*,
  `Resolve.State.derivable_open`). CK-93's `let` chain is linear to check (§8.2). The proofs
  both need cost about 1 % of instructions on the corpora against a build that keeps none (after
  the review round's fix, §8.2 *as restated*).
- **Not done**: per-group memoisation of imported schemes (the review's 1 %): an instantiation
  makes fresh variables per use, which a memo would copy anyway, and the profile puts v2's
  instantiation within 1 % of v1's.

Result, R8c's tree after its two review rounds, v1 from the same binary, two rounds: the plain
corpus 1.031–1.033× v1 in cycles (493 / 478M) and 1.03× in task-clock; the dispatch corpus
1.054–1.058× in cycles (542–543 / 513–514M) and 1.056–1.058× in task-clock — over R8c's 1.05×
target by choice: the broad `err` rule (§8.2) costs 0.8 % of instructions, and R9's budget is
1.10×. The parent read 1.05–1.06× and 1.08× in cycles. The four phases after
P4 have events of their own (§5 *as built by R8c*): on the dispatch corpus `derived`, `elaborate`,
`publish` and `finish` take about 2, 4, 8 and 4 ms of v2's 100 ms of `check` (wall, the root
package's modules).

*As measured by R9 (2026-09-27), with `core` under v2.* ReleaseFast, one binary, v1 and v2 by
`--checker`. Two changes of R9's, both in v2 only: the store reserves three variables per
instruction (it reserved one, and grew two or three times, a copy each; `Module.zig` P1), and the
derivability walk keeps its first 16 colours inline and neither colours nor memoises a node with no
successor (`Derivable.Colours`, `isLeaf`).

| Measure | v1 | v2, `core` under v2, before the two changes | v2, R9 | R9 / v1 |
|---|---|---|---|---|
| plain corpus, whole process, `perf stat -r 11` cycles, two rounds | 475–478M | 494–496M | 494M | 1.036–1.040 |
| dispatch corpus, the same | 510–511M | 545M (core under v2; 542–543M under v1 at R8c) | 538–540M | 1.055–1.058 |
| plain corpus, `zig build bench … --checker=` check phase, three rounds, median | 93.2 ms | 101.2 ms | 97.9 ms | 1.05 |
| dispatch corpus, the same | 101.3 ms | 111.9 ms | 111.0 ms | 1.10 (rounds 1.06–1.12) |
| `s_int6000`, sum of `check` events, median of 7 | 16.9 ms | 19.3 ms | 18.0 ms | 1.07 |
| `s_tup6000`, the same | 29.7 ms | 55.6 ms | 47.0 ms | **1.58** |

`s_int6000` and `s_tup6000` are the diary's programs rebuilt (6 000 declarations of `a < b`, and
of `( a, [ b ] ) < ( b, [ a ] )`, over `Int`); the dispatch corpus stands for `gen`. `s_tup6000` is over
the rule, and was before R9 (1.89×; `ed61b07`'s binary, `core` under v1, read 1.54× in whole-process
cycles): no slice had measured it since the diary's entry. It is
CK-131, recorded with its profile; the bench's own figures (whole process and check phase) are
within 1.10×. `zig build bench` gained `--checker=v1|v2` for the check line (R9).


*As measured by R9b (2026-09-27): CK-131 fixed.* The same method as R9's: ReleaseFast, v1 and v2
by `--checker` on one binary (v1 is frozen, so v1 is `919f8be`'s), `check --no-cache --jobs=1
--self-profile`, the sum of the `check` events, median of 7, all binaries interleaved; the whole
process by `perf stat -r 11`. The programs are R9's, and `perf_test.zig`'s `CK-131` scenario now
keeps their generator: `s_tup6000` (6 000 of `( a, [ b ] ) < ( b, [ a ] )` over `Int`),
`s_int6000` (`a < b`) and, from R9's review, the tuple of two `Int`s (`( a, b ) < ( b, a )`).
Each change was measured on its own and kept only if it paid; each row adds one to the row above.

| Change | `s_tup6000` ms (× v1) | pair ms (× v1) | `s_int6000` ms (× v1) | `s_tup6000` cycles / instructions, M |
|---|---|---|---|---|
| v1 | 29.7 | 25.7 | 17.6 | 146.7 / 408.5 |
| v2 at `919f8be` | 47.6 (1.60) | 33.6 (1.31) | 18.5 (1.05) | 209.1 / 565.6 |
| (a) a table primitive whose method type already is `root, root -> Bool\|Order` answered in `Resolve.step` (§9.3 step 1 *amended by R9b*) | 45.3 | 30.9 | 17.2 | 200.8 / 542.2 |
| (b) the plain-method fast path (§9.3 step 4 *amended by R9b*) | 37.8 | 31.2 | 17.5 | 178.1 / 482.3 |
| the ground derivability memo a dense column (§9.5 *amended by R9b*) | 36.7 | 29.6 | 16.9 | 171.1 / 475.3 |
| `unifyWellKnown` skips a method type of that shape (a use's operands) | 36.1 | 28.4 | 17.2 | 168.3 / 464.9 |
| (c) derivability kept by ground shape, per module (`Derivable.Shapes`) | 33.5 | 27.8 | 17.2 | 162.5 / 455.2 |
| P6's unit memo searched inline below 16 keys (`Unit.wanted`) — **as kept** | 32.5 (1.09) | 28.1 (1.09) | 16.5 (0.94) | 161.4 / 453.7 (1.10 / 1.11) |

Not kept, for paying nothing measurable: a multiplicative hash for `Resolve.State.derived`, and
that memo as a dense column (its map's cost is the misses of a 60 000-entry table, not the hash).
**Measured and declined** (the manager, 2026-09-27): skipping §9.5's cycle test for a receiver
whose ground encoding is bounded and met no alias. It measured 32.7 ms (cycles 159.9M, about
−1 %), and it rested on an argument — a bounded preorder expansion over exactly the `structural`
successors cannot reach a cycle — rather than on the walk. R8c's review rounds showed where a
proof that is only an argument for a narrower condition leads (three holes), so the walk stays
and the 1 % is paid.
The final tree (the rows above as kept, the rollback guard of §9.3 added), rounds of the three
programs alone (v1, `919f8be`, R9b), two rounds of medians of 7: `s_tup6000` **1.058× and
1.103×**, the pair 1.093× and 1.047×, `s_int6000` 0.955× and 0.954×; whole process on
`s_tup6000` 160.8M / 146.3M cycles, 1.10×. The median of `s_tup6000` moves by ±4 % between
rounds on this machine, so it sits on the 1.10× line rather than clearly under it. What is left over v1 on it is no longer the resolver — whose share of the
profile is below v1's — but the constant factor of v2's unification, rank adjustment and P6 on
every declaration, spread thin.

| Measure (R9b measured before the declined cycle-test skip was reverted) | v1 | v2, R9 | v2, R9b | R9b / v1 |
|---|---|---|---|---|
| plain corpus, whole process, `perf stat -r 11` cycles, two rounds | 475–478M | 494–496M | 487–488M | 1.02–1.03 |
| dispatch corpus, the same | 508–509M | 538M | 532–533M | 1.05 |
| plain corpus, `zig build bench … --checker=` check phase, three rounds, median | 93.8 ms | 97.9 ms | 99.8 ms | 1.06 (rounds 1.03–1.07) |
| dispatch corpus, the same | 102.5 ms | 111.0 ms | 107.7 ms | 1.05 (rounds 1.03–1.06) |

The scenario (`zig build test-perf`, CK-131) is v2 against v1 on the module's own `check`
event, best of 5, bound 1.25×: red at `919f8be` (167 %), green on R9b (107 %).

*As measured by R14b (2026-09-27): CK-134 closed.* R12 found the check phase of `zig build bench
-- --generate=100000` at 1.087× (plain) and 1.122× (`--dispatch`) the `7427828` figure. Method:
ReleaseFast binaries of `7427828`, `881e23d` (R14) and R14b; the whole process by user cycles,
`check --no-cache --jobs=1` of the two generated trees, pinned to one core, the **minimum** of 11 to
21 interleaved runs (on this machine the mean of `perf stat -r` moved by up to 7 % between two
copies of one binary; the minimum by under 1 %); the bench's check line, medians of 7 interleaved
rounds. Each change was measured alone twice: against the build before it, and as an ablation — the
final tree with only that change taken out. Every figure below is user cycles unless it says otherwise.

What the profile said. v2 did the same work as v1 (unifications, generalisations and instantiations
within 2 %) with 5 % more instructions and 24 % more branch misses, spread thin: unification,
rank adjustment, P6 and I7's scans each a few per cent over v1, none of them the gap alone. And a
cost no profile of user cycles had shown: every module's type store mapped its own pages
(`std.heap.page_allocator`) and unmapped them at the end — v1's too, but R9's reservation of
three variables per instruction (a capacity of 4.5 after `MultiArrayList`'s growth factor) tripled
it — a fault and a zeroed page for most of what a store touched. Taking it away took a run's
system time on the dispatch corpus from about 44 ms to 24 ms, which the bench's wall-clock
check line counts and `perf`'s user cycles do not.

| Change (kept) | vs the build before, user cycles, dispatch / plain | ablation from the final tree | instructions (dispatch) |
|---|---|---|---|
| a module's owned store carved out of the worker's scratch arena, which the driver resets retaining its largest chunk (`Module.check`) | −34.5M / −26.6M; wall −27 ms, system −19 ms, page faults 18 036 → 9 323 | +33.7M / +27.5M | ±0 |
| an interface term memo stamped per read and kept by the module's check (`Schemes.TermMemo`), where every instantiation of an imported scheme allocated and cleared a memo as long as the WHOLE interface | −2.9M / −2.1M | +14.3M / +10.2M | −19.7M |
| rank adjustment does not enter a pool root an earlier walk of the same pass reached (`Generalize.adjustRanks`): that walk would return its rank and write nothing | −7.1M / −5.7M | +6.1M / +5.7M | −28.2M |
| the empty case of `TypeStore.touchesErr`, `Evidence.mergeRejected` and `Unify.release` tested inline, the rest out of line | −6.1M / −5.8M | +8.3M / +4.3M | −6.0M |
| `TypeStore.fresh` tests capacity inline (`append` called its test out of line) | −3.8M / −3.2M | +4.9M / +3.4M | −7.7M |
| I7's placement pass skipped for a table with no `undetermined` term: `placed` refuses only at one (`Dispatch`) | +2.5M / +3.9M (code layout) | +6.4M / +0.1M | −5.9M |

Measured and **not kept**, for paying nothing the ablation could see: the journal's `record`
inline (−9M in sequence, ±2M as an ablation over 21 runs); `Instantiate.copy`'s first pass through
`Walk.eachOwned` (−3.7M in sequence, −2M as an ablation); an array-of-structs store (one 32-byte
row for `parent`, `rank`, `mark` and `content`; −1 % instructions, cycles within noise: L1 misses
did not move, a module's store fits in L2); `Occurs.check` reading a node's successors in one
decode (+1M instructions); `pool.append` with the capacity test inline (+0.7 %); `Walk.hasError`
and `lowerTo` through `eachOwned` (within noise); reserving two variables per instruction instead of
three (−3 ms system, +1–2 ms user; superseded by the scratch arena, which makes the reservation's
size cost nothing but address space). Priced and left alone: I7 as a whole is 1.5 % of
instructions, and the acyclicity proofs (§8.2) 1.5–1.9 % of cycles; both are guarantees, and no
change here rests on an argument about either — every change is exact by construction (the walks
it skips would write nothing; the memos are keyed and cleared exactly).

Output: a differential over all of `tests/corpus/` and `tests/pending/` (1 124 files and 273
directories, each checked with and without `--platform=node`, each file's `dump --stage=types`,
`interface` and `dispatch`, and dev, `--release`, `--library` and `--library --release` builds;
plus `bench/corpus`) against `881e23d`'s binary: 56 365 output files, **zero bytes changed**; the
two generated trees built `--library` at `--jobs=8` likewise. Peak RSS unchanged (47 MB).

| Measure | `7427828` | `881e23d` | R14b | R14b / `7427828` |
|---|---|---|---|---|
| bench check line, dispatch, median of 7 rounds | 100.0 ms | 110.1 ms (1.10) | 76.0 ms | **0.76** |
| bench check line, plain, the same | 93.7 ms | 99.5 ms (1.06) | 67.1 ms | **0.72** |
| whole process, user cycles, dispatch, min of 11 | 465.3M | 522.8M | 471.9M | 1.01 |
| whole process, user cycles, plain, the same | 438.6M | 477.9M | 428.7M | 0.98 |
| whole process, `--jobs=8`, dispatch, wall, mean of 20, two rounds | 53–64 ms | 62–64 ms | 51 ms | — |

The whole process keeps what v2 costs outside the check line (its `resolve` phase read slower
under `perf` than `7427828`'s, with `Graph.lookup`'s hash no longer inlined; the bench's own
`resolve` line did not show it, so no finding is filed). The ablation column was measured before
the two changes not kept were taken out.

---

## 19. What is kept from the current code

| Piece | Decision | Notes |
|---|---|---|
| `TypeStore.zig`: union-find, Rémy rank, journal, `extra`, roots-only access | **adapted** | `Flags.wants`; epoch marks; `Snapshot` per §7.5 |
| `Solve.unifyFlat`, `unifyRecord` (four-way merge-join), `unifyAlias`, kind lattice | **adapted** | dispatch arms removed; `Result` returned; normalised records; text-ordered failure |
| `Solve.call` and the arity suite (`checker.md` §8.3) | **verbatim** | |
| `Solve.generalize`, `adjustRank`, pools | **adapted** | `Walk.owned`; §8.3 check; switch for rule (a) until R14 |
| `makeCopy` / `copyHelp` | **adapted** | constraint method types through the same memo (they are children); wanteds created by I5 |
| `occurs` (iterative three-colour) | **adapted** | `Walk.structural`, epochs, returns the cycle path |
| `Constrain.zig` per-form rules | **rewritten**, rules verbatim | split into three files; §6.2–§6.5 changes |
| `Solve.zig`'s ~3 000 dispatch lines, and `Types.zig`'s capability walk | **rewritten** | `Resolve`, `Instances`, `Evidence` |
| `Types.Builder` (annotation and `where` reading) | **adapted** | produces givens |
| `Types` session table | **adapted** | capability fields deleted; `arity: u16` |
| `Schemes.zig` writer and reader | **adapted** | `Evidence.requirements` order; derived contexts; ctor result kind; epochs |
| `Check.zig` driver: scheduler, core gate, `claim`/`compareKey`/`publish`/`install`/`verifyReads` | **moved verbatim** into `Driver.zig` and `Incremental.zig` | `install` loses its capability rebuild and reads published contexts |
| `ModuleCheck.run` | **rewritten** | §5's phases |
| `fillInterface`, `fillCtorTerms`, `hasError`, round trips | `hasError` and round trips **verbatim**; the rest into `Publish.zig` | |
| `Dispatch.zig` | **rewritten** | §13 |
| `Exhaustive.zig` | **verbatim** | gate input only |
| `Cycles.zig`, `Edges.zig` | **adapted** | `Convention`, trees |
| `Render.zig` | **verbatim**, plus cycle rendering | |
| `Diagnostics.zig` texts | **verbatim** except §15.3; reporter core **rewritten** | `Report.zig` plus message files |
| `Schema.zig`, `SchemaPlan*.zig` | **adapted** | properties from the §11 memo; plan in P9 |
| `reads.zig`, `Command.zig`, `InterfaceTerms.zig` | **verbatim** | |

### 19.1 The target layout of `src/check2/`

Renamed to `src/check/` at R12. No file over about 1 500 lines.

*As built by R12 (2026-09-27):* renamed; the v2 files and the shared ones are one flat
directory (and `constrain/`), so an import is `"X.zig"` again. `checker.md` §3 *as amended by
R12* lists it by role. Three files were over 1 500 lines and were split, each re-exporting what
it moved so no caller changed: `Diagnostics.zig` 2 174 → 1 431 (`DispatchTexts.zig` 793: the
§10 and obligation texts and the cyclic value), `Exhaustive.zig` 1 590 → 1 453
(`PatternStore.zig` 159: the simplified pattern language) and `Contexts.zig` 1 620 → 1 318
(`ContextUnits.zig` 334: the unit graph and `complete`). The largest files now: `Exhaustive`
1 453, `Diagnostics` 1 431, `Schemes` 1 397, `Contexts` 1 318, `checker_test` 1 294, `Types`
1 257 (from 1 835), `TypeStore` 1 047; `Dispatch` 907 (from 1 747). 30 551 lines in all, tests
included. `rules_test.zig` fences I2 (with the kept files that own, serialise or print a type
listed), the type table's structural bits' readers (S4's fence, its capability half deleted with
the API), and the 1 500-line cap; S2's fence went with v1.

```
check2/
  Check.zig          ~300   public API: run, Module, Options (same shape as today's)
  Driver.zig         ~700   DAG scheduler, core gate (moved)
  Incremental.zig    ~600   cutoff key, claim, publish, install, verifyReads (moved)
  Module.zig         ~600   §5's phases
  TypeStore.zig     ~1000
  Walk.zig           ~400   structural and owned successors, lowerTo, DFS, occurs, recordRow, epochs
  Unify.zig          ~900
  Generalize.zig     ~450   pools, adjustRank, generalise, generality check
  Instantiate.zig    ~350   copy, scheme instantiation, evidence creation (I5)
  constrain/Expr.zig ~800   constrain/Pattern.zig ~500   constrain/Decl.zig ~600
  Solve.zig          ~900   tree walk, boundaries, calls, obligations, `?`
  Groups.zig         ~450   SCCs, effective status, frames, nesting at demand, merge (§10)
  Resolve.zig       ~1100   wanteds, givens, drain, promotion, lineage
  Instances.zig      ~800   module rule, well-known table, matching, derived contexts, privacy, marker walk
  Evidence.zig       ~500   tables, canonical order, elaboration
  Publish.zig        ~500
  Report.zig         ~400   emit path, quiet, failure bits
  Types.zig          ~900   session type table (capability fields gone)
  shared, unchanged path: Exhaustive, Cycles, Edges, Render, Diagnostics (texts), Schemes,
  Schema*, reads, Command, InterfaceTerms, Dispatch, Convention
```

Until R12, `check2` imports the shared files from `src/check/` and does not copy them. (R12: one
directory.)

*As built by R4b (2026-09-25; counts after its review):* `Context` 87 lines (the per-module read
context, no generation state), `Subset` 117 (P0), `Walk` 497, `Unify` 554, `Generalize` 288
(frames, rank adjustment, quantification), `Instantiate` 334, `Solve` 470 (the walk, calls,
boundaries, the generality check), `Report` 367, `Publish` 285, `Module` 421, `constrain/Tree` 341
(the tree and the generator's state), `constrain/Expr` 248, `constrain/Pattern` 133,
`constrain/Decl` 526, and `rules_test.zig` 131. No
`TypeStore.zig` (§4.1 *As built*), no `Groups.zig` yet (R7: the SCC is the shared
`check/Scc.zig`, called from `Module` and `constrain/Decl`).

*Imports from `src/check/` after R4b's review (S2):* `TypeStore`, `Types`, `Schemes`, `Render`,
`Diagnostics`, `Dispatch`, `Convention`, `Cycles`, `Exhaustive`, `reads`, `Schema`, `SchemaPlan`,
`SchemaPlanBuild` (all on §19's KEPT list), the three pure moves `Category`, `Env` and `Scc`
(kept with the texts), and v1's `Check.zig` from `Driver.zig` alone — the checker switch, gone
at R11. Nothing imports `Constrain.zig` or `Solve.zig`, so R12 can delete both with `Check.zig`
(`check2/rules_test.zig` holds the line).

*As built by R5 (2026-09-25):* two new files, `Obligations` 283 lines (§4.5's table) and
`Instances` 221 (§11.4's marker walk only; lookup and matching are R6a's). `Solve` grew to 878
(obligations, the default step, `?`, the record node), `Unify` 617, `Walk` 528, `Report` 488,
`Subset` 108, `Generalize` 297, `Module` 429, `constrain/Tree` 389, `constrain/Expr` 295,
`constrain/Decl` 532: 7 254 lines with the driver. The shared change is `Flags.obls` (§4.1,
*Decided by R5*); `Publish.payloadParams` is public for the marker walk.

*As built by R5's review (2026-09-25):* `Solve.zig` split, as §19.1 expects of a file past its
budget. The obligation deciders moved to **`Decide.zig`** (359 lines: the first step, the drain,
the four deciders, step 3's defaults, step 7's close and poison's settling), which leaves
`Solve` 621 lines: the walk, unification and its report, calls, and the boundary's step order.
v2's own texts moved from `Report.zig` to **`Messages.zig`** (198), which leaves `Report` 302
lines: the emit path, `quiet`, the failure bits and v1's staged texts. Now `Obligations` 294,
`Instances` 242, `Unify` 648, `Walk` 532: 7 442 lines in all.

*As built by R6a (2026-09-25):* two new files, **`Evidence`** 357 lines (§4.2's tables: wanteds,
answers, givens, the position pairing, and `requirements`, §12.1's one canonical order) and
**`Resolve`** 502 (the step, attach and Rule U1's re-attach, the bridge, the `rigid` row, sharing,
the lineage rule, promotion and the default). Lookup and the derivability walk joined the marker
walk in **`Instances`**, now 864 lines — past its ~800, and R8a's fixpoint belongs there too, so
R8a splits it (the marker walk is the separable half). `Solve` 795, `Unify` 776, `Walk` 546,
`Instantiate` 400, `Decide` 374, `Report` 388, `Module` 501, `Subset` 81 (now the elaboration scan
`build` and `dump --stage=dispatch` refuse by), `constrain/Expr` 445, `constrain/Decl` 606,
`constrain/Tree` 416: 9 709 lines in all. No `Groups.zig` yet (R7). Shared: `Category.zig` gains
`.where_clause` and `Diagnostics.categoryLines` gives it the general lines until R13 (v1 never makes
one); `js/Emit.zig` and `main.zig` ask `Subset.needsElaboration`.

*Revised by R6a's review (2026-09-25):* the marker walk left `Instances` for its own
**`Marker`** (241 lines), so `Instances` (675) holds lookup and THE derivability verdict; the
resolver's tables moved out of `Solve` into `Resolve.State` (S7). `Resolve` 608, `Evidence` 425,
`Solve` 865, `Unify` 816, `Instantiate` 435, `Messages` 219, `rules_test` 173 (its S4 fence):
10 151 lines in all, every file under its §19.1 figure.

*As built by R6b (2026-09-25):* two new files, **`Elaborate`** 942 lines (P6: §12.2's units, §12.3's
group calls, the derived table and its sort, and P5's rows' bodies with their propagation) and
**`Eager`** 185 (P5 under v1's one-entry-per-parameter context: which rows, and each body's
wanteds, resolved in a frame of their own). Elaboration is its own file rather than a part of
`Evidence` (~500 above), as the marker walk left `Instances`: `Evidence` stays the tables and the
canonical order (425). `Subset` is gone (nothing refuses elaboration now). `Module` 544, `Solve` 911
(P5's frame), `Resolve` 598, `Report` 396, `Instances` 670: 11 303 lines in all. `Elaborate` is past
the ~500 the table gives elaboration and under the 1 500 cap; R8a's contexts replace most of P5's
half. Shared: `Dispatch.checkI7` judges each term once, bottom-up, and `Edges.termsEdges` walks each
term once (§13.1 *Amended by R6b*).

*Revised by R6b's reviews (2026-09-25):* `Elaborate` split (N5): the unit's DAG and its
topological writer are **`Unit`** (179 lines), P5's rows' bodies, their probe and propagation and
P5's frame moved beside the row choice in **`Eager`** (329), and `Elaborate` (781) keeps the sites,
§12.3, the derived table and its sort. `Solve` 893 (its P5 frame helpers left with P5), `Module`
567: 11 499 lines in all.

*As built by R7 (2026-09-26):* two new files, **`Groups`** 545 lines (the groups and their status,
the top-level-kind frame's life, nesting at demand and the `demand` node, the merge and the
hand-down, the budget and its calibration) and **`Recursion`** 466 (D14's two hooks, the hint and
its syntactic reading of the Bir, §10.6's cycle). `Groups` is over the ~450 above because the
frames of §10 live there, as the table says they should; `Recursion` is §10.7's and §10.6's, which
the table did not foresee as a file. `Solve` 951 (the top-level group loop moved to `Groups`, the
frame stack stays), `Generalize` 378 (`Queue`, `route`, the frame fields), `Module` 518 (P4 is
`Groups.checkAll`), `Decide` 386, `Unify` 853, `Instances` 691, `Report` 383 (the R7 refusal is
gone), `Messages` 268: 12 727 lines in all.

*Revised by R7's reviews (2026-09-26):* `Recursion` split (S4): D14's hooks and when a mismatch is
D14's stay (157 lines), and the Bir reading its hint and §10.6's cycle print is **`Producers`**
(393). The frame stack's primitives and step 6's generality check moved from `Solve` (860) to
`Generalize` (534), as the table above assigns them. `Groups` 592.

*As built by R8a (2026-09-26):* two new files, **`Contexts`** 848 lines (§11.2: the units over the
payload-mentions graph, the memo and its generations, the joint fixpoint and its passes, the
in-flight branch and replay, P5's settle) and **`Derivable`** 492 (the one verdict, moved out of
`Instances` and reading the contexts, the boundary requirements off a method's scheme). The
fixpoint lives beside `Instances` rather than in it, as the marker walk did (`Instances` 704 →
584). `Eager` 330 → 220 (the probe, the propagation and the row choice are gone), `Elaborate` 794,
`Publish` 407 (the rows and the hidden rows), `Instantiate` 494 (`freeze`, `substitute`),
`Incremental` 315 (v1's hit settle moved to v1), `rules_test` 182 (the S3 fence gone with the
stopgap it fenced): 14 327 lines in all, every file under 900.
*After R8a's review round (2026-09-26):* `Contexts` 936 (the marker's `equatable` entry, one
template per answer, bodies per run, the template assert), `Derivable` 504 (`foreignDerives`), `Instances` 615,
`Eager` 237 (`markerKeys`), `Elaborate` 800, `Publish` 451 (the alias-body closure), `Walk` 626
(`sameShape`), `Generalize` 538, `rules_test` 190 (`isEquatable(` fenced to
`Marker`): 14 603 lines in all, every file under §19.1's ~1 500.

*After R8c (2026-09-26):* `Generalize` 630 (rank adjustment's successor stack and inline
answers, the pool's compaction), `Walk` 688 (`eachOwned`, proving runs), `Unify` 932 (the bounded pair
scan, the flex-flex fast path), `Resolve` 689 (the open derivability memo, the Debug check of a
proof), `Derivable` 581, `Solve` 882 (`solveFields`), `Elaborate` 813, `Module` 539 (the P5–P9
events), `Groups` 565, `Instances` 648: 15 905 lines in all (after the review round; the proofs
themselves live in the shared `TypeStore`). `Contexts`
is 1 574, past §19.1's ~1 500 since R8b's rounds; R8c did not touch it.

---

## 20. External contracts

### 20.1 Stable (the corpus is the oracle)

- **CLI.** Every command and flag. The one addition is the hidden, test-only `--checker=v1|v2`,
  which exists R4–R11 and is deleted at R12.
  *As built by R12 (2026-09-27):* deleted. `--checker` is an ordinary unknown option (usage,
  exit 2), and `--self-profile` no longer writes `obligations` or the five `constraints_*`
  counters, which only v1 filled (always 0 under v2).
- **Dump stages.** `tokens`, `ast`, `bir`, `types`, `interface` and `graph` keep their text
  formats.
- **Diagnostics.** Every diagnostic code, the JSON diagnostic format, exit codes and streams.
- **Emitted JavaScript**, except §20.3.

### 20.2 Changed on purpose

| What | When | Version |
|---|---|---|
| `dump --stage=dispatch` format (§13.2) | R2a | — |
| the `Convention` column (§12.5) | R2b | `dispatch_bytes` v3 |
| `dump --stage=raw` gains the §14.2 columns | R3 | — |
| dispatch table bytes | R2a | `dispatch_bytes` v2, `entry_bytes` v3 |
| interface record | R3 | `iface_bytes` v3, digest v2 |
| texts of §15.3 | R5, R6, R13 | — |
| `method_needs_annotation` retired | R7 | — |

### 20.3 Emitted JavaScript that changes

1. **Derived functions of parametric types whose context is not "every parameter, same method"
   (D4).** A phantom parameter loses its parameter, and a nested requirement gains a
   different-method parameter. `emit/Derived*` goldens are reviewed individually at R11. `Maybe`,
   `Result`, `List` and every type that compares each parameter do not change.
2. **Every CK fix.**
3. **`let` evidence parameters (D5, R14).**
   *As built by R14 (2026-09-27):* a `let` function binding with requirements is
   `function <name>($l<inst>$0, …, params…)` (or its arrow, for a `lambda` right-hand side), each
   use passes its evidence first, `f(ev…, args…)`, and a reference in value position is its
   eta-expansion over the binding's arity. `emit/LetEvidenceParameter` pins the shape.

*As measured by R8a (2026-09-26):* no golden of `tests/corpus/emit/`, `dispatch/` or `run/` moved
under v2 for item 1 — every derived type the corpus emits compares each of its parameters with the
derived method, so its context is v1's list, entry for entry (`test-v2`: all 28 `emit/` and
`emit/release/` fixtures pass, the 13 a `--library` build of a type used to refuse among them, and
their bytes equal v1's; `blackbox_test.zig` compares the two checkers' `--library` output byte for
byte). The shapes item 1 changes are pinned by `run/` fixtures instead, whose output shows it:
`PhantomParameterEq` (a phantom parameter: `Tag$$eq` takes no evidence), and
`GenericDerivationNestedRequirement` (`Outer$$eq = ($m$0, $x, $y) => Holder$eq($m$0, $x.a, $y.a)`
with `$m$0` a `key`, the §11.2 example). Item 2's CK-85 changes one `run/` golden on purpose,
under both checkers (the emitter is shared): `run/EvidenceFunctionBodyPerCall` prints one
`table (where)` line where it printed three (`static-dispatch-spike.md` A.85 *as amended by R8a*),
and CK-87's cap removal turns `run/DerivedEqDeepRecord` from refused to built.

*As measured by R9 (2026-09-27), with `core` under v2:* `bench/corpus` built with `--library` under
both checkers (dev and `--release`) differs in one kind of line, and no item 1 function: a derived
body's position whose type is an all-nullary nominal type (`Dict`'s `NColor`, `ExprParser`'s `Op`,
`Router`'s `Sort` and `SettingsTab`) is `x.a === y.a` under v2 where v1 calls the type's derived
`eq`, whose body is that same `===` — A.18's rule (`Instances.onApp` step 5), which v2 applies at
every position and v1 only at a site. The `Router` and `ExprParser` lines were already there before
R9 (root-package modules); R9 adds `core/Dict.mjs`'s two, and `--release` renames the short names
after the `Dict$NColor$$eq` it no longer reaches. `bench/corpus/DictExtra.beni`'s `any` was a
`find dict predicate /= Nothing` on `Maybe ( String, v )` with `v` rigid, which v2 refuses
(`missing_where_constraint`, CK-20's rule) and v1 answered with structural equality; it is a
`case` since R9.

### 20.4 Existing fixtures whose expectations change

These change at the slice named, and are re-blessed with review, never in bulk:

| Fixture | Slice | Why |
|---|---|---|
| `tests/corpus/dispatch/*` | R2 | the format |
| `check/bad/MethodNeedsAnnotation/` | R11 | D3: becomes a `run/` fixture that prints the answers |
| `check/bad/PriorityGroupSpecializedPayloadEq/` | R11 | its refusal is re-derived without priority groups. Expected to stay a refusal, with a new region |
| `run/DerivedEqInPriorityGroup/` | R11 | must still pass. Only its intent comment changes |
| `check/bad/LetConstrainedTwice.beni` | R14 | D5: `show` generalises; the diagnostic becomes whatever `Int`/`String` lack (`unknown_method render`) |
| `check/bad/LetHelperCyclicReceiver` | R14 | D5: the program is valid. It becomes `run/LetHelperCyclicReceiver` |
| `abuse_test.zig`'s row-76 scenario | R14 | expects exit 0 within the bound |

*As built by R11 (2026-09-27):* `check/bad/MethodNeedsAnnotation/` is `run/OwnEqCheckedAfterItsUse/`,
which prints both answers (`EQ`, `True`, `True`; v1 still refuses it). The refusal of
`PriorityGroupSpecializedPayloadEq` is v2's at the SAME region and text as v1's, so its golden
did not move; its intent comment, and `DerivedEqInPriorityGroup`'s, now say how v2 reaches it.
The entries of `tests/pending/v2-expected.md` (deleted at R11) — the differences R4b to R9 introduced,
this table's among them — were re-blessed one by one, each with its reason, in
`checker-rewrite.md` R11 *As built*; `LetConstrainedTwice` and `LetHelperCyclicReceiver` among
them for their v2 texts, not for D5, which still changes them at R14. No `emit/` golden moved
(§20.3's item 1 was measured by R8a).

*As built by R14 (2026-09-27):* `check/bad/LetHelperCyclicReceiver` is `run/LetHelperCyclicReceiver`,
which prints both answers, and the `abuse_test.zig` row-76 scenario expects exit 0 within its
bound. `check/bad/LetConstrainedTwice` is **still refused**, and its row above is withdrawn: its
`show x = x.render 1` carries only a dot-call's own requirement, which the owner's D5 row of
2026-09-26 (§21.1) keeps monomorphic. Its golden moved in its hint alone, which now says why the
binding has one type (§8.4 *As built by R14*).

---

## 21. Decisions

All **taken by the owner on 2026-09-24** ("go with the recommendations"). Each names the spec text
it changes, and the slice that writes that change where this document does not already.

| # | Decision | Rationale | Spec change and slice |
|---|---|---|---|
| **D1** | **Private methods answer dispatch only inside their module.** Derived functions the module emits may use them. *(Amended: that means structural shapes derived in the module; see the D1 round-4 row of §21.1.)* Any wanted from another module that reaches one, directly or through derivation, is `private_method` | Coherence: the same two values never compare differently in two places. The refusal protects no-silent-wrong-answer (rule 7), and `pub` is always available | §11.3 here; `static-dispatch-spike.md` §3.3 and A.63, pointer now; R8 implements |
| **D2** | **`?` is a deferred obligation**, decided when either side is concrete, defaulting to `Result` only at the enclosing declaration's boundary | The greedy order refuses valid programs (CK-06) and protects nothing | §8.6; `checker.md` §6.5, pointer now; R5 |
| **D3** | **No annotation is ever required on a method for ordering reasons.** Own untyped methods are deferred (§10). `method_needs_annotation` is retired | The refusal was an implementation ordering limit, not a guarantee (rule 7). Roc shows the deferral works | §10; `static-dispatch-spike.md` §10.12 and §6.3.1 step 4, pointer now; `language.md` §10 catalogue marks the code retired in R7 |
| **D4** | **A derived function takes one evidence parameter per entry of its inferred context**, not one per type parameter | Closes row 73 (CK-25) and the phantom case (CK-23), and it is smaller output. The emitted ABI is unchanged for every type that compares all its parameters | §11.2; `static-dispatch-spike.md` §9.4 and A.20, pointer now; interface v3 (R3); R8 |
| **D5** | *(Amended 2026-09-24, round 2 S-new-4: read the D5 row of §21.1, which states the HM(X) rule. The text that follows is the original wording.)* | **D5** | **A constrained `let` binding is generalised when every variable its requirements reach is its own**. Rule (a) is retired, and levels keep outer-receiver requirements monomorphic. Let binders get evidence parameters `$l<inst>$<k>` | HM(X) is sound here once I2 holds, and rule (a) protected no guarantee (rule 7). Row 76's trigger disappears | §8.4, §13; `static-dispatch-spike.md` §6.4, §11 and A.30, pointer now; `backend.md` §4's constrained-declaration row gains `let` in R14 |
| **D6** | **Build v2 in parallel** (`src/check2`, hidden `--checker=v2`), with the old checker as the oracle, then switch and delete | §22 | `checker-rewrite.md` |
| **D7** | An annotation escape is reported as **`rigid_mismatch`**, with no new code | It is a rigid mismatch against an outer variable. The Elm-style text is enough | §8.3 |
| **D8** | A float literal pattern gets a dedicated message under **`unexpected_token`**, with no new code | The grammar already excludes it (`language.md` §3). Only the message was wrong | `checker-rewrite.md` R1 |
| **D9** | The **`number` bridge** exists only for `eq`/`compare` on a `number`-kinded variable, and unifies the declared method type first | Keeps today's ABI (no evidence for `number`) while checking `where` clauses (CK-21) | §9.3 |
| **D10** | The `equatable` marker walk descends into **payloads**, not type arguments | "Comparable exactly when everything it can hold is", which is the message's own promise | §11.4 |
| **D11** | A **dispatch back-edge merges** the groups on the nested stack into one mutually recursive group | The ML rule. The only sound alternative is an annotation, which D3 rules out | §10.4 |
| **D12** | The **record-alias constructor** emits the record literal, keys in canonical order | Elm's semantics (`language.md` §0) | `backend.md` §4 row, written in R1 |
| **D13** | **Pending fixtures** live in `tests/pending/` with the corpus layout, and are run by `zig build test-pending`, not by the gates | Rule 4: never commit red | `checker-rewrite.md` §2 |
| **D14** | **Canonical pessimism in recursive groups** (§10.7). In a value SCC of two or more members, or a merged group, a method call or obligation whose receiver is group-level at its constraint node has its method type lowered to the group's rank, even when it resolves inline. The resulting `type_mismatch` carries a hint naming the member to annotate. *Taken 2026-09-24 by the manager under the owner's standing instruction to take the recommendations (review round 3, B-3, option (i)); flagged to the owner.* | Rule 7: the refusal buys I9's order-independence, a guarantee, and annotating a member lifts it. Without it, `sccA` and `sccB` are accepted in one order and refused in the other | §10.7, I9 restated; R7 |

### 21.1 Amendments of 2026-09-24, from the design review

The owner's instruction was "go with the recommendations", so these amendments stand as decided.
Each one records what changed and why.

| Decision | Amendment | Rationale |
|---|---|---|
| **D2** | "The enclosing declaration's boundary" means **the boundary that owns the obligation's variables**: the `?`'s target's own generalisation boundary, which may be a `let` (§8.6). The default happens inside that boundary's settle loop, as a last resort | S3. Under D5 a `let` generalises, and deciding its `?` later would unify generalised variables |
| **D3** | `method_needs_annotation` survives for **one non-ordering case**: a derived instance whose context depends on an in-flight inferred method of the group being checked (§11.2). The refusal is the same in every declaration order, and an annotation always lifts it | S1. A derived instance is not a group member, so there is no monomorphic reading of it. A mixed fixpoint over inference and derivation is not worth its complexity for this rare shape. Rule 7 is kept: a named escape hatch, and no silent wrong answer |
| **D9** | The `number` bridge applies to a **flex or rigid** of kind `number`. It is a row of §9.2's receiver table, applied when the wanted is first drained, and always unifies the method type first | B4. Without the rigid case, `core` (`abs`, `max`, `min`) and `run/DecodeInto` do not check. v1 has it at `Solve.zig:2750-2753` |
| **D10** | "Payloads" is made checkable across modules by **`payload_params`** in interface v3. A `foreign type` has all parameters | S15. An imported opaque type's payloads are not in its interface |
| **D11** | **Value back-edges merge too.** (Round 1 wording, superseded by the round-2 row below.) Nested checking happens at the innermost boundary that drains a wanted, not only at top level, and it checks the value-dependency prefix first. The Roc comparison and the two-types example are recorded in §10.6, with a hint on the resulting `type_mismatch` | B6, B7, S17. Top-level-only pinning made results order-dependent, and a nested group's value dependencies were unchecked. v2 is stricter than Roc on purpose, because Roc's laziness is order-dependent |
| **D2** (round 2) | Whether a `?` default is due is read on **adjusted** ranks: §8.1 step 2 runs before step 3. A top-level frame merged into another never defaults; its root does | N2, N4. Stale young ranks defaulted an escaping `?` to `Result` too early, and a merged frame defaulted before the root's facts arrived |
| **D2** (R5's review, 2026-09-25) | The boundary that owns a `?` is its **target's** (the round-1 amendment's words, now the only reading): the subject and the value are lowered to the target's rank, the target is never lowered to the subject's, and a `?` still undecided at its target's step 3 is defaulted to `Result` even when its subject is outer | CK-99: sharing one rank made the target monomorphic in its own success type and refused a program v1 builds; §4.5 *Amended by R5's review* |
| **D3** (round 2) | The surviving `method_needs_annotation` case is narrowed to a derived context entry **indexed by a type parameter** that depends on an in-flight method. A closed payload contributes nothing and is filled like a group call | S-new-1. The broader refusal guarded nothing (rule 7) |
| **D14** (round 4) | D14 is stated over **every wanted resolved or attached** on a group-level receiver (a method callee, instantiation evidence, a sub-wanted), and every variable of an obligation with a group-level deciding variable. It is checked in `Resolve`'s single resolution function. `R` is the member's own top-level frame rank. The hint names the member **syntactically** (the reference that produced the receiver's value), or else every unannotated member, sorted by text | R7-1, R7-2, S4-1. The round-3 rule missed evidence and sub-wanteds (`evA`/`evB`, `subA`/`subB` were order-dependent), and its hint depended on union-find class membership |
| **D1** (round 4) | A private method is still the module's method for **every** type the module declares (the module rule is unchanged by privacy). "Derived functions the module emits use it" covers structural shapes derived in the module. The module's other nominal types have no derived `eq`, and comparing them is the module-rule clash | R0 found the round-1 text contradicted §3.3 step 1. `7427828` already behaves this way |
| **D8** (round 4) | Elm's `exposing (T(..))` also gets a dedicated message under an existing code: **`expected_token`** at the `(` after the type name, suggesting `exposing (T, Ctor1, Ctor2)` (`language.md` §5.2). Later uses of the unexposed constructors stay quiet. *As built by R1 (2026-09-24): every unknown constructor in that file stays quiet, not only `T`'s — lowering is per file and cannot tell which names are `T`'s constructors, and resolution, which can, finds only silent error instructions. No guarantee is lost: the file already fails, and a misspelt constructor is reported once the import is corrected.* | CK-47. Same reasoning as D8: the grammar already refuses it, and only the message and the cascade were wrong |
| **D5** (round 2) | Generalisation is plain HM(X) on levels. A young receiver's promoted requirement may mention outer variables free. I15 binds only receivers that are not generalised | S-new-4. The round-1 wording contradicted `adjustRank`, and I15 |
| **D5** (R7's round-2 review, 2026-09-26; **decided by the owner 2026-09-26: yes**) | A `let` binding whose constrained variables carry ONLY dot-calls' own requirements is not generalised over them, so `let call s = s.f 10 in call { f = … }` stays a field call once D5 lands (static-dispatch-spike.md §11 *Deferred receiver*, amended 2026-09-26) | Without it, R14 generalises `call` and the amended rule refuses the record: a program accepted today would be refused, and generalising there buys no guarantee (rule 7) while taking the field call away. The alternative (b) accepts the flip and moves the case to a `check/bad` fixture |
| **D5** (R14, 2026-09-27; **confirmed by the manager 2026-09-27**, R14's review S1) | A `let` **value** binding (no parameters, and a right-hand side that is not a `lambda`) and a `let` pattern are not generalised over a constrained variable (§8.4 *As built by R14*, rule 2): Haskell's monomorphism restriction | A value binding can take evidence only by becoming a function of it, whose right-hand side then runs at each read: that breaks `language.md` §6's "evaluated once, where written" for `let` bindings, silently re-runs a `Debug.log` or an expensive table per read, and would move `static-dispatch-spike.md` §6.2's pinned-by-a-later-use example. It refuses nothing v1 or pre-R14 v2 accepted, once a `let` over the 64-requirement cap is held rather than refused (R14's review B2; R14's first cut refused one). The workarounds are a parameter, or a placeholder application `f a _`, which is a `lambda` and so a function binding. The alternative is a per-evidence memo like the top level's (A.85 as amended by R8a), at a `let` |
| **D11** (round 2) | **Nesting happens at demand**, not at a boundary. **Only top-level frames merge**, and every `let` frame generalises at its own boundary. **A reference to an annotated binding is never a back-edge**. It instantiates the scheme (§6.6) | N3, N5, N8. Boundary-time nesting was still order-dependent; merging `let` frames was order-dependent; treating annotated members as in-flight killed polymorphic recursion that v1 accepts. The at-demand design also deletes parking, pinning and prefix closures |

---

## 22. Migration

**Recommendation, adopted as D6: build the new checker in parallel.** The choice was between
building it beside the old one and replacing the old one in place, slice by slice.

The parallel build wins, for four reasons:

1. **The old checker is the only complete oracle.** 289 black-box cases, about 580 fixtures and
   the determinism and matrix tests encode what the checker must keep doing. With both checkers
   runnable on the same input, every difference is either a CK entry, which is listed, or a v2 bug.
   Replacing in place loses the comparison the moment the first piece is swapped.
2. **The architecture does not decompose into swappable pieces.** Unify-without-resolution,
   wanteds, elaboration and deferral each change the interface between `Unify`, `Solve` and the
   dispatch code. An in-place sequence would build and then delete adapters at every step. That is
   the accretion this rewrite exists to end.
3. **The three gates stay meaningful.** Until the cut-over they run v1, which only improves (R1–R3
   land fixes in shared code). v2 is held to `test-v2` and `test-pending` at every slice (§22.2),
   and they become part of the gates' meaning at the switch.
4. **Precedent.** rustc's next-generation trait solver shipped behind `-Znext-solver`. The test
   suite and crater ran under both until parity, then the default flipped.

**Its costs, stated.**
- Two checkers co-exist for about eight slices.
- Shared code (`Lower`, `Dispatch`, interfaces, `Cycles`) has to serve both. R2 and R3 therefore
  make the **contract** change on v1 first, so v2 targets a contract that already exists and that
  v1 already produces.
- Pending fixtures fixed only by v2 wait in `tests/pending/` until the cut-over, protected by
  `tests/pending/CLAIMED`.

**Amendment of 2026-09-25 (the owner): v1 is frozen.** The owner does not require `master` to keep
working during the conversion. v1 is kept only as the **oracle**: it checks `core` and the
dependencies, so the corpus goldens keep running as v2 grows. It is **frozen**: no further fixes
or features land on v1, and its remaining bugs are fixed by v2 only. v1 is deleted as soon as v2
can check `core` and pass the corpus (R9–R11). This narrows reason 3 above: the gates stay
meaningful because v1 stops changing, not because R1–R3-style fixes keep landing on it.

### 22.1 The switch

- **R4–R8.** `--checker=v2` checks the **root package** with v2 and **every non-root package** with v1:
  `core`, and platform packages such as `Node` (N4). The `--core` corpus fixtures, which make their
  own module part of `core`, therefore still run v1 under `BENI_CHECKER=v2` before R9. They are
  listed in `tests/pending/v2-expected.md` as "not yet v2" rather than counted as passes (N13). Both read and
  write the same interface format, so the black-box corpus can run against v2 before v2 can check
  `core`.
- *As built by R4a:* "the root package" is `SourceStore.Package.app` without `--core`
  (`check2/Check.zig`'s `Options.usesV2`). A module an earlier phase already reported on, or one
  the graph poisoned, is checked silently by v2 as by v1 (`checker.md` §4.3), so R4a's stub reports
  `not_implemented` only on the root modules that reach it clean.
- **R9.** `--checker=v2` covers every package including `core`, and `test-v2` becomes strict.
  *As built by R9 (2026-09-27):* `Options.usesV2` is `checker == .v2` and nothing else — the root
  package, `core`, platform packages and `--core` fixtures alike — and `Options.root_is_core` is
  deleted. Every record a v2 build reads is therefore v2-written, cold or warm (`key_version` 4,
  §14.3), so v2's fallbacks for a record the old checker wrote are deleted with
  `Context.oldCheckerWrote`: v1's ABI for a row-less private type in `Instances.derivedNominal` and
  `Derivable.head` (now `internal`, as for any v2 record), and v1's table bit in `Marker`'s imported
  gate. `Incremental.install` keeps v1's capability rebuild for `--checker=v1` only. `core`'s
  records under v2 are v1's byte for byte (`dump --stage=raw` and `interface`, every module) except
  the `no_function` bit of §14.2 *as amended by R8b*, which v1 never writes, once CK-130 was fixed
  (§23 item 4).
- **R11.** The default flips.
  *As built by R11 (2026-09-27):* `--checker` defaults to `v2` (`Cli.zig`, and `Session`,
  `check2/Check.zig`'s `Options` and `bench` with it), so the three gates run v2. `--checker=v1`
  stays, hidden, for the scenarios that compare the two checkers (the cache key's checker row,
  CK-131's ratio, CK-107's, the checker-crossing cache scenarios) and for one v1-only guard
  (`abuse_test.zig`'s constraint-set counters, A.81), until R12.
- **R12.** v1, the flag and `check2`'s name are deleted.
  *As built by R12 (2026-09-27):* `src/check/`'s `Solve.zig`, `Constrain.zig` and `Check.zig`
  (its pipeline tests moved to `checker_test.zig`, which ran them under v2 from R11), v1's
  capability settle and its per-type bits in `Types.zig` (`answers_*`, `public_*`, the
  method-parameter requirement tables), the schema endpoints' settled properties
  (`Schema.settleProperties` and its `Types` API), the flat half of `Dispatch.zig` (`Target`,
  `FlatSite`, `FlatDerived`, `Builder` and its converter), the constraint sites of
  `TypeStore` and `Schemes.instantiate`'s `Site`, `Env`'s generator-only fields, six
  `Reporter` methods nothing called, `Check.Checker`, `Options.usesV2`, `Driver`'s v1 branch
  and `Incremental.install`'s capability rebuild. Then `git mv src/check2/* src/check/`.

### 22.2 How v2 is held between slices

| Step | Runs | Mode |
|---|---|---|
| `zig build test-v2` | the whole `tests/corpus/` with `--checker=v2` | **report** (R4–R8): pass/fail per fixture, exit 0. **strict** (R9–R11): must be all green except the listed expected-difference fixtures |
| `zig build test-pending` | `tests/pending/` under v1 and v2 | fails if a fixture is green under the default checker (promote it), or if a fixture in `tests/pending/CLAIMED` is red under v2 |

*As built by R4a:* report mode is not quite "exit 0". It skips the fixtures of
`tests/pending/v2-expected.md`, and it FAILS for a red fixture listed in
`tests/pending/v2-green.txt` (the ratchet, S12), or for a line of either file that names no
fixture the walk runs (`checker-rewrite.md` §2.4). The scenarios of `pending_test.zig` run under
the default checker only.

*As built by R9 (2026-09-27):* strict. `test-v2` is the corpus walker's strict mode under
`BENI_CHECKER=v2`: a fixture `v2-expected.md` lists is skipped (an entry must name one fixture the
walk runs, or the step fails), and any other red fixture fails the step. Report mode and the
`v2-green.txt` ratchet are deleted; the `--core` section of `v2-expected.md` with them.

*As built by R11 (2026-09-27):* both rows are history. `test-v2` is deleted — with v2 the default,
`test-blackbox` is the same run, and its determinism and incrementality scenarios run under v2
as they are — and so are `v2-expected.md` (each entry re-blessed individually, `checker-rewrite.md`
R11 *As built*), `v2-subset.sh` and the name-filtered binaries' guards. `test-pending` and
`test-pending-perf` run once each, under the default checker: rule (b) holds v2 to promoting
every fixture it turns green, and `CLAIMED` is empty.

Both are part of every rewrite slice's exit criteria (`checker-rewrite.md`), beside the three
gates.

---

## 23. What is not settled

These are honest uncertainties for the implementing slices, not open owner decisions.

1. **The merge rule of §10.4 has not been exercised on real code.** The argument is the ML rule,
   but the frame bookkeeping (handing pools downwards, lowering ranks) is new. R7's reviewer must
   check it against a permutation scenario over at least 4 mutually dispatching own methods, and
   against Roc's `type_checking_integration.zig:10490-10530` shapes.
2. **The occurs cost at binders (§18)** is unmeasured on beni. The fallback is stated.
3. **The proven-undetermined default (§9.4)** is today's `settleUndetermined` with a sharper
   precondition. Which existing fixtures exercise it is unknown until R6 runs the corpus.
4. **Interface v3's context rows for `core`.** `core`'s derived types (`Maybe`, `Result`, `Order`)
   get contexts equal to today's ABI. That must be confirmed by `emit/` goldens not moving in R8.
   *R9 (2026-09-27):* confirmed with `core` checked by v2: every context row of every `core` record
   is v1's (`dump --stage=raw`), once CK-130 put back §3.2's derived rows of `Order` and `Never`.
5. **Schema endpoints in the fixpoint (§11.5)** depend on S3/S4 of `schema.md`, which have not
   landed. R8 covers S2's check-only endpoints, and later schema slices must use `Instances`, not
   add a property pass.
6. **The constraint edges of `Walk.owned`, and I15's lowering on attach, are new relative to both
   Elm and Roc** (§3). No shipped checker treats method types as level-carrying graph edges this
   way. R4 and R6 must prove on the corpus that I15 never lowers a variable a program needed to stay
   polymorphic. The known costs are D5's outer-receiver case (CK-02), where it is the point, and
   nothing else yet. The R6 reviewer runs the I15 assert over `bench/corpus`.
7. **Nesting at demand (§10.2) departs from Roc**, which nests only at group boundaries. The
   soundness argument is in §10.2: a nested group shares no variable with the open frames except
   through a back-edge. The prior art closest to it is Roc's own nested check, which the design
   copies, but at a different point.
8. **D14's merge argument (§10.7)**, "whether a node is inside a recursive group is a function of the
   member's own body prefix", is argued, not proven. R7's permutation scenario must include 3-cycles,
   and a member that demands the cycle at two different nodes.
   *R7 (2026-09-26), for items 1, 7 and 8:* `scenario/PERM` holds every order of 3- and 4-member
   merges, a member demanding its cycle at two nodes, a value back-edge, a group nested two `let`s
   deep and D14's refusals (CK-72, CK-73, CK-76) byte-identical (§10.8). Still argued, not proven;
   Roc's `type_checking_integration.zig` shapes were not ported.
9. **The joint derived-context fixpoint (§11.2)**, with its approximation-or-fresh rule and memo
    replay, is new. R8a's reviewer checks the well-foundedness argument against `xm`, `cbA` and a
    cross-unit chain.

## 24. Revision trace: the design review of 2026-09-24

Every item of `review-design.md` and where it landed. "Disagree" rows say why.

| Item | Resolution |
|---|---|
| **B1** `children` makes constrained variables cyclic | §4.1 two successor functions; I2 restated; §3 Roc citation corrected; §8.2 and §11.4 use `structural`; §23 item 6 |
| **B2** constraint edges alone do not close CK-02 | I15; `lowerTo` on attach (§7.1); §4.1 note |
| **B3** occurs before the unifying steps | §8.1 rewritten as a settle fixpoint, then occurs over binders and unified variables, then generalise; I16 |
| **B4** no `number` bridge for rigids | §9.2 table; §9.3 step 2 moved; D9 amended (§21.1) |
| **B5** in-place writes survive rollback | §4.2 journalled `WantUndo`; §7.5; I14 restated with the entry-point assertion |
| **B6** pinning to top-level rank | §10.2 rewritten: park on the innermost frame, nest at its boundary, pinning retired; §10.6 example; D11 amended. *Superseded in round 2 (N3): nesting is at demand; see §24.1.* |
| **B7** nested checks ignore value dependencies | §10.2 `checkNested` checks the value-dependency prefix; value back-edges merge (§10.3, §10.4); `Groups.value_deps`. *Superseded in round 2 (N3): the prefix check is "nest on first reference".* |
| S1 derived query blocked on the current group | §11.2: never memoised while blocked; blocked-on-self → `method_needs_annotation` (D3 amended); the fixpoint's own frame; assert |
| S2 member requirement lists | §12.3: lists from each member's own scheme; three cases; assert |
| S3 D2's boundary | §8.6; D2 amended. R5's reviewer focus corrected in `checker-rewrite.md` |
| S4 CK-04 diagnostics | §6.3 `binders_end` occurs at the lambda or branch end, which keeps `infinite_type` ×2; §18 nested measurement |
| S5 bridge placement | with B4 |
| S6 rescanned obligations | §4.5 per-rank buckets; I3. *Superseded in round 2 (N1, S-new-2): obligations ride on their variables.* |
| S7 infeasible slice claims | `checker-rewrite.md`: CK-08, CK-09 (`.beni` with `==`) and CK-11's v2 check move to R6 |
| S8 R1 depends on R2 | `Convention` moved to R2 (§12.5); R1 → R2 strictly ordered |
| S9 R1's CK-17 fix | `checker-rewrite.md` R1: make v1's walk growable, not `.unknown` → refusal |
| S10 I7 assert on v1 | §13.1: `internal`, never a panic, R2–R10 |
| S11 environment leaks into gates | `checker-rewrite.md` §2.4 |
| S12 no ratchet in report mode | `checker-rewrite.md` §2.4 `v2-green.txt` |
| S13 wrong-reason passes | `checker-rewrite.md` §2.4–§2.5: red signatures, permutation asserts, best of 3 |
| S14 lineage | §9.5 rewritten: equal-root repeat is `infinite_type`; root identity |
| S15 D10 across modules | §11.4, §14.2 `payload_params`; D10 amended |
| S16 rank of P2's rigids | §5 P2, §6.6, §8.3 |
| S17 D11 vs Roc | §10.6; hint; fixture in R7 |
| S18 stale invariant numbers | `checker-findings.md` CK-10, 14, 18, 26, 35 corrected |
| S19 normative scope | Status line |
| S20 R4 messages | §15.3 |
| S21 `?` speculation | §7.5: no longer speculative; §8.6 |
| S22 cache not keyed by checker | §14.3 |
| N1 | `checker-findings.md`: CK-10 is K3; new class K15 (specification drift) for CK-61 |
| N2 | `checker-findings.md` CK-22 program annotated |
| N3 | §7.3 wording |
| N4, N13 | §22.1 |
| N5 | §4.1 text order for everything shown |
| N6 | §13.1 `lets` present and empty from R2 |
| N7 | §4.2 `origin` optional plus `origin_decl` |
| N8 | `checker.md` §6.7 sentence fixed now |
| N9 | `language.md` §10 pointer note added |
| N10 | §12.1 discovery order; R6 byte-comparison criterion |
| N11 | §10.4, §15.2 |
| N12 | §11.2 worklist |

### 24.1 Round 2 (`review-design-2.md`)

| Item | Resolution |
|---|---|
| **N1** obligation extras escape generalisation | §4.5: obligations ride on their variables; all variables of one obligation share one rank (I15 extended); `owned` yields them. Program: CK-68 |
| **N2** `?` default reads stale ranks | §8.1 is now settle (no defaults) → adjust ranks → defaults on still-rank-`r` obligations → loop; §8.6; D2 amended. Program: CK-62 (`n2try`) |
| **N3** settle-time nesting order-dependent | §10 rewritten: **nesting at demand**. Deleted: parking, park lists, pinning, settle-time nesting, the value-prefix closure, `Groups.parked` and `value_deps`. Program: CK-63 (`n3box`) |
| **N4** merged frames default early | §8.1 and §10.4: a merged frame runs steps 1–2 and hands down, with no defaults; debug assert. Program: CK-65 (`n4ambm`) |
| **N5** merged `let` frames | §10.4: only top-level-kind frames merge. Program: CK-65 (`n5sw`) |
| **N6** journal-segment occurs | §8.1: an append-only `touched` log with per-frame start; §7.1 |
| **N7** group variable outside the caller's scheme | §12.3 case 3 → `undetermined` by parametricity; §9.4 promotes per member. Program: CK-66 |
| **N8** annotated recursion | §6.6: every reference to an annotated binding instantiates its scheme and is never in-flight or a back-edge; only the body sees the rigid instance. Program: `run/AnnotatedPolymorphicRecursion` guard |
| S-new-1 | §11.2 narrowed (closed payload filled like a group call); D3 amended; programs CK-67 (valid) and CK-69 (refused) |
| S-new-2 | §4.5, §8.1: obligations readied through their variable; defaults applied in one batch |
| S-new-3 | §4.4 effective status via union-find root; §10.4 |
| S-new-4 | §8.4 restated as HM(X); I15 restricted; D5 amended |
| S-new-5 | §9.1: one `ready` queue, drained by the innermost settle step |
| S-new-6 | I15 assert bounded to the boundary's own walk; §18 |
| S18 (still open after round 1) | now edited in place in `checker-findings.md` (CK-10, 14, 18, 26, 35), plus the erratum table |
| Nits | `checker.md` §5 and §6.5 notes updated; prefix closure moot (deleted); D11 hint prints the cycle from the smallest name by text (§10.6); `payload_params` puts an opaque type's phantom-ness in its digest, which is accepted and noted in §14.2 |

**Round-2 correction to the reviewer's programs.** Several of them used a nullary dot-call
(`(Box x).size`, `(K u).makeBox`). beni parses that as a **field access**
(`static-dispatch-spike.md` §11), so v1's refusal of them is correct. The fixtures use `.size ()` and
a `u` parameter. Two also used Elm's argument order for `Maybe.withDefault`, where beni's is
subject-first. Both behaviours were re-checked on the v1 binary.

### 24.2 Round 3 (`review-design-3.md`)

| Item | Resolution |
|---|---|
| **B-1** shared `ready` queue | §9.1: one queue per top-level frame and per fixpoint frame; each frame drains only its own; eager draining after every constraint node; §8.1 step 1; §10.4's demand-chain premise now justified. Programs: `rq1` (CK-73), `rq2` (guard), the merge variant (CK-73 fixture) |
| **B-2** re-entrant derived query | §11.2: a fresh fixpoint on re-entry; terminates by nesting. Program: CK-74 (`other = (T 1).key "s"`, both orders) |
| **B-3** I9 inside recursive groups | **D14** (§10.7, §21), option (i), with a hint. I9 restated with its three rules; §10.5 rewritten. Programs: CK-72 (`sccA`/`sccB` refused with the hint in both orders), guard `run/RecursiveGroupAnnotatedReceiver` (annotated form), guard `capt` |
| S-1 | §10.2: a `checkGroup` that returns merged sends the demand down the in-flight path |
| S-2 | §11.2: explicit rank and pool for `Instantiate` |
| S-3 | §8.1: one `touched` list per frame; reversed-chain perf scenario in R7 |
| S-4 | §10.2: one cumulative recursion budget across nested frames, `nesting_too_deep` with an annotation hint; explicit stack rejected, with reasons; generated deep-chain scenario in R7 |
| S-5 | `checker-rewrite.md`: R4 split into R4a and R4b; R4b includes obligation-free constraint generation; its subset excludes obligation forms |
| S-6 | §11.2: memo generations |
| S-7 | §17 demand order; §18 settle-loop cost; §5 P4 skips `done` groups; the §21 D5 row points to its amendment |
| N-1 | I14: a probe never nests |
| N-2 | §10.4: the no-nesting-after-default assert also covers `let` frames |
| N-3 | §4.5: only result variables' closures are lowered; R5 reviewer test |
| Slice sizing | `checker-rewrite.md`: R2a/R2b, R4a/R4b, R6a/R6b, R8a/R8b; the CK → slice index updated |

### 24.3 After R0 (2026-09-24)

| Item | Resolution |
|---|---|
| CK-22's inside fixture was ambiguous | D1 amended (§11.3, §21.1): the module rule is unchanged by privacy, so a private `eq` is the method of every type the module declares. `run/PrivateEqInsideModule/` is a v1-green guard |
| CK-37's fixture depended on which cycle check fires first | §9.5 pins it: eager draining makes the resolver walk first; one `infinite_type`; the cycle's root is poisoned; a non-cycle rejection flags one method and does not poison. Both are v1's behaviour, so both fixtures are guards |
| CK-71 (R0: `Session` ids depend on thread timing) | assigned to R1: merge interners in path order |
| CK-47's code | D8 amended: `expected_token` at the `(`, confirmed |
| CK-73's merge-variant `.iface` | wrong under D14. The fixture is split into a D14 `check/bad` and a `check/good` without the `q` helper |

### 24.4 Round 4 (`review-design-4.md`)

| Item | Resolution |
|---|---|
| **R4-1** Snapshot and routing | §7.5: the Snapshot records every open frame's `ready`/`touched` lengths. Per-frame lists stay contiguous, which S-3's bound needs, and the cost falls only on failure probes. §9.1: rows carry `frame` and `seq`; routing is by creation frame; a merged frame drains its own queue until hand-down. §4.5's stale "one queue" is fixed |
| **R7-1** D14 misses evidence and sub-wanteds | §10.7 restates D14 over every wanted resolved or attached, and over all of an obligation's variables, in `Resolve`'s one resolution function; I9 rule (3) restated; D14 amended (§21.1). Programs `evA`/`evB`, `subA`/`subB` (`checker-rewrite.md` §5.6) |
| **R7-2** the hint's member depended on order | §10.7: syntactic naming by the introducing reference, falling back to the text-sorted unannotated members |
| **R7-3** the nesting budget | §10.2: budget = 2 × one declaration; admission requires one full declaration's worth left, so the refusal is always at the demand with the hint; `nest_cost` is a counted constant calibrated in Debug; fixpoint frames charge it; the "thousands" claim is corrected and the exception added to I9 |
| **R8-1** fresh-on-re-entry did not terminate | §11.2: a fixpoint's own payload queries read its approximation; fresh only when a group frame lies above it; a real well-foundedness argument (group frames are unique and bounded; cross-unit chains follow a DAG) |
| **R8-2** per-method fixpoint was unsound | §11.2: the unit is (type-level SCC) × {`eq`, `compare`}, iterated jointly. Guard `xm`/`xm2` |
| **R8-3** closed in-flight branch skipped the merge | §11.2: the method-type check is an ordinary wanted in the asking frame, so it merges via §10.3/§10.4; memo-generation hits replay it. Programs `cbA`/`cbB` |
| S4-1 | §10.7: `R` is the member's own top-level frame rank |
| S4-2 | §15.3: D14 hint, nesting hint, and derived `private_method` variant added |
| S4-3 | §9.5: the backstop counts resolution steps per module, cumulatively |
| S4-4 | §9.1: one creation sequence `seq` across wanteds and obligations |
| S4-5 | `checker-rewrite.md` R6a: "privacy" means spike §1.2's direct `private_method` only; D1's reach through derivation is R8b's |
| N-4 | spike §3.3 note and the §21 D1 row now say "structural shapes" |
| N-5 | left to R0's `CLAIMED`/`RED` notes (R0's region); flagged in the report |
