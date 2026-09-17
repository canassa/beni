# Roc's static dispatch, as built: an implementation walkthrough for S3–S6

**Commissioned by** [`plans/static-dispatch-spike.md`](../../../plans/static-dispatch-spike.md) §4–§6
and the branch specification [`static-dispatch-spike.md`](../static-dispatch-spike.md). Reports
[`07`](07-roc-static-dispatch.md) and [`18`](18-static-dispatch-revisited.md) argued the *design*
question and are not repeated here. This report answers a different one: **how is it actually
built**, in the Zig compiler vendored at `references/roc/` (commit `f083385b5b`, 2026-09-12), and
where does the spec disagree with what that code does.

Every claim below carries a file-and-line citation, prefixed to say which tree it is in:
`roc:<path>:<line>` is `references/roc/<path>`, and `beni:<path>:<line>` is this repository. The
prefix is not decoration — both compilers have a `src/check/Check.zig`. A bare `` `:1234` ``
continues the citation immediately before it. Roc line numbers are against commit `f083385b5b` and are
stable; `beni:` line numbers are against this branch, which is under concurrent edit, so treat them
as a starting point and search for the named symbol if one has drifted. Read §9 first if you are about to write code; it is the
payload, and the rest is its evidence.

## 0. Findings

- **Roc's constraint record is 88 bytes, not 12.** `StaticDispatchConstraint`
  (`roc:src/types/types.zig:1066`) carries name, function var, a tagged `Origin` with per-kind payloads,
  provenance, a derived-map plan and interpolation metadata; the size is pinned by a test
  (`roc:src/types/types.zig:49`). The spec's 5-field record is the right *starting* shape, but three of
  Roc's extra fields exist for reasons the spike will meet: origin class drives the principality
  rule (§2), provenance is what lets a diagnostic point at the user's own expression (§7), and
  neither participates in type identity. (§1)
- **The August-2026 principality fix is shipped, and it is not "keep several constraints per
  name".** It is a *partition by origin class*: same-name constraints unify through one
  representative if **any** of them is declarative (a `where` clause, an operator desugaring, a
  literal conversion); a group of plain `.m()` dot-calls stays separate, one constraint per use
  (`roc:src/check/unify.zig:3757-3825`). The spec's invariant 3 ("at most one constraint per name") is
  therefore *right for `where` clauses and wrong for dot-calls*, and the difference is exactly the
  program report 18 §2.2 quoted. (§2.3, §9)
- **Evidence slots dedupe by method name, not by constraint.** `emitConstraints`
  (`roc:src/check/dispatch_evidence.zig:510-543`) emits **one** evidence param per `(dispatcher var,
  method name)` even when the var carries several same-name constraints, and a call whose
  constraint is not the representative is marked `independent_callable`
  (`roc:src/check/static_dispatch_registry.zig:1344-1357`). This is the bridge between the two bullets
  above and it is not in the spec. (§3.4)
- **Canonical evidence order is a depth-first walk of the resolved type, not a quantifier list —
  and it is followed by a worklist over the constraints' own function types.** A constraint's
  `fn_var` can bind further constrained variables (`where [a.iter : a -> i, i.next : …]`), so
  `enumerateEvidenceParamsWithRequirements` drains a queue after the root walk
  (`roc:src/check/dispatch_evidence.zig:211-241`). beni's §7.2 rule ("quantifier order, then name
  text") has no second phase and no story for a dispatcher that the scheme body cannot reach. (§3.3,
  §9)
- **A generalised scheme is a pair: the root type *plus* an explicit side table of requirements.**
  `roc:design.md:5461-5478` is unambiguous that traversing the root alone is insufficient, because a
  requirement's receiver can belong to an enclosing scope while its callable mentions scheme-owned
  variables. The spec's §6.4 ("constraints ride on `Flags`, so `generalize` carries them for free")
  is the case Roc found was not enough. (§4.3, §9)
- **Rollback of constraints really is a length truncation** (`roc:src/types/store.zig:515`), speculation
  never nests (`roc:src/types/store.zig:425`), and sorting is by **ident text**, never by ident index,
  with the reason spelled out in a comment: "Evidence order must survive import/copy remapping, but
  `Ident.Idx` ordering is local to one interner" (`roc:src/check/unify.zig:3634-3639`). Spec invariants
  2 and §6.5 rule 1 are confirmed by Roc's code, for Roc's own reasons. (§1.3, §2.2)
- **Report 18 §2.4's complaint is still true, and the code says exactly why.** A missing-method
  report highlights `constraint.fn_var`'s region (`roc:src/check/report.zig:2494-2500`), and for a
  `where`-clause constraint that variable *is the callee's annotation node*
  (`roc:src/check/Check.zig:15100-15110`); instantiating at a caller copies the original region across
  (`:6845-6858`). Roc's own test corpus reproduces it. `provenance.intro_expr` does not fix it — it has
  sixteen call sites inside `Check.zig` but **`report.zig` never reads it**, and
  `reportConstraintErrorAt` builds the missing-method payload from `fn_var`, `fn_name` and `origin`
  alone (`roc:src/check/Check.zig:39984-40000`). The information the user needs is
  on the *obligation* (`DeferredConstraintCheck.failure_expr`, `roc:src/check/unify.zig:3954-3956`), which
  the report does not consult. (§7.2, §9 row S3-11)
- **The non-specialising backend passes hidden parameters holding pointers to vtable records — both of
  the spec's candidate encodings, in that order.** `.boxy` binds one leading `opaque_ptr` argument per
  *dictionaries span* — a worker parameter "supplies one or more method dictionaries"
  (`roc:src/postcheck/boxy/plan.zig:293`) and one local backs every index in its span
  (`roc:src/postcheck/boxy/lower.zig:12628-12633`); forwarding through a generic-calls-generic
  edge is literally "pass the caller's own hidden local through", with no materialisation statement
  (`:26800-26812`) and no notion of depth — the two-number `EvidenceChainIndex { depth, index }` is
  `.lss`-only. Roc needed program-wide interned method slots to make records of differing shapes
  interchangeable (`roc:src/postcheck/boxy/plan.zig:410-422`); the spec's N-separate-arguments encoding
  avoids that machinery entirely. (§6.3, §6.6, §9 rows S4-2 to S4-4)
- **`where` aliases shipped in August 2026**, closing report 18 §2.4's last open item
  (`roc:design.md:3014-3027`, `roc:src/canonicalize/Statement.zig:192-206`). Roc decided in July 2026 to see
  how much of an issue not naming a constraint set would be; the answer arrived within a month.
  (§9 row X-1)
- **Roc's solver has no iteration budget for constraint solving.** `checkStaticDispatchConstraints`
  drains an unbounded queue and terminates *structurally*, via two lineage detectors — an exact
  repeat of a dispatch-state digest and a strict-embedding growth test
  (`roc:src/check/Check.zig:30281-30378`). The `1 << 20` bound the spec keeps is a different mechanism
  answering the same question, and the spec's demand that reaching it report is right; the debug
  guard Roc does have (`roc:src/types/debug.zig:12`, 100k iterations) panics rather than reports. (§8)

## 1. Data representation

### 1.1 Where a constraint lives

On the variable, in the content, exactly as the spec proposes. `Flex` and `Rigid` are two-field
structs and the second field is the constraint range:

```zig
// roc:src/types/types.zig:302-330
/// A flex var, with optional static dispatch constraints
pub const Flex = struct {
    name: ?Ident.Idx,
    constraints: StaticDispatchConstraint.SafeList.Range,
    …
    pub fn withConstraints(self: Flex, constraints: StaticDispatchConstraint.SafeList.Range) Flex {
```

`Rigid` is the same with a non-optional `name` (`roc:src/types/types.zig:332-350`). A `Range` is
`{ start: Idx, count: u32 }` — eight bytes, a half-open run of one flat list
(`roc:src/collections/safe_list.zig:41-46`). The list is a single per-store column,
`static_dispatch_constraints: StaticDispatchConstraint.SafeList` (`roc:src/types/store.zig:161`),
appended through `appendStaticDispatchConstraints` (`roc:src/types/store.zig:1102`) and read through
`sliceStaticDispatchConstraints` (`roc:src/types/store.zig:1173`).

This is beni's spec §6.1 invariant 1 already: two flat tables, a range, never a map. The one
difference is that Roc has **one** level of indirection where the spec has two — Roc's `Flex`
carries the `Range` inline (8 bytes), while the spec carries a `ConstraintSet` enum(u32) indexing a
`constraint_sets: ArrayList(Range)`. The spec's extra level buys a 4-byte `Flags` instead of a
12-byte one; Roc paid the 8 bytes and its `Descriptor` is still 32
(`roc:src/types/types.zig:34`, a pinned-size test). Either is defensible; the spec's claim that
`Descriptor` does not grow is confirmed by the analogous Roc numbers.

### 1.2 What a constraint carries

```zig
// roc:src/types/types.zig:1066-1101
pub const StaticDispatchConstraint = struct {
    /// the dispatch fn name
    fn_name: Ident.Idx,
    /// the dispatch fn var, a function
    fn_var: Var,
    /// the origin of this constraint (operator, method call, where clause, or
    /// literal). …
    origin: Origin,
    /// Where this constraint was introduced, so ambiguity can be reported at the
    /// user's own expression without reconstructing var->expr maps after the
    /// fact. … This is METADATA: it is deliberately excluded from type identity
    provenance: Provenance = .{},
    derived_map_plan: ?DerivedMapPlan = null,
    interpolation: InterpolationMetadata = .none,
};
```

`@sizeOf(StaticDispatchConstraint) == 88`, asserted at `roc:src/types/types.zig:49` with a comment
explaining that the `Origin` union dominates because the literal variant embeds a whole
`NumeralInfo`.

Four things to take from this record:

1. **`fn_name` + `fn_var` is the whole of the type-level content.** The method's type *at this use*
   is a variable in the same store as everything else, so "check the constraint" is just "unify two
   variables". Identical to the spec's `MethodConstraint { name, fn_var }`.
2. **`origin` is a tagged union with payloads inside the variant**, not a flat enum beside extra
   fields (`roc:src/types/types.zig:1182-1225`). Variants: `desugared_binop { negated: bool }`,
   `desugared_unaryop`, `method_call`, `where_clause { body_required: bool }`,
   `from_literal: LiteralInfo`. The spec's `origin: enum(u8) { dot_call, well_known, where_clause,
   type_dispatch }` maps onto this, but `well_known` conflates Roc's `desugared_binop` with the
   `from_literal` family and **loses the `body_required` bit**, which is load-bearing (§2.3).
3. **`provenance.intro_expr`** is a raw `CIR.Expr.Idx` stored as a plain `u32` with a `maxInt`
   sentinel, because `types` sits below `canonicalize` in the layering and cannot name the type
   (`roc:src/types/types.zig:1094-1101`). Its comment states the purpose exactly: "so ambiguity can be
   reported at the user's own expression without reconstructing var->expr maps after the fact."
   The spec's `region: Bir.Inst.Index` is the same field under another name.
4. **Metadata is explicitly outside type identity.** `provenance`, `derived_map_plan` and
   `interpolation` are excluded from the canonical type key (`roc:src/check/canonical_type_keys.zig:1073-1096`
   hashes only `fn_name`, the `fn_var` structure and the origin tag) and from unification's
   content-equality. Two structurally identical constraints with different provenance stay equal.
   The spec has no equivalent statement and should acquire one, because `Site` is in its
   `MethodConstraint` and `Site` must not affect the interface bytes.

### 1.3 Allocation, merging, and speculative rollback

Sets are **append-only** and merging appends a third range, exactly as the spec's invariant 2
requires. `unifyStaticDispatchConstraints` (`roc:src/check/unify.zig:3488-3540`) computes
`const top: u32 = @intCast(self.types_store.static_dispatch_constraints.len());`, appends the
survivors, and returns `rangeToEnd(top)`. Neither input range is touched.

Speculation is a savepoint over the store. `Savepoint` records the constraint list's length among
the other append-only lengths:

```zig
// roc:src/types/store.zig:334-345
pub const Savepoint = struct {
    slot_trail_len: usize,
    desc_trail_len: usize,
    root_meta_trail_len: usize,
    union_rank_trail_len: usize,
    vars_len: usize,
    record_fields_len: usize,
    tags_len: usize,
    interpolation_parts_len: usize,
    static_dispatch_constraints_len: usize,
```

and rollback is a single truncation:

```zig
// roc:src/types/store.zig:515
self.static_dispatch_constraints.items.shrinkRetainingCapacity(savepoint.static_dispatch_constraints_len);
```

Descriptors themselves roll back through a replayed undo trail in reverse (`roc:src/types/store.zig:469-500`)
— beni's journal. Two details worth copying:

- **Probes never nest**: `std.debug.assert(!self.savepoint_active)` at `roc:src/types/store.zig:425`.
  beni's `TypeStore.mark`/`rollback` allows nesting by depth; Roc's flat rule is what lets one
  `usize` per list be the whole rollback state.
- **The checker's own side tables roll back too, and there are 23 of them**
  (`roc:src/check/Check.zig:25285-25340`), twenty-three lengths in all. A probe shrinks `deferred_static_dispatch_constraints`,
  `instantiation_dispatchers`, `ambiguity_candidates`, `dispatch_target_instantiations`,
  `generated_codec_derivations` and more. **This is the part of rollback the spec does not mention
  at all**: the spec says rollback stays "a length truncation" of the constraint table, which is
  true of the *store*, but beni's dispatch-site builder (§7.1) is also a side table appended to
  during discharge, and a speculative unification that registers an obligation and is then rolled
  back must not leave a `Dispatch.Site` behind. See §9, row S3-5.
- There is a debug-only cross-check that rollback is exact: `createSavepointVerifying` clones the
  whole store and `rollbackToSavepoint` byte-compares (`roc:src/types/store.zig:394-402`, `:527-529`).

## 2. Unification

### 2.1 The three sites, and what each one does

`unify.zig`'s dispatch on `a`'s content is at `roc:src/check/unify.zig:770-800`; the constraint rules
live in `unifyFlex` (`:859-908`), `unifyRigid` (`:909-936`) and `unifyStructure` (`:1039-1050`).
Reproduced in control-flow order:

| `a` | `b` | What happens | Line |
|---|---|---|---|
| flex | flex | `unifyStaticDispatchConstraints(a.constraints, b.constraints)`, merge into one flex with the merged range and the first non-null name | `:873-877` |
| flex | rigid | `recordDeferredConstraint(vars, a_flex.constraints)`, then merge to the **rigid** | `:878-881` |
| flex | alias | if the flex has **no** constraints, merge to the alias; otherwise **re-unify against the alias's backing var** so the constraints are not lost | `:882-890` |
| flex | structure | `recordDeferredConstraint`, merge to the structure | `:891-894` |
| flex | `err` | **`return error.ErroneousType` if the flex carries any constraint**, else merge to `err` | `:902-905` |
| rigid | flex | `recordDeferredConstraintOn(vars.a.var_, b_flex.constraints)` — note: **on `a`**, the rigid, not on `b` | `:918-921` |
| rigid | rigid | `error.TypeMismatch` unconditionally; constraint sets are never consulted | `:922-926` |
| rigid | alias | expand the alias and re-unify | `:927-932` |
| structure | flex | `recordDeferredConstraint(vars, b_flex.constraints)`, merge to the structure | `:1043-1046` |

Three observations the spec should absorb.

**Nothing fails at unification time.** Every meeting of a constrained flex with something concrete
becomes a *deferred* entry; the only immediate failures are `rigid`/`rigid` (which is an ordinary
mismatch, not a constraint failure) and constrained-flex-meets-`err`. The spec's Rule U2 says
"flex vs rigid: every constraint on the flex must be present by name on the rigid … else
`missing_where_constraint`", checked *in* `unify`. Roc does not check there — it defers, and the
rigid arm of the discharge loop does the name-presence check (§3.1). This matters for the spec's
own §6.2 rollback story: a `missing_where_constraint` raised from inside `unify` fires during
speculative unification too, and a speculation that is rolled back would have already reported.
Roc's comment says exactly this, at the top of `recordDeferredConstraint`:

> ```zig
> // roc:src/check/unify.zig:546-554
> /// NOTE: if flex-side dispatch constraints ever start FIRING mid-unify
> /// instead of deferring here, revisit `structurallyIncompatiblePair` (bottom
> /// of this module)—the defaulting pre-filter's soundness fence relies on
> /// this deferral.
> ```

**An alias is not transparent to constraints.** A constrained flex meeting an alias does not merge;
it re-unifies against the alias's backing variable, "so we don't loose static dispatch constraints"
(`roc:src/check/unify.zig:887`), and the symmetric arm in `unifyAlias` does the same
(`roc:src/check/unify.zig:951-957`). The spec's §6.3 handles aliases at *discharge* ("discharge against
`actual`"), which is equivalent, but the spec's Rule U3 lists `alias` among the contents that merely
register an obligation — under beni's interned-alias representation, merging a constrained flex
*into* an alias descriptor and then discharging against `actual` is fine, because `resolved()`
looks through. Worth an explicit note rather than an accident.

**The deferred entry is recorded against `b`, deliberately.**

```zig
// roc:src/check/unify.zig:545-561
/// Record a deferred constraint check for later verification.
/// Always uses b's var for error regions (via unresolved_b) because b represents
/// the "actual" type from the user's code, while a represents the "expected" type
/// (e.g., from a function signature). When constraints aren't satisfied, we want
/// to highlight where the user's code is, not the constraint's origin.
fn recordDeferredConstraint(…) {
    const dispatcher_var = self.unresolved_b orelse vars.b.var_;
    return self.recordDeferredConstraintOn(dispatcher_var, constraints);
}
```

This is an expected/actual polarity rule, and it is the same instinct as the spec's "report at the
flex's region — the call in the body that needs the method" (§6.2 Rule U2). Roc reaches it by
choosing *which variable owns the obligation*; the spec reaches it by choosing *which region the
message prints*. Roc's is the stronger form, because the region then falls out of the variable.

### 2.2 flex ⊓ flex, in detail

```zig
// roc:src/check/unify.zig:3488-3506
fn unifyStaticDispatchConstraints(self, a_constraints, b_constraints) Error!Range {
    // Early exits for empty ranges
    if (a_len == 0 and b_len == 0) return .empty();
    else if (a_len == 0 and b_len > 0) return b_constraints;
    else if (a_len > 0 and b_len == 0) return a_constraints;

    const partitioned = try self.partitionStaticDispatchConstraints(a_constraints, b_constraints);
    …
```

The three early exits are free: an unconstrained side hands the other side's **existing** range
straight through, with no copy. Only a genuine two-sided merge allocates. The spike's M1a
measurement ("what does dispatch cost code that never uses it") is answered by that first line: one
length comparison.

The merge itself sorts both sides into index arrays and merge-joins them by **name text**:

```zig
// roc:src/check/unify.zig:3629-3650
fn lessThan(context: @This(), a_index: u32, b_index: u32) bool {
    const a = context.constraints[a_index];
    const b = context.constraints[b_index];
    if (!a.fn_name.eql(b.fn_name)) {
        // Evidence order must survive import/copy remapping, but
        // Ident.Idx ordering is local to one interner.
        return Ident.textLessThan(…a.fn_name…, …b.fn_name…);
    }
    // Put declarative/defaulting relations before independent
    // dot-call relations so each same-name group can be matched
    // with a linear scan.
    const a_is_method_call = a.origin == .method_call;
    const b_is_method_call = b.origin == .method_call;
    if (a_is_method_call != b_is_method_call) return !a_is_method_call;
    // Preserve producer order within each semantic class.
    return a_index < b_index;
}
```

That comment is beni's §6.5 rule 1 and rule 2, written by someone who hit the problem: **never order
by interner index**. It is worth noting that `StaticDispatchConstraint.sortByFnNameAsc` /
`orderByFnName` (`roc:src/types/types.zig:1240-1250`) exist and are **dead** — nothing in the tree calls
them; the live ordering is this comparator.

Note also the shape of the result: the merged range is `only_in_a` appended, then `only_in_b`
appended (`roc:src/check/unify.zig:3533-3540`). Each half is name-sorted, the concatenation is **not**.
Roc's stored order is therefore deterministic but not canonical, which is fine for Roc (one thread
per module, and the canonical order is recomputed by a separate walk, §3.3) and would **not** be
fine for beni, where the interface record's bytes are hashed. The spec's answer — sort at the two
boundaries, not on every merge (§6.1 invariant 4) — is correct and is what Roc effectively does too.

### 2.3 Same-name constraints after the principality fix

This is the part report 18 §7 could not establish from Zulip. The fix shipped, and it is not what
the Zulip thread described. Report 18 §2.2 quoted Feldman as proposing "allow several constraints on
the same method name". What `partitionStaticDispatchConstraints` actually does
(`roc:src/check/unify.zig:3600-3849`) is partition each same-name group **by origin class**:

```zig
// roc:src/check/unify.zig:3599-3607, on partitionStaticDispatchConstraints
/// Match relations that deliberately share one callable type while leaving
/// independent same-name method calls separate. When a same-name group
/// contains any declarative relation (where clause, literal, or operator),
/// the whole group unifies through one representative declarative; a group
/// of dot calls alone stays separate so each use can instantiate a selected
/// rank-1 method scheme independently.
```

The algorithm, per same-name group:

1. **Arity and effect pre-check.** Every constraint in the group whose `fn_var` already resolves to
   a function head must agree on argument count and on effectfulness, or the whole unification is
   `error.TypeMismatch` (`roc:src/check/unify.zig:3709-3746`). The comment: "A rank-1 method scheme has
   one fixed outer function shape. Its quantified types may instantiate differently at each call,
   but instantiation cannot change argument count or a known effect mode."
2. **Split declarative from `method_call`.** The sort has already put declaratives first, so this is
   a scan (`:3748-3757`).
3. **If any declarative is present**: pick the first as the representative, retain one declarative
   *per semantic origin class* (`retainDeclarativeStaticDispatchConstraint`, `:3578-3592`, which
   folds metadata into an existing same-class entry rather than appending a duplicate), and push
   **every other member of the group, dot-calls included, into `in_both` paired with the
   representative** — i.e. unify them all against it (`:3763-3806`).
4. **If the group is dot-calls only**: keep every one of them, on both sides, separately
   (`:3807-3824`). This is the principality fix. `f1(l)` and `f2(l)` from the Zulip repro each keep
   their own `map` constraint at their own instantiation.

`sameDeclarativeOriginClass` (`roc:src/check/unify.zig:3884-3902`) defines the classes: `where_clause`
with `where_clause`; `desugared_unaryop` with itself; `desugared_binop` only when the `negated` bits
agree; `from_literal` only for the same literal kind, and **interpolation never with itself**,
because "each interpolation carries its own part vars and source regions". `method_call` matches
nothing, including itself.

`mergeStaticDispatchConstraintMetadata` (`:3905-3936`) is what makes the fold lossless: numeral
fit-sets are intersected, `body_required` is OR'd, and a missing `provenance.intro_expr` is filled in
from the constraint being folded away.

Then the pairs are unified, one at a time, with a recursion guard that is **separate from the
general unification visited set**:

```zig
// roc:src/check/unify.zig:3543-3570
fn unifyStaticDispatchConstraint(self, a_constraint, b_constraint) Error!void {
    // Self-referential constraints like `a.plus : a, a -> a` are valid and expected.
    // To prevent infinite recursion when unifying them, we track visited constraint
    // function variables in the scratch visited_vars list.
    if (self.hasConstraintVisitedVar(a_constraint.fn_var) or self.hasConstraintVisitedVar(b_constraint.fn_var)) {
        return;
    }
    _ = try self.scratch.constraint_visited_vars.append(self.scratch.gpa, a_constraint.fn_var);
    _ = try self.scratch.constraint_visited_vars.append(self.scratch.gpa, b_constraint.fn_var);
    defer self.scratch.constraint_visited_vars.items.items.len -= 2;
    try self.unifyGuarded(a_constraint.fn_var, b_constraint.fn_var);
}
```

And one more subtlety, easy to get wrong: the loop over `in_both` is **index-based, re-fetching each
iteration**, because unifying a pair can recursively grow the same scratch buffer
(`roc:src/check/unify.zig:3509-3520`). The same pattern recurs four more times in the discharge loop, each with its own comment
(`roc:src/check/Check.zig:31388`, `:31424`, `:31486`, `:32199`). Any beni implementation that holds a
`[]MethodConstraint` slice across a `unify` call has the same bug.

## 3. Resolution

### 3.1 The drain loop

`Check.checkStaticDispatchConstraints(env, is_numeric_default_pass)` (`roc:src/check/Check.zig:31332`)
is `dischargeObligations`. It is called from eleven places — every generalisation boundary, the
literal-defaulting pass, module finalisation (`roc:src/check/Check.zig:11440`, `:13243`, `:13989`,
`:14040`, `:18013`, `:20080`, `:25181`, `:26946`, `:28666`, `:28776`, `:31328`).

Its shape is beni's, with one structural difference:

```zig
// roc:src/check/Check.zig:31337-31349
const scratch_deferred_top = self.scratch_deferred_static_dispatch_constraints.top();
defer self.scratch_deferred_static_dispatch_constraints.clearFrom(scratch_deferred_top);
…
// The drain runs until the queue is exhausted. Termination is structural:
// every re-deferred relation keeps a still-flex receiver whose eventual
// grounding consumes it, and every fresh child edge passes the lineage
// detectors, which reject an exact repeated state or a strictly grown
// re-entry of the same binding before it can extend the queue further.
var deferred_constraint_index: usize = 0;
while (deferred_constraint_index < env.deferred_static_dispatch_constraints.items.items.len) : (deferred_constraint_index += 1) {
```

Index-based, re-reading `.len` every round — identical to beni's `dischargeObligations`
(`beni:src/check/Solve.zig:1258-1280`). At the end, the queue is cleared and the *unresolved* entries are
appended back:

```zig
// roc:src/check/Check.zig:32433-32439
// Now that we've processed all constraints, reset the array
env.deferred_static_dispatch_constraints.items.clearRetainingCapacity();
// Copy any flex constraints to try again later
try env.deferred_static_dispatch_constraints.items.appendSlice(
    self.gpa,
    self.scratch_deferred_static_dispatch_constraints.sliceFromStart(scratch_deferred_top),
);
```

**This is the difference.** beni's `dischargeObligations` clears the list unconditionally at the end
of a rank; an obligation on a still-flex variable is folded into the variable's `Flags` and the list
entry is dropped. Roc keeps the *queue entry* alive across passes, because a `DeferredConstraintCheck`
carries more than the constraint — `failure_expr`, `waiting_on_target_def`, `owner_group_index`
(`roc:src/check/unify.zig:3951-3972`) — and those would be lost. For beni the spec's fold is fine as long
as `Site` really is on the constraint (§6.1), which it is.

### 3.2 The switch, arm by arm

`dispatch_resolution: while (true)` at `roc:src/check/Check.zig:31366`. Compare against the spec's §6.3
table directly:

| `dispatcher_content` | Roc | Line | Spec §6.3 |
|---|---|---|---|
| `err` | mark every constraint `static_dispatch_rejected`, mark the var erroneous, stop | `:31367-31374` | "silence" — same, plus Roc records a durable rejection bit |
| `rigid` | build `ident_to_var_map` from the rigid's own constraint set, then per deferred constraint: present → `unify(rigid_var, constraint.fn_var)`; absent → `missing_method` | `:31375-31460` | matches Rule U2 / the `rigid` rows exactly |
| `structure.nominal_type` | §3.3 below | `:31462-31862` | the `app T args` row |
| `alias` | resolve the alias's own `origin_module`, look the method up **on the alias declaration**, and only fall back to the backing var for the derivable names | `:31863-32188` | spec says "discharge against `actual`" — **narrower than Roc**, see §9 row S3-7 |
| `record`, `record_unbound`, `tuple`, `tag_union`, `empty_record`, `empty_tag_union` | derivable names only (`is_eq`, `to_hash`, `map`, `map!`, `parser_for`, `encoder_for`), each gated on a component-supports check; anything else → `missing_method` | `:32189-32385` | matches, except Roc derives on `record_unbound` (an open record) too |
| `flex` | append to the scratch list, retry next pass | `:32386-32391` | spec folds into the var's set instead |
| everything else (`func`, `field_presence`, …) | per constraint: `is_eq` → `reportEqualityError`, else `.not_nominal`; an empty constraint list is `std.debug.assert(false)` | `:32392-32425` | matches the `func` row |

Two spec-relevant details in that table:

- **Roc derives for an *open* record.** The `record_unbound` arm (`roc:src/check/Check.zig:32190-32195`)
  is in the same branch as closed records. The spec's §6.3 explicitly refuses an open record
  (`no_methods_on_shape`, "an open record's field set is not yet known, so neither the shape key nor
  the field obligations can be computed"). `record_unbound` in Roc is a *closed-by-construction*
  record literal shape, not a row-polymorphic one, so the two are probably not in conflict — but the
  spec should say which of beni's record forms it means, because beni's `Structure.Record` has an
  `ext` that is `empty_record` or a variable and the distinction is the whole rule.
- **The `err` arm records a durable bit, not an `err` type.** `markStaticDispatchRejected` sets
  `Descriptor.flags.static_dispatch_rejected` on the *equivalence class* of the constraint's
  `fn_var` (`roc:src/types/types.zig:105-110`), and `roc:design.md:8853-8871` explains why a raw var index
  cannot carry it: "a union-find root is not stable across later merges, so a raw-keyed set answers
  'rejected' for whichever occurrence happened to be recorded and misses every other member of the
  same class." beni's spec has `Target.err` on the *site* and no class-level marker. With one
  constraint per name and no shared callables, beni may not need one; with §2.3's declarative
  representative it might.

### 3.3 Looking a method up on a nominal type

Two steps: find the owning module env, then binary-search its method table.

**Owner resolution is by content identity, never by name.**

```zig
// roc:src/check/Check.zig:20784-20788
/// Resolve the module env that declares a type from the type's content-based
/// origin identity. No name matching: two envs share an owner entry only when
/// their transitive module content is byte-identical, in which case they are
/// interchangeable as type owners by definition.
fn ownerEnvForOriginModule(…)
```

`NominalType.origin_module` is a `ModuleIdentity.Idx` carried on the type itself
(`roc:src/types/types.zig:355-360` for the alias analogue), and `self.owner_envs_by_identity.get(origin_hash.*)`
is the lookup (`roc:src/check/Check.zig:20802`). beni's `Types.Entry.module`
(`beni:src/check/Types.zig:55-65`) is the same field with a `Graph.Index` instead of a content hash.

**The method table is a sorted array keyed on `(owner module ident, owner decl statement, method
ident)`** — `MethodDefs = SortedArrayBuilder(MethodKey, MethodBinding)`
(`roc:src/canonicalize/ModuleEnv.zig:586-591`), built at canonicalisation (§5.5), read by
`lookupMethodBindingFromOwnerAndMethodEnvsConst` (`roc:src/canonicalize/ModuleEnv.zig:5797-5812`). Its
doc comment is the load-bearing sentence for beni's §6.3.1:

> "This keeps method implementation lookup explicit **without requiring local associated methods to
> be published through the module exposure table**." — `roc:src/canonicalize/ModuleEnv.zig:588-590`

That is exactly the spec's §6.3.1 step 2 finding — do not go through `Interface.Provenance`, because
it only maps `pub` entries and a private method would be invisible. Roc reached the same conclusion
and solved it with a separate table rather than by reading the Bir.

**The search is not one env.** `lookupStaticDispatchMethodBinding` (`roc:src/check/Check.zig:20735-20760`)
tries, in order: the owner env, the module being checked, then **every** imported module env:

```zig
for (self.imported_modules) |candidate_env| {
    if (candidate_env == owner_env or candidate_env == self.cir) continue;
    if (self.lookupStaticDispatchMethodBindingInEnv(candidate_env, owner_env, …)) |found| return found;
}
```

This is Roc's *receiver extension* mechanism (§5.5): a module can register a method against a type it
does not own, provided the owner is a nominal declaration whose body is an empty closed tag union.
**beni's spec has no equivalent and should not acquire one** — it is a coherence hole (which import
set is in scope changes which method runs), and the spike's "module rule" (a method of `T` is a `pub`
value in `T`'s module) is the tighter rule. Worth recording as a deliberate divergence, not an
oversight.

Then, in order (`roc:src/check/Check.zig:31536-31852`):

1. `staticDispatchBindingIsDerivedMarker` — the owner declared `method : _`, so derive
   (`:31549`). Per-name: `is_eq` requires `nominalSupportsStructuralDerive(.equality)`, `to_hash`
   the `.hash` variant, `parser_for`/`encoder_for` a shape check that can answer
   `.supported` / `.unresolved` / `.unsupported`, with `.unresolved` **re-deferring the whole
   obligation** (`:31600-31603`).
2. `rejectValuelessMethodDispatch` — the declaration is annotation-only with no body
   (`:20711-20733`).
3. The local-def status machine (`:31694-31770`): `not_processed` / `processing` / `processed`, with
   a predeclared scheme var used for polymorphic recursion, and an unannotated unchecked target
   causing `deferDispatchObligationForUncheckedTarget`. **This is a real cost beni will meet**: a
   dispatch edge is not in the name graph, so a method call can reach a declaration the checker has
   not typed yet, and the module's own declaration order does not help.
4. `resolveDispatchTargetMethodVar` (`:31772-31782`) — instantiate the target scheme.
5. `unifyInContext(method_var, constraint.fn_var, …, .method_type { constraint_var, dispatcher_name,
   method_name })` (`:31786`, and the ordinary-path call at `:31815`) — the unify that either
   succeeds or produces the diagnostic.

Step 5 has a wrinkle worth knowing about: when the receiver's type is a *defaulted literal* that the
program never chose, the unify is bracketed in a probe and rolled back on failure, "because the
failed validation must not retype anything the relation's argument graph reaches"
(`roc:src/check/Check.zig:31819-31822`).

### 3.4 Derivation for structural shapes

The whole table of derivable names is one array:

```zig
// roc:src/check/static_dispatch_registry.zig:1316-1323
pub const structural_method_kinds = [_]struct { method_name: [:0]const u8, common_ident: [:0]const u8, kind: StructuralKind }{
    .{ .method_name = "is_eq", .common_ident = "is_eq", .kind = .equality },
    .{ .method_name = "to_hash", .common_ident = "to_hash", .kind = .hash },
    .{ .method_name = "parser_for", .common_ident = "parser_for", .kind = .parser },
    .{ .method_name = "encoder_for", .common_ident = "encoder_for", .kind = .encoder },
    .{ .method_name = "map", .common_ident = "map", .kind = .map },
    .{ .method_name = "map!", .common_ident = "map_bang", .kind = .map_effectful },
};
```

Note what is **not** on it: `compare`/`is_lt`. Roc's ordering is numeric-only by the decision report
07 recorded, so there is no derived total order to generate. beni's spike derives `compare` for every
nominal type and every structural shape (spec §9), which is a larger derivation surface than Roc has
ever shipped — §9 row S6-1.

`is_eq` on an anonymous structural type is guarded by `typeSupportsIsEq(structure)` and, if it holds,
`satisfyDerivedIsEqConstraint` (`roc:src/check/Check.zig:32206-32215`); the failure path is the dedicated
`reportEqualityError` rather than the generic missing-method message
(`:32216-32222`). The comment says the rule plainly: "Anonymous structural types (records, tuples,
tag unions) have derived `is_eq` only if all their components also support `is_eq`"
(`:32196-32198`).

### 3.5 Canonical evidence order

`src/check/dispatch_evidence.zig` is the file the spike plan cites for evidence order, and it is
worth reading in full. Its header states the contract:

```
// roc:src/check/dispatch_evidence.zig:1-27
//! Every scheme with dispatch constraints gets one ordered param list: index
//! `k` in that list is the identity a dispatch plan's `constraint(k)`
//! resolution and a call edge's k-th evidence entry both refer to. The order
//! is defined purely by the scheme's type structure, so the definition's own
//! module and a caller holding a structural copy of the scheme … enumerate
//! identical lists without sharing var identities.
//!
//! Order contract: depth-first over the resolved type structure—function
//! args then return, ordinary alias/nominal args then backing, and logical row
//! fields/tags across the complete extension chain, all in store order—
//! emitting one target parameter per dispatcher/method at the constrained
//! var's first occurrence; then every independent constraint fn type is walked
//! the same way in source order (they can bind further constrained vars,
//! e.g. `where [a.iter : a -> i, i.next : ..]`).
```

Four things follow, and three of them are not in beni's §7.2.

**(a) It is a walk of the type, not an enumeration of quantifiers.** `walk`
(`roc:src/check/dispatch_evidence.zig:246-320`) is an explicit stack over the resolved content, pushing
children in declared order: alias args then backing, nominal args (never the backing — the comment at
`:293-297` says a nominal application's structure is its args), tuple elems, function args then
return, record fields and tag payloads across the whole extension chain. A constrained variable emits
its params **at first occurrence**, deduped by a `visited` set on the resolved root
(`:261-263`). beni's §7.2 "in the order `Schemes.Writer` records them" is the *same* order by
construction — `Schemes.Writer` discovers quantifiers by walking the body — so this is agreement, but
the spec should say it is a walk, because the next three points depend on that.

**(b) Same-name constraints share one slot.**

```zig
// roc:src/check/dispatch_evidence.zig:510-543
fn emitConstraints(…) {
    scratch.emitted_methods.clearRetainingCapacity();
    for (store.sliceStaticDispatchConstraints(constraints)) |constraint| {
        const emitted = try scratch.emitted_methods.getOrPut(gpa, constraint.fn_name);
        if (!emitted.found_existing) {
            try out.append(gpa, .{ .dispatcher_var = dispatcher_root, .constraint = constraint, … });
        }
        // A shared target does not make the callables interchangeable: each
        // one can expose further independently constrained variables.
        try scratch.fn_var_queue.append(gpa, .{ .var_ = constraint.fn_var, … });
    }
}
```

The dedupe key is `fn_name` alone, with the rationale at `:141-145`: "Runtime evidence selects a
method *target*, not one particular instantiation of that target's callable scheme. Independent
same-name calls therefore share this receiver-local slot while retaining their own callable relations
in the checked plans." The site that is *not* the representative records
`independent_callable: true` and instantiates the shared target against its own callable
(`roc:src/check/static_dispatch_registry.zig:1344-1357`, `:1540-1546`). **This is the mechanism that makes
§2.3's principality fix compatible with a fixed evidence ABI**, and it has no analogue in the spec.

**(c) There is a second phase, over the constraints' own function types.** Every emitted constraint's
`fn_var` is queued, and after the root walk the queue is drained — index-based, because `walk` can
grow it:

```zig
// roc:src/check/dispatch_evidence.zig:227-241
// Constraint fn types can bind further constrained vars; the queue holds
// every emitted constraint's fn var in emission order. `walk` may grow the
// queue while we drain it—index-based drain keeps that sound.
var queue_index: usize = 0;
while (queue_index < scratch.fn_var_queue.items.len) : (queue_index += 1) {
    …
    try walk(gpa, store, queued.var_, source, scratch, out);
}
```

beni's §7.2 has no second phase. Under beni's §2.4 closure rule (a `where` clause's variables must be
quantifiers of the scheme) the second phase is a no-op for *annotated* declarations. It is not a
no-op for inferred ones, and inferred `pub` schemes are exactly what the spike exists to measure.

**(d) Each param carries a `path` from the scheme root to the dispatcher.** `PathStep`
(`roc:src/check/dispatch_evidence.zig:41-69`) is `{ kind: u32, data: u32 }` with kinds `fn_arg`,
`fn_ret`, `alias_arg`, `alias_backing`, `nominal_arg`, `nominal_backing`, `tuple_elem`,
`record_field`, `tag_payload_tag`, `tag_payload_index` — rows addressed by *label*, "because row
order differs between checked and monomorphic types". The path exists because
"compiler-generated call edges — structural-derivation component calls, builtin helper calls — have
no checked instantiation records, so monotype resolves a target's obligations by walking these paths
over the concrete monomorphic callable instead" (`:23-27`). An empty path is explicit and means the
dispatcher is reachable only through a constraint's fn type, or is an erased open-row remainder
(`:88-97`). beni's spike emits derived functions from the checker rather than synthesising call edges
later, so it probably does not need paths — but the *reason* Roc needs them is worth knowing before
S6 decides how a derived `eq` for `Maybe a` gets its element evidence.

### 3.6 Where the result is stored

Per module, in `StaticDispatchPlanTable` (`roc:src/check/static_dispatch_registry.zig:1755-1800`) — flat,
index-based, sorted-for-binary-search, serialisable. It is beni's `Dispatch` record at ten times the
size:

| Roc field | Line | beni `Dispatch` equivalent (spec §7.1) |
|---|---|---|
| `plans: []StaticDispatchCallPlan` | `:1756` | `sites: []Site` |
| `by_expr: []PlanKV` "sorted by key" | `:1758` | `sites` sorted by `(inst, evidence_index)` |
| `evidence_nodes: []EvidenceNode` | `:1782` | `Target.top` / `Target.ext` plus nested evidence |
| `evidence_refs: []CheckedEvidence` | `:1784` | — (beni has no nested evidence) |
| `site_evidence: []SiteEvidenceEntry` sorted by key | `:1786` | `decl_evidence: []Range` + the per-site `evidence_index` |
| `template_root_evidence` | `:1795` | — |
| `generated_codec_derivations` | `:1798` | `derived: []Derived` |
| `operand_pool` | `:1778` | — (beni keeps args in the Bir) |

And the per-site resolution is beni's `Target`, one-for-one plus three. **Annotated, not verbatim** —
Roc's own doc comments on each variant are replaced below by the beni equivalent:

```zig
// roc:src/check/static_dispatch_registry.zig:1529-1555 — doc comments replaced by beni mapping
pub const CheckedCallResolution = union(enum) {
    direct_pending: EvidenceNodeId,          // construction-only; never serialised
    direct_closed: DirectCall,               // beni: top / ext
    direct_parametric: DirectCall,           // beni: top / ext, but the callable is still open
    evidence_dependent: struct {
        scheme_param: ?u32 = null,
        index: EvidenceChainIndex,           // beni: evidence: u16 — but see §6
        independent_callable: bool = false,
    },
    structural: StructuralDerivation,        // beni: derived
    checked_error,                           // beni: err
    @"unreachable",                          // beni: —
};
```

Two gaps. **`direct_closed` vs `direct_parametric`** is the distinction between a resolved target
whose callable is fully ground and one that still mentions variables the enclosing specialisation
supplies; beni's backend does not specialise, so it collapses, but the checker still has to know
which case it is in to decide whether to emit evidence arguments at the site. **`@"unreachable"`** is
a dispatcher no instantiation can ever supply — Roc lowers it to a crash. beni's spec has
`ambiguous_method_receiver` as a note; the `@"unreachable"` case is the sub-case where it is
provably not an ambiguity but dead code, and the spec does not separate them.

## 4. The artifact and the interface

This is the section that maps onto `Interface.Quantified` and spec §6.5. Roc has **two** boundary
mechanisms and they must not be conflated:

| Path | Carrier | Read by |
|---|---|---|
| **A. the `ModuleEnv` cache** — `types.Store` serialised verbatim | `roc:src/types/store.zig:1695`, `roc:src/canonicalize/ModuleEnv.zig:874` | the **type checker** of a downstream module, through `copy_import.zig` |
| **B. the checked artifact** — `CheckedTypeStore` | `roc:src/check/checked_artifact.zig:2668`, `:5348` | post-check lowering and monomorphisation |

Path A is beni's `Interface`. Path B has no beni analogue; the spike's `Dispatch` table plays that
role and never crosses a module boundary at all.

### 4.1 What is written for a constrained quantifier

**Path A writes the whole 88-byte record, verbatim, in store order.** `Store.Serialized` has
`static_dispatch_constraints: StaticDispatchConstraint.SafeList.Serialized`
(`roc:src/types/store.zig:1695`), written at `:1715`, relocated at `:1803`. Nothing is projected,
filtered or reordered; `provenance`, `derived_map_plan` and `interpolation` all go out. Padding
inside the `Origin` union is zeroed for byte-determinism by `SafeList.zeroPadding`
(`roc:src/collections/safe_list.zig:152-159`), which explicitly handles "unions (tail padding, variant
overshoot)".

**Path B projects to three fields:**

```zig
// roc:src/check/checked_artifact.zig:2668-2680
pub const CheckedStaticDispatchConstraint = struct {
    fn_name: canonical.MethodNameId,   // interned method name, not an Ident.Idx
    fn_ty: CheckedTypeId,              // hash-consed checked type, not a Var
    origin: types.StaticDispatchConstraint.Origin,
};
```

`provenance`, `derived_map_plan` and `interpolation` are **dropped** at
`roc:src/check/checked_artifact.zig:8947-8969` (`copyCheckedStaticDispatchConstraints`).

**Neither boundary sorts.** Constraints are written in the order the store holds them — which §2.2
showed is not arbitrary (`partitionStaticDispatchConstraints` sorts both input sides by ident text,
`roc:src/check/unify.zig:3625-3668`, and writes the survivors back in that order), but is also not a
canonical name order, because a merge concatenates two separately-sorted halves. What matters here is
that *the boundary itself* applies no ordering, and downstream equality depends on position: structural equality zips the two lists positionally
(`roc:src/check/checked_artifact.zig:3787-3793`), and both `writeConstraints`
(`roc:src/check/checked_artifact.zig:7882-7897`) and the canonical type key
(`roc:src/check/canonical_type_keys.zig:1077-1090`) hash elements in list order — the key's length
prefix is written one frame earlier, at `:535`.

**This is the one place the spec is clearly right and Roc is clearly wrong for beni's purposes.**
Roc can get away with producer order because a module is checked on one thread and its output is
therefore reproducible. beni's §8.1 has M4 *hashing the interface bytes*, and beni checks modules on
many threads. §6.5 rule 1 — "sorted by name text, never by symbol id" — is required, and the spec's
reasoning (`Symbol` numbering depends on which worker interned which file) is exactly the reasoning
in Roc's own unifier comment (`roc:src/check/unify.zig:3634-3635`), just applied one layer further out.
`StaticDispatchConstraint.sortByFnNameAsc` exists in Roc (`roc:src/types/types.zig:1241`) and is dead
code; beni should make its equivalent live.

### 4.2 How an importing module instantiates it

`copy_import.zig` is beni's `Schemes.instantiate` plus `makeCopy`. The memo is
`VarMapping = collections.DenseMap(Var, Var)` keyed by *resolved* root
(`roc:src/check/copy_import.zig:40`, gate at `:346-380`). Flex and rigid funnel into one shared
`pushIdentity` (`:505-529`) that short-circuits an empty list and otherwise pushes a frame walking
the constraints one at a time.

The constraint loop (`roc:src/check/copy_import.zig:591-673`) is the pattern beni's `copyHelp` needs.
**Paraphrase, not a verbatim quote** — the trailing comments are mine and intermediate lines are
elided:

```zig
.head => {
    const source_constraint = frame.source_constraints[frame.idx];
    frame.pending = source_constraint;                    // every field copied
    frame.pending.fn_name = try ctx.copyIdent(source_constraint.fn_name);
    frame.stage = .await_fn;
    if (!try request(ctx, source_constraint.fn_var)) return false;  // the SAME memo
},
…
.await_fn => {
    frame.pending.fn_var = machine.values.pop().?;
```

— i.e. **`fn_var` is deep-copied through the same memo as the rest of the type**, which is precisely
the spec's §6.4 warning ("or instantiation will share a method type between two instantiations and
the two uses will be wrongly unified"). Rigid and flex get identical treatment.

Three rewrites happen at the boundary, and beni needs all three:

- `fn_name` is re-interned into the destination ident store (`:593`);
- every var in `interpolation` and `derived_map_plan.tag_name` is re-copied/re-interned (`:599-649`);
- **`provenance` is cleared** (`:650-654`): *"The introducing expression is module-scoped: its index
  refers to the SOURCE module's CIR and is meaningless here."* beni's `MethodConstraint.region` is a
  `Bir.Inst.Index` with exactly the same problem, and `Site` likewise. The spec does not say what
  happens to them on instantiation from an interface; §6.5 says each constraint created by an
  instantiation is tagged with the instruction that caused it, which is the right answer — but it
  must be stated as *overwritten*, not *carried*.

Every copied var lands **already generalised** — `finishFrame` hardcodes `.rank = Rank.generalized`
(`roc:src/check/copy_import.zig:550-557`) — and the copy is cached once per `(module, node)` in
`self.import_cache` with the warning *"The caller must instantiate this variable before unifying
against it"* (`roc:src/check/Check.zig:24495-24497`). beni's `importedValue` (`beni:src/check/Solve.zig:1049-1059`)
already has this shape.

### 4.3 Generalisation and promotion — where the spec is short

`src/types/generalize.zig` **does not touch constraints at all**. Rank adjustment refuses to descend:

```zig
// roc:src/types/generalize.zig:420-430
.flex => {
    // Here, we start at group_rank (since flex should be generalized).
    // Constraints are deliberately not descended into.
    try self.settleRank(fill.desc_idx, group_rank);
    return true;
},
```

Constraints are kept, not sorted, not deduplicated, and a constraint's `fn_var` does not drag the
receiver's rank down. Everything interesting happens in `Check.zig` instead, in two steps the spec
has one of.

**Dedup** — `deduplicateGeneralizedDispatchRequirements` (`roc:src/check/Check.zig:27773`), called at the
four generalisation boundaries (`:13571`, `:13946`, `:18040`, `:21613`). The key is
`{ fn_name, origin tag, origin flag, 32-byte callable-shape digest }`; duplicates are **unified
first** so the union-find records the substitution, then the survivors are re-appended as a fresh
range and installed with `flex.withConstraints(retained_range)` (`:27869-27877`). Order among
survivors is preserved by stable read/write compaction.

**Promotion** — `captureSchemeDispatchRequirements` (`roc:src/check/Check.zig:28361-28471`), and this is
the finding. A generalised scheme in Roc is **not** just its root type:

> "A generalized scheme is a pair: its root type and the unresolved static-dispatch requirements
> created while checking that definition. A requirement records its receiver and its callable
> relation. **This representation is necessary when the receiver belongs to an enclosing scope: the
> callable relation can contain scheme-owned argument, result, and literal variables even though
> traversing the root type alone cannot reach them.**"
>
> `roc:design.md:5461-5468`

The promotion rule itself:

```zig
// roc:src/check/Check.zig:28427-28439
break :blk switch (candidate.source) {
    .creation => created: {
        if (receiver.desc.rank == rank) {
            try undecided.append(self.gpa, candidate_idx);
            break :created false;
        }
        break :created @intFromEnum(receiver.desc.rank) < @intFromEnum(rank);
    },
    // A copied relation is detached from its receiver descriptor.
    .scheme_copy => true,
};
```

A receiver at the boundary's *own* rank is **undecided**, because whether it escapes is only proved
by rank adjustment; `captureEscapedSchemeDispatchRequirements` (`:28477`) re-judges those right after
`generalize`. Promoted requirements land in `type_schemes[i].dispatch_requirements` (`:28455-28462`),
deduped against existing entries by resolved receiver root + resolved fn root + name (`:27686-27701`),
and a guard panics if this runs inside a solver probe (`:28368-28370`).

The side table is then read back by `enumerateEvidenceParamsWithRequirements`, which appends the
explicit requirements **after** the root walk in producer order (`roc:src/check/dispatch_evidence.zig:203-241`).

beni's §6.4 says constraints ride on `Flags` and `generalize` carries them for free. For the vars
that *are* quantified that is true. The case Roc's side table exists for is the one where they are
not: an inner declaration whose constraint sits on an outer-rank receiver but whose `fn_var` mentions
the inner declaration's own quantifiers. Two instantiations of the inner scheme then share one
constraint and are wrongly unified — which is the same failure the spec already guards against in
`copyHelp`, one scope out. See §9, row S3-4.

For the on-disk shape of a promoted requirement, Roc persists only the *generated-codec* ones
(field list reproduced; Roc's own doc comments on the struct are elided):

```zig
// roc:src/canonicalize/ModuleEnv.zig:874-888 — fields only
pub const BindingSchemeCodecRequirement = extern struct {
    node_idx: u32,
    scheme_root: u32,
    receiver_var: u32,
    constraint_index: u32,      // raw index into the serialized constraint list
    requires_instantiation: u32,
    is_synthetic: u32,
};
```

with the comment (`:867-873`) that `constraint_index` "names the exact `StaticDispatchConstraint` in
this environment's serialized `TypeStore`; import copying therefore preserves the complete callable
graph and metadata without reconstructing either from the receiver's final shape." beni's
`Quantified { constraints_start, constraints_len }` is the same idea with the range on the quantifier
instead of a parallel table — which is fine **provided** every promoted constraint really does hang
off a quantifier.

### 4.4 Version pinning

Two guards worth copying into beni's §8.1 interface work. `serialized_layout_version: u32 = 95`
(`roc:src/check/checked_artifact.zig:31346`) feeds a `SERIALIZED_VERSION_HASH`
(`roc:src/check/checked_artifact.zig:31356`) computed from a recursive structural fingerprint of the
serialised types (`roc:src/check/artifact_serialize.zig:354`), so changing
`CheckedStaticDispatchConstraint`'s field order invalidates every cached artifact; it is checked on
load by `expectSerializedVersion` (`roc:src/check/checked_artifact.zig:31367-31376`). And `validateOffsetLen` / `validateSerialized`
(`roc:src/check/artifact_serialize.zig:253-270`) overflow-safely bounds-check every `(offset, len)`
against the blob before any dereference, yielding `error.CorruptArtifact`.

## 5. Canonicalisation

### 5.1 The node, and the in-place rewrite

Canonicalisation **never** resolves a value-receiver dispatch. It emits a syntactic node with no
target slot:

```zig
// roc:src/canonicalize/Expression.zig:386-396
/// Method call expression.
///
/// ```roc
/// list.map(transform)
/// ```
e_method_call: struct {
    receiver: Expr.Idx,
    method_name: Ident.Idx,
    method_name_region: base.Region,
    args: Expr.Span,
},
```

and the checker **rewrites that node in place** into the resolved form:

```zig
// roc:src/canonicalize/Expression.zig:397-404
e_dispatch_call: struct {
    receiver: Expr.Idx,
    method_name: Ident.Idx,
    method_name_region: base.Region,
    args: Expr.Span,
    constraint_fn_var: TypeVar,
    surface_origin: SurfaceOrigin,
},
```

via `NodeStore.replaceExprWithDispatchCall` (`roc:src/canonicalize/NodeStore.zig:2135-2156`), whose only
callers are in `Check.zig` (`:20071`, `:20129`, `:23755`, `:23829`). The node **tag** is the
before/after marker: `expr_method_call` vs `expr_dispatch_call`
(`roc:src/canonicalize/Node.zig:74-82`), with `ExprDispatchCall` carrying exactly one extra `u32`
(`roc:src/canonicalize/Node.zig:733-745`). Args, the method-name region and the surface origin live in a
five-word side record, `MethodCallData` (`roc:src/canonicalize/NodeStore.zig:417-426`).

That is beni's design already: the spec's `method_call` BIR instruction carries `{ name, args }` and
nothing else, and the resolved target goes in the separate `Dispatch` table (§7.1). The one
difference is that Roc *mutates the node* and beni keeps the answer in a side table. beni's choice is
better here — `Bir` is an output (`dump --stage=bir` is corpus-tested) and an instruction whose tag
changed during checking would make the dump depend on whether the checker ran.

### 5.2 Field access versus method call is decided by the **parser**

`roc:src/parse/Parser.zig:3867-3893`: after a `DotLowerIdent`/`NoSpaceDotLowerIdent` the parser looks
ahead for `NoSpaceOpenRound`; if it is there the state becomes `method_apply`, otherwise the token is
folded into a field-access path. Canonicalisation only mirrors that decision
(`roc:src/canonicalize/Can.zig:11965-11994` vs `:12081-12092`).

This confirms the spike's §1.1 rule ("`x.m a b` is a method call; `x.m` with no arguments stays a
field access; `(x.m) a` is always a field call") is implementable with one token of lookahead, and
that the receiver's type is never needed. It also shows the cost: `e_field_access` in Roc is a
*maximal contiguous path* (`roc:src/canonicalize/Expression.zig:371-385`), so `a.b.c.m(x)` parses as one
field-access node with segments `b, c` and one method call on it. beni's lowering recognises "an
`apply` whose head is a `field_access`" (plan §5.1), which needs the same flattening decision.

### 5.3 The receiver-unknown case

There is no representation for it, because it is the only case: the node has no target slot until
the checker writes one. Within the checker there are still two paths
(`roc:src/check/Check.zig:20054`):

```zig
const resolve_method_first = !did_err and self.varResolvesToKnownType(receiver_var);
```

If the receiver's type is already known, the method is resolved **before** the arguments are checked,
so arguments check against the declared parameter types (publish at `:20071`). Otherwise arguments
are checked first and a constraint is recorded (publish at `:20129`). **The spec does not mention
this split, and it is a real quality decision**: without it, `xs.map (\x -> x.field)` type-checks the
lambda against a fresh variable and loses the field's type. See §9, row S3-9.

### 5.4 Return-type dispatch: `module(a).m(...)` does not exist

The form in the vendored tree is **`Thing.m(args)` via a type-variable alias**:

```zig
// roc:src/canonicalize/Statement.zig:222-240
/// A type variable alias within a block - enables static dispatch on type vars.
/// ```roc
/// foo : thing -> Str
/// foo = |arg|
///     Thing : thing       # Type var alias
///     Thing.something(arg) # Static dispatch using the type var alias
/// ```
s_type_var_alias: struct {
    alias_name: Ident.Idx,
    type_var_name: Ident.Idx,
    type_var_anno: CIR.TypeAnno.Idx,
},
```

The alias statement is created at `roc:src/canonicalize/Can.zig:10137-10176`; the call node itself is
built at `roc:src/canonicalize/Can.zig:8467-8474` and `roc:src/canonicalize/Can.zig:13653-13658`,
producing `e_type_method_call` whose "receiver"
is a **statement index**, not an expression (`roc:src/canonicalize/Expression.zig:447-461`), rewritten by
the checker into `e_type_dispatch_call` with a `constraint_fn_var` (`:462-468`,
`roc:src/check/Check.zig:20237`).

This is the **one** place canonicalisation partially resolves a dispatch: it resolves the *owner*,
`typeDispatchOwnerStatement` (`roc:src/canonicalize/Can.zig:8479-8498`), by scanning scopes for a type-var
alias — plus a special case where an ordinary type alias becomes a dispatch owner *only* for
`parser_for`.

Two consequences for the spike's §4:

- Report 18 §3 described this as `module(a).decode(bytes)`. That syntax is gone. The shipped form is
  a **statement** binding an uppercase name to an annotation's type variable, which is closer to the
  spec's `type_dispatch { var, name, args }` than to anything report 18 described. The spec's §4.1
  should cite this, not the 2025 Zulip syntax.
- The spec's `type_dispatch: lhs = SymbolIndex of the type variable` (plan §5.2) is Roc's design
  minus the binding statement. Roc needs the statement because the alias is a *scope* entry the
  formatter can round-trip; beni resolves the variable directly out of the annotation. beni's is
  simpler and there is no evidence it is wrong.

### 5.5 Operator desugaring — and where it does *not* happen

**The binop → method-name table is not in `canonicalize/`.** Canonicalisation keeps `e_binop`
(`roc:src/canonicalize/Expression.zig:362`, `:726-750`) and desugars only `and`/`or` (into `e_if`,
`roc:src/canonicalize/Can.zig:13323-13350`) and unary `!` (into a hard-wired `e_call` to `Bool.not`,
`roc:src/canonicalize/Can.zig:13233-13234`, `:14478-14506` — **not** a dispatch).

The names are interned in `ModuleEnv.CommonIdents` (`roc:src/canonicalize/ModuleEnv.zig:239-350`); the
mapping switch is in the checker (`roc:src/check/Check.zig:23196-23217` arithmetic, `:23290-23311`
comparisons, `:23399` equality, `:23421-23467` inequality, `:23342-23345` ranges, `:23141-23153`
unary minus). The full table:

| Surface | Method | Line |
|---|---|---|
| `+` `-` `*` `/` `//` `%` | `plus` `minus` `times` `div_by` `div_trunc_by` `rem_by` | `roc:src/canonicalize/ModuleEnv.zig:241-246` |
| unary `-` | `negate` | `:247` |
| `<` `<=` `>` `>=` | `is_lt` `is_lte` `is_gt` `is_gte` | `:251-254` |
| `==` | `is_eq` | `:255` |
| `!=` | `is_eq` then `not` — *"`a != b` desugars to `a.is_eq(b).not()`"* | `roc:src/check/Check.zig:23421-23467` |
| `..<` `..=` | `range_exclusive_to` `range_inclusive_to` | `:256-257` |
| numeric literal | `from_numeral` | `:345` |
| string literal | `from_quote` | `:346` |
| interpolation | `from_interpolation` | `:347` |
| derived | `to_hash` `parser_for` `encoder_for` `map` `map!` `to_inspect` | `:258-262`, `:342-347` |

Two things beni should copy and one it should not.

**Copy: `SurfaceOrigin` on the resolved node.**

```zig
// roc:src/canonicalize/Expression.zig:756-770
/// The surface syntax a dispatch call was desugared from, recorded as
/// explicit CIR data so re-emission can reproduce the operator form.
/// Operator forms carry contracts the method-call form does not (e.g.
/// arithmetic binops: `ret = lhs`), so re-emitting them as `.method()`
/// calls would weaken the program.
pub const SurfaceOrigin = union(enum) { method_call, binop: Binop.Op, unary_minus };
```

beni's spec §1.3 has a `well_known` *flag* on the BIR instruction, which records that the call came
from an operator but not **which** operator. The formatter, `fmt`, and every diagnostic that wants to
say "`==`" rather than "`eq`" need the operator back. Roc's diagnostics do exactly that —
`getOperatorForMethod` (defined `roc:src/check/report.zig:5332`, called `:2605-2611`). See §9, row S3-10.

**Copy: the comparison-result restriction.** `roc:design.md:3005-3012` states the rule and the reason:

> "`|a, b| a == b` infers `c, c -> Bool where [c.is_eq : c, c -> Bool]`, whereas `|a, b| a.is_eq(b)`
> infers `c, d -> e where [c.is_eq : c, d -> e]`. Restricting comparison results to `Bool` also keeps
> inferred signatures simple … Replacing operators with unrestricted method-call sugar would change
> these intentional typing rules."

The operator form pins both argument types to each other *and* the result to `Bool`. beni's spec §3.1
lowers `==` to the well-known `eq`; if it lowers to exactly the same constraint a hand-written
`a.eq b` produces, inferred schemes get looser and noisier than they need to be.

**Do not copy: the receiver-extension rule.** §5.6.

### 5.6 The method set is built at canonicalisation, and it is wider than "the declaring module"

```zig
// roc:src/canonicalize/ModuleEnv.zig:588-591
/// Mapping from (receiver owner declaration, method_ident) pairs to the method binding.
/// This keeps method implementation lookup explicit without requiring local
/// associated methods to be published through the module exposure table.
pub const MethodDefs = SortedArrayBuilder(MethodKey, MethodBinding);
```

`MethodKey` is `(owner module ident, owner declaration statement, method ident)`
(`roc:src/canonicalize/ModuleEnv.zig:526-571`) — beni's `(TypeId, name)`, so the spike plan's claim that
"a block form is a front-end change only" is confirmed by construction.

Two registration kinds (`roc:src/canonicalize/Can.zig:1010-1041`):

- **`declaration_owner`** — the method is defined inside the type's associated `.{ }` block. This is
  the spike's module rule.
- **`receiver_extension`** — the method's *first parameter type* names some other declaration, so it
  is **also** registered as a method on that type (`receiverMethodOwnerFromFunctionAnno`,
  `roc:src/canonicalize/Can.zig:1117-1129`). Restricted: builtins are excluded (`:1158`),
  builtin-role modules cannot declare extensions (`:1104-1105`), and the target must be a nominal
  declaration whose body is an **empty closed tag union** — a pure namespace type (`:1107-1114`).

Precedence is settled at canonicalisation: declaration-owner beats receiver-extension regardless of
source order (`:1085-1094`); two receiver extensions on one key emit a `shadowing_warning` and the
later wins (`:1095-1098`); two declaration-owners panics as an internal invariant (`:1067-1073`).

And at lookup time (§3.3) the checker searches the owner env, then the current module, then **every
imported module** (`roc:src/check/Check.zig:20752-20758`). So Roc's coherence guarantee is narrower than
report 18 §4.1 claims: which method `x.m()` resolves to can depend on which modules the *calling*
module imports, for types whose body is an empty tag union. The spike's module rule has no such hole
and should keep it.

## 6. Codegen

**The dispatch-resolving "backend" is `src/postcheck/`, not `src/backend/`.** `src/backend/dev`,
`src/backend/llvm` and `src/backend/wasm` decide nothing about dispatch and **know nothing about
types**: they lower `assign_call` (static), `assign_call_dict` (dictionary) and the rest of the
`assign_boxy_*` family (`roc:src/lir/LIR.zig:802-895`) as opaque shapes. The dev backend does a
little more than "lower" — it generates a dictionary-dispatch thunk per worker
(`roc:src/backend/dev/LirCodeGen.zig:20521`, `:24405-24717`) — but the thunk is emitted from the
plan's slot table, not from any type.

### 6.1 Two modes, one switch

```zig
// roc:src/base/SpecializationStrategy.zig:6-13
pub const SpecializationStrategy = enum {
    /// Lambda-set specialization: specialize polymorphism and callable flow
    /// before producing LIR.
    lss,
    /// Box closures and type-variable values, pass descriptor/dictionary data
    /// explicitly, and lower checked artifacts directly to LIR.
    boxy,
```

`--specialize=yes|no`, default `.lss` (`roc:src/base/SpecializationStrategy.zig:15-17`,
`roc:src/cli/main.zig:11735`). The branch is one switch, before any backend
(`roc:src/lir/checked_pipeline.zig:683-692`), and both modes then funnel into one
`finishLoweredOutput` (defined `:810`, called from the `.lss` path at `:807` and the `.boxy` path at
`:925`) that ends at the same LIR and the same backends. "Converge" is not quite right: that function
re-branches on the strategy at `:824-828` to run three `.lss`-only inlining passes.

**beni is in `.boxy`'s position**, exactly as report 07 said. So `.boxy` is the mode to read, and the
finding is that `.boxy` is **hidden runtime parameters holding pointers to vtable records** — both of
the spec's candidate encodings at once, in that order.

### 6.2 `.lss`: evidence is consumed at compile time

```
// roc:src/postcheck/monotype/lower.zig:798-804
/// One resolved dispatch requirement supplied to a specialization: either a
/// concrete method target … or a compiler-derived structural implementation.
/// Fully materialized at the requesting call edge—checked `constraint(k)` refs are
/// substituted from the requester's own evidence there—so a specialization's
/// vector is self-contained (dictionary passing evaluated at compile time).
```

A specialization's identity is `(callable, checked source fn-type digest, requested closed
monomorphic fn type)` (`roc:src/postcheck/monotype/specialize.zig:3-12`), and the `.lss` lowerer emits
**zero** `assign_call_dict` statements. Nothing here transfers to beni.

### 6.3 `.boxy`: hidden dictionary parameters

One worker per **definition**, not per instantiation: workers are keyed by `(WorkerSource,
checked_type)` where a procedure template's `checked_type` is its *scheme* type
(`roc:src/postcheck/boxy/plan.zig:2586-2613`, `:11847-11850`). Non-specialising, as advertised.

Hidden params are declared per worker as `HiddenDictionaryParam`
(`roc:src/postcheck/boxy/plan.zig:294-302`) and become real LIR argument locals:

```zig
// roc:src/postcheck/boxy/lower.zig:12611-12635  (bindHiddenDictionaryArgs)
for (params, layouts) |param, runtime_layout| {
    const layout_idx = runtime_layout.layoutIdx();
    if (layout_idx != .opaque_ptr) {
        boxyLowerInvariant("boxy hidden dictionary arg layout was not opaque_ptr");
    }
    const local = try self.addArgLocal(layout_idx);
```

That is beni's `$m$0 … $m$n-1` (spec §8.1) with the same shape and the same position: leading
parameters, added by the lowerer, invisible in the source language.

**Two distinct kinds of hidden parameter**, and conflating them is the trap:

| | Carries | LIR ref | Layout |
|---|---|---|---|
| **type descriptor** | representation/layout/RC/tag metadata for an erased variable | `LIR.BoxyDescRef` (`roc:src/lir/LIR.zig:95-106`) | `opaque_ptr` → `*const BoxyTypeDesc` |
| **method dictionary** | method implementations for a `where` constraint | `LIR.BoxyDictRef` (`roc:src/lir/LIR.zig:111-121`) | `opaque_ptr` → `*const BoxyDict` |

beni has no descriptors (JS values carry their own shape), so only the second column applies.

### 6.4 The dictionary at runtime

```zig
// roc:src/lir/program.zig:257-263
/// Runtime data for polymorphic behavior and static dispatch in boxy LIR.
pub const BoxyDict = struct {
    debug_dispatch_plan: ?dispatch.StaticDispatchPlanId = null,
    method_slots: BoxySpan = .{},
    hidden_descs: BoxySpan = .{},
    nested_dicts: BoxySpan = .{},
};
```

`method_slots` is a **span into a program-wide array**, not an inline record, and each slot holds an
integer proc id rather than a code address (`roc:src/lir/program.zig:240-255`). Slot indices are
**program-wide and stable** — `DictionaryRequirement.slot`
(`roc:src/postcheck/boxy/plan.zig:410-422`): *"Program-wide runtime slot for this checked method
spelling. The slot is stable across dictionaries with different requirement subsets"* — so a
dictionary carrying a superset of a callee's requirements satisfies it with no remapping
(`roc:design.md:7297-7305`). Lookup is `method_slots[slot]`, O(1), **and the method id is not even
compared** — a test pins that (`roc:src/eval/boxy_runtime.zig:7766-7778`: slot has `.method = 11`, the
call passes `required_method = 0`, and it still returns proc 3).

The call itself is one LIR statement (`roc:src/lir/LIR.zig:897-908`) that every backend lowers to a
single C-ABI call to `roc_boxy_call_dict` (`roc:src/eval/boxy_abi.zig:2223-2242`; dev
`roc:src/backend/dev/LirCodeGen.zig:18699-18779`, LLVM `roc:src/backend/llvm/MonoLlvmCodeGen.zig:3810-3868`,
wasm `roc:src/backend/wasm/WasmCodeGen.zig:9519-9570`). Argument order at the callee is: **explicit args,
then hidden descriptors, then nested dictionaries** (`roc:src/eval/boxy_runtime.zig:7657`, `:7699-7745`).

**What this tells the spike.** Report 18 §1.4 argued that the multi-method record encoding goes
megamorphic on a JS target and that N function arguments keep every call direct. Roc, on a native
target where a megamorphic property load is not the failure mode, chose the *record* — and then had
to add a program-wide slot interning scheme so that records of different shapes are still
interchangeable. The spec's choice of N arguments (plan §0) avoids that machinery entirely, at the
cost of an arity that varies with the constraint set. Nothing in Roc's code argues against the spec's
choice; the slot-interning scheme is the price of the one it did not make.

### 6.5 Derived function bodies

**No Roc source text is ever generated.** The checker decides *that* it derives (`StructuralKind`,
`roc:src/check/static_dispatch_registry.zig:1271-1278`) and the lowerer decides *how*. Four different
answers, which is itself the finding:

| Method | `.lss` | `.boxy` |
|---|---|---|
| `is_eq` | Monotype IR, generated lazily, memoised per `(value_ty, result_ty)` | **no code at all**: the slot is `structural_eq = true` with `proc` left `undefined` (`roc:src/postcheck/boxy/lower.zig:1427-1452`), and the runtime walks the value against its descriptor (`boxyValuesEqual` → `valuesEqualWithDesc`, `roc:src/eval/boxy_runtime.zig:1830`, `:1852`) |
| `to_hash` | as above | generated as a synthetic LIR proc, **eagerly per representation**, at lower time (`structuralHashMethodSlot`, `roc:src/postcheck/boxy/lower.zig:3471-3545`) |
| `parser_for` / `encoder_for` | Monotype IR, deferred to graph sealing because row types may still carry live defaults (`emitDraftDeferredStructuralSerializations`, `roc:src/postcheck/monotype/lower.zig:8933`) | a generated LIR worker per shape, `WorkerSource.generated_codec` (`roc:src/postcheck/boxy/plan.zig:599-607`, body at `roc:src/postcheck/boxy/lower.zig:6270-6291`) |
| `map` / `map!` | Monotype IR | **rejected**: `boxyPlanInvariant("derived map evidence reached runtime dictionary planning")` (`roc:src/postcheck/boxy/plan.zig:9061`) |

The `.lss` derivation shape is the one worth reading for S6:

> "`is_eq` and `to_hash` share one recursive ladder: walk a type one layer at a time, decomposing
> aggregates (records/tuples/tag unions) and transparent nominals that have no exact component
> method. … **Recursion is broken by an expansion stack plus a memoized generated helper def.**"
>
> `roc:src/postcheck/monotype/lower.zig:49044-49072`

The generic driver is `lowerDerivation` (`:49077`), parameterised by comptime `Deriver` types —
`EqDeriver` (`roc:src/postcheck/monotype/lower.zig:56494`) supplies `leaf` (`:56534-56540`, emitting a
`.structural_eq` node) and `combine` (`:56546-56548`, folding components with `if`). The memo is
`defCache` (`:56510-56512`), keyed by `defAddress(value_ty, result_ty)` (`:56514-56516`) over
`GeneratedHelperDefAddress` (`:2863`), and sits deliberately *outside* the specialization index
(`roc:src/postcheck/monotype/specialize.zig:19-22`).

Two things this says about the spec's §9 and §6.3.1 step 4:

- **Roc derives lazily and memoises; the spec derives eagerly, for every nominal type in a module,
  used or not.** The spec's reasoning is sound and is a determinism argument: a request that
  travelled backwards to the declaring module would make that module's output depend on which other
  module got there first. Roc does not have that problem because derivation happens whole-program,
  after every module is checked. beni has no whole-program phase, so eager is the only choice — but
  the spec should record that it is trading output size for determinism, and that Roc's own answer
  is the opposite because its phase ordering is different. This is a real S4/S6 size cost the
  measurement plan (§7 M2) should attribute correctly.
- **One generic ladder, two `Deriver`s.** The spec writes `eq` and `compare` derivation separately
  in §9. Roc's comptime-parameterised single walk with `leaf`/`combine` hooks is a strictly smaller
  implementation and beni's `eq`/`compare` differ only in those two hooks.

### 6.6 Forwarding evidence through a generic calling a generic

This is the question the spike's §8.2 has to answer, and Roc answers it twice.

**`.lss`: a lexical evidence chain, resolved at compile time.** `EvidenceChainIndex { depth: u16,
index: u16 }` (`roc:src/check/static_dispatch_registry.zig:1336-1339`) where `depth` counts enclosing
generalized callables outward from the reference, 0 being innermost. Monotype models the frames as
`EvidenceChain` (`roc:src/postcheck/monotype/lower.zig:969-1001`); the scope wrapper above it,
`LexicalDispatchScope` (`:951-954`), carries the description — *"nested local functions see their own
vector at depth 0 and enclosing callables' vectors at higher depths, like compile-time captures"*.
`EvidenceChain.at` resolves a reference:

```zig
// roc:src/postcheck/monotype/lower.zig:992-1001
fn at(self: *const EvidenceChain, ref: static_dispatch.EvidenceChainIndex) ?SpecEvidence {
    var chain: *const EvidenceChain = self;
    var depth = ref.depth;
    while (depth > 0) : (depth -= 1) {
        chain = chain.parent orelse return null;
    }
    if (ref.index >= chain.vector.len) return null;
    return chain.vector[ref.index];
}
```

**`.boxy`: the caller's own hidden local is passed straight through.**

```zig
// roc:src/postcheck/boxy/lower.zig:26800-26812 — abridged
.bound_dictionaries => |dictionaries| blk: {
    const first: Plan.DictionaryRequirementId = @enumFromInt(dictionaries.start);
    if (!self.dictionaryBindingIsBound(first)) {
        boxyLowerInvariant("boxy direct call dictionary source was not bound in the enclosing worker");
    }
    …
    const dict_local = self.dictionaryLocalForRequirementOrNull(first) orelse
        boxyLowerInvariant("boxy direct call bound dictionary source had no local");
    break :blk .{ .local = dict_local };
},
```

No materialisation statement is emitted for the forwarding case; the `.static_rep` case emits
`assign_boxy_dict_ref` (`roc:src/postcheck/boxy/lower.zig:28154`, and the same statement is emitted
for other dictionary sources at `:11398` and `:16964`). The decision between forwarding and building a constant
dictionary is `DirectCallHiddenDictionaryArg.Source`
(`roc:src/postcheck/boxy/plan.zig:334-345`, chosen at `:8226-8250`), and the whole thing runs to a
fixpoint because discovering a dictionary can discover a worker which can discover more dictionaries
(`materializeDictionaryCallPlans`, `:6944-6993`).

**The spec is missing `depth`.** `Dispatch.Target.evidence: u16` (spec §7.1) is "the k-th evidence
parameter of the enclosing declaration" — one level. Roc needs two numbers because a lambda nested
inside a constrained declaration is itself a callable that can forward its enclosing declaration's
evidence. beni's backend lowers a nested lambda to a JS closure that captures `$m$k` lexically, so
`depth` may genuinely be unnecessary — but only if evidence parameters are *captured* rather than
*re-passed*, and the spec does not say which. See §9, row S4-1.

### 6.7 The interpreter

`src/eval/interpreter.zig` is a **LIR** interpreter and performs no type-directed lookup of its own.
Its `assign_call_dict` handler (`:2911-3016`) resolves the dict ref, then calls the *same*
`boxy_runtime.prepareDictCall` the C-ABI path uses (`:2945-2954`) — *"the same semantics back both the
LIR interpreter and machine-code output"* (`roc:src/eval/boxy_runtime.zig:1-6`). The only divergence is
how a proc id becomes a callee: `evalProcById` versus a registered thunk table
(`roc:src/eval/boxy_abi.zig:845-865`, `:2300-2302`).

## 7. Diagnostics

### 7.1 The variants

There are six, under one umbrella (`roc:src/check/problem/types.zig:547-554`):

```zig
pub const StaticDispatch = union(enum) {
    dispatcher_not_nominal: DispatcherNotNominal,
    dispatcher_does_not_impl_method: DispatcherDoesNotImplMethod,
    type_does_not_support_equality: TypeDoesNotSupportEquality,
    type_does_not_support_map: TypeDoesNotSupportMap,
    unresolved_dispatcher: UnresolvedDispatcher,
    recursive_dispatch: RecursiveDispatch,
};
```

plus four adjacent ones on the `where`-clause side —
`where_clause_receiver_not_introduced` (`roc:src/check/problem/types.zig:703-707`), `not_a_where_alias`
(`:683-686`), `where_alias_in_type_position` (`:689-692`), `recursive_where_alias` (`:696-699`) — and
`associated_item_not_found` (`:167-171`). A constraint-function *type* mismatch is **not** a
`StaticDispatch` variant at all: it is an ordinary `type_mismatch` with
`Context.method_type { constraint_var, source_region, dispatcher_name, method_name }`
(`roc:src/check/problem/context.zig:301-312`).

There are **no numbered error codes**: `Report` has `title`, `headline`, `severity`, `document` and
nothing else (`roc:src/reporting/report.zig:232-243`). Diagnostics are identified by an uppercased title
plus `file:line:col:line:col`.

Mapping onto the spec's ten codes (§10):

| Spec code | Roc |
|---|---|
| `unknown_method` | `dispatcher_does_not_impl_method` with `dispatcher_type = .nominal` |
| `private_method` | — (Roc's method table is not the exposure table, §5.6, so there is no private/public split to report) |
| `no_methods_on_shape` | `dispatcher_not_nominal` |
| `missing_where_constraint` | `dispatcher_does_not_impl_method` with `dispatcher_type = .rigid` — **effectively dead**, see below |
| `method_constraint_mismatch` | `type_mismatch` + `Context.method_type` |
| `where_variable_unbound` | `where_clause_receiver_not_introduced` |
| `duplicate_where_constraint` | — (merged instead, §2.3) |
| `type_dispatch_needs_annotation` | — |
| `ambiguous_method_receiver` | `unresolved_dispatcher` — but as an **error**, not a note |
| `constrained_constant` | — |

Two of those are worth pausing on. Roc's **`unresolved_dispatcher` is a hard error**, with a headline
of *"This is trying to dispatch a method named `to_i128` on an unresolved type variable, but
unresolved type variables have no methods"* and a hint offering an annotation. beni's spec makes the
analogous situation a **note under `--explain`**, because an unannotated `pub` declaration promotes
its constraints into the interface instead. That is a deliberate and correct divergence — beni
*supports* the polymorphic scheme Roc rejects — but it means the spike has no equivalent of Roc's
single most user-visible dispatch diagnostic, and the churn measurement (plan §7 M3) is the only
thing that will observe the cost.

And the spec's `duplicate_where_constraint` has no Roc analogue because Roc *merges* duplicates
(`retainDeclarativeStaticDispatchConstraint`, §2.3). Rejecting them is defensible; the spec should
note it is a choice.

### 7.2 Where the reports point — report 18 §2.4, re-tested against the code

**The complaint is still accurate at `f083385b5b`.** Roc has two location mechanisms and the
missing-method report uses the worse one.

Mechanism (1), **region-by-`Var`**: the payload stores a `Var`, and the report bit-casts it into a
`Region.Idx` and indexes a parallel side array (`roc:src/check/report.zig:216-219`, `:306-309`).
Mechanism (2), **region-in-payload**: the checker resolves an expression to a `base.Region` and
stores it.

`DispatcherDoesNotImplMethod` has no general `Region` field (`roc:src/check/problem/types.zig:598-615`),
so it is mechanism (1):

```zig
// roc:src/check/report.zig:2494-2500
// Add source region highlighting
if (self.getRegionSafe(@enumFromInt(@intFromEnum(data.fn_var)))) |region| {
    const region_info = self.module_env.calcRegionInfo(region.*);
    try report.document.addSourceRegion(
        region_info, .error_highlight, self.filename, self.source,
```

`data.fn_var` is `constraint.fn_var` — the variable modelling the *method's callable type*. Where its
region lives depends on the constraint's origin:

- `origin = .method_call`: `fn_var` is minted at the call site
  (`roc:src/check/Check.zig:24109-24129`, `mkReceiverDispatchFnVar` ending in
  `freshFromContent(..., region)`), so the region is **right**.
- `origin = .where_clause`: `fn_var` **is the callee's `where`-clause annotation node** —
  `const func_var = ModuleEnv.varFrom(method.anno);` (`roc:src/check/Check.zig:15100-15110`), with no
  provenance set.
- Instantiating the callee at a caller does **not** move it: same-module callees instantiate with
  `.use_last_var`, which explicitly copies the original var's region onto the fresh one
  (`roc:src/check/Check.zig:6845-6858`, `:20923`).

The corpus proves it — `roc:test/snapshots/where_clause_nested_obligation_missing_method_issue_9892.md`,
whose rendered output block begins at `:20`:

```roc
Wrap(a) := [W(a)].{
    unwrap : Wrap(a) -> Str where [a.frobnicate : a -> Str]
    unwrap = |Wrap.W(x)| x.frobnicate()      # line 3
}
run : b -> Str where [b.unwrap : b -> Str]
run = |v| v.unwrap()
main : Str
main = run(Wrap.W(42.U8))                     # line 10 — the actual mistake
```

```
MISSING METHOD - where_clause_nested_obligation_missing_method_issue_9892.md:3:28:3:38
```

The `U8` on line 10 is never underlined and never mentioned; the rendered body only says "The value's
type, which does not have a method named `frobnicate`, is: `U8`"
(`roc:src/check/report.zig:2507-2557`). That is the "game of spot-the-difference" of report 18 §2.4,
reproduced from the compiler's own test corpus.

**`provenance.intro_expr` does not fix it.** It is never read in `report.zig` or `problem.zig` — the
only hit in `report.zig` is an unrelated comment at `:4809`. It is resolved to a `Region` inside
`Check.zig` (`constraintIntroExpr`, `:10292-10300`) and feeds exactly one diagnostic,
`unresolved_dispatcher` (`:11039`, `:11137`, `:28173`). And for a `where_clause` constraint it is
deliberately stamped with the **callee's body dispatch**:

```zig
// roc:src/check/Check.zig:31433-31441
if (backing[i].origin == .where_clause and backing[i].fn_name.eql(constraint.fn_name)) {
    backing[i].origin.where_clause.body_required = true;
    // Stamp the where-clause constraint's provenance with the
    // body dispatch that forced it, so instantiated copies point
    // at a concrete dispatch use …
```

which is why `roc:test/snapshots/static_dispatch_scheme_position_matrix.md:45` reports at line 19, inside
the callee, when the mistake is on line 22.

`provenance.intro_expr` *is* read inside `Check.zig` — `constraintIntroExpr`
(`roc:src/check/Check.zig:10298-10300`) has sixteen call sites: `invalid_numeric_literal`
(`:34240`, `:34263`), `poisonConstraintFailureSource` (`:10312`), the
`InstantiationEvidence.dispatch_target.node_idx` slots (`:31056`, `:31214`, `:39622`), four
`recordAmbiguityCandidate` sites (`:23716`, `:23814`, `:24161`, `:24198`) and the
`unresolved_dispatcher` path (`:11039`, `:28173`). The load-bearing claim is narrower and survives
intact: **`report.zig` never reads it**, and the missing-method payload is never built from it.
`reportConstraintErrorAt` (`roc:src/check/Check.zig:39962-40016`) assembles
`dispatcher_does_not_impl_method` out of `fn_var`, `fn_name` and `origin` alone (`:39984-40000`); its
`explicit_error_expr` parameter reaches only `poisonConstraintFailure` (`:39977`, `:40014`) and never
the report.

There is exactly **one** path in the whole checker where a caller-side region is threaded into a
dispatch diagnostic: `MethodTypeContext.source_region`, populated at one of roughly nineteen
`.method_type` construction sites (`roc:src/check/Check.zig:39649-39657`) and consumed at
`roc:src/check/report.zig:3101-3105`. Every other site leaves it `null` and falls back to the type
variable's introduction site.

**What this means for the spec.** §6.2 Rule U2 already says `missing_where_constraint` is reported
"at the flex's region — the call in the body that needs the method … deliberately not at the
annotation", and §10.4 has the fixture. That is the right rule and Roc does not implement it. But the
example above shows the rule is not sufficient either: in the nested case, "the call in the body that
needs the method" **is** `x.frobnicate()` inside `unwrap`, which is where Roc already points and which
is still wrong. The information the user needs is the *instantiation site* — `run(Wrap.W(42.U8))` —
and that is not on the constraint at all; it is on the obligation. Roc's `DeferredConstraintCheck`
carries `failure_expr` for exactly this (`roc:src/check/unify.zig:3954-3956`: "The expression whose
instantiation created this obligation. Ordinary definition-site constraints have no owner and report
at their provenance") and then does not use it in the missing-method report. **beni's `Obligation`
should carry the instantiating instruction and the diagnostic should print both regions** — the call
that needs the method and the call that supplied the type. See §9, row S3-11.

### 7.3 No "did you mean"

The edit-distance machinery exists — `findBestTypoSuggestion` with `best_dist: u32 = 3`
(`roc:src/check/snapshot/diff.zig:181-202`) — and is wired to record fields (`roc:src/check/snapshot/diff.zig:597`) and tag names
(`:679`) only. No dispatch report calls it. The corpus proves the gap: `test/snapshots/static_dispatch/Adv.md`
misspells `update_str` as `update_strr` — edit distance 1, same type — and the output offers nothing.

beni's spec §6.3.1 step 5 already requires "listing the module's `pub` value names within edit
distance 2" and §10.1 has the fixture. Keep it; it is a place the spike can be better than the thing
it is copying, cheaply, because `checker.md` §8 already has the routine.

## 8. Budgets and guards

Roc's constraint solver has **no numeric iteration budget**. Five mechanisms do the job instead, and
they are worth listing because the spec has one of them.

**1. The drain loop is unbounded.** `while (deferred_constraint_index < env.deferred_static_dispatch_constraints.items.items.len)`
(`roc:src/check/Check.zig:31348`), with termination asserted structurally in a comment:

> "The drain runs until the queue is exhausted. Termination is structural: every re-deferred relation
> keeps a still-flex receiver whose eventual grounding consumes it, and every fresh child edge passes
> the lineage detectors, which reject an exact repeated state or a strictly grown re-entry of the
> same binding before it can extend the queue further." — `roc:src/check/Check.zig:31343-31347`

**2. The lineage detectors.** Two of them, both in `Check.zig`:

- `repeatedDispatchStateAncestor` (`:30281-30304`) — walks the constraint's explicit derivation chain
  and rejects an edge whose `(target env, target binding, method name, 32-byte state digest)` exactly
  matches an ancestor's.
- `dispatchStateGrowsAlongLineage` (`:30306-30378`; the doc comment quoted below is `:30306-30321`,
  the function itself `:30322-30378`) — a homeomorphic-embedding test. Its doc comment
  is the clearest statement of why a counter cannot do this job: *"a chain can pump either component
  (a growing receiver, or a constant receiver whose `where`-shape feeds an ever-deeper type through a
  non-receiver argument), and every such chain re-derives a strictly larger copy of the same
  obligation forever even though no two of its states are ever digest-equal."* One growth step is
  allowed (it may just be a call-site argument); a growth step whose embedded ancestor already grew is
  rejected.

Failure is a real diagnostic — `recursive_dispatch` (`roc:src/check/problem/types.zig:638-643`), built at
`rejectRecursiveStaticDispatch` (`roc:src/check/Check.zig:31021-31028`), carrying the matched ancestor's
receiver snapshot as `grown_from_snapshot` so the message can show both states.

**3. The occurs check does not follow constraints.** `roc:src/check/occurs.zig:263-265`:

```zig
.flex => {
    // Flex variables are not checked for cycles - they are allowed to have
    // self-referential constraints. Only structural content is checked.
},
```

Self-reference like `a.plus : a, a -> a` is normal and expected, so the cycle detection that matters
is the constraint-visited set inside `unifyStaticDispatchConstraint` (§2.3,
`roc:src/check/unify.zig:3544-3570`), kept *separate* from the general `visited_vars` "to match legacy
mark semantics".

**4. A debug-only iteration guard, which panics.** `IterationGuard`
(`roc:src/types/debug.zig:25-52`, with `MAX_ITERATIONS = 100_000` at `:12`), compiled out in release:

```zig
pub inline fn tick(self: *Self) void {
    if (builtin.mode == .Debug) {
        self.count += 1;
        if (self.count > MAX_ITERATIONS) {
            std.debug.panic("Infinite loop detected in type-checking at '{s}' after {d} iterations. …
```

Used in exactly the shape beni's `check/depth/` fixtures assume — e.g. `staticDispatchCallableHead`
(`roc:src/check/unify.zig:3862`).

**5. Structural size limits are the field widths.** `SafeRange.count` is `u32` and `SafeList.Idx` is
`u32`, so at most 2³²−1 constraints per range and per store; `appendSpan`
(`roc:src/check/artifact_serialize.zig:506-508`) `@intCast`s unchecked. There is **no** `max_constraints`
constant anywhere in `src/check` or `src/types`.

**Verdict for spec §6.3's Budget paragraph.** The spec keeps the `1 << 20` bound and adds the
requirement that reaching it *reports* `nesting_too_deep` and poisons, plus `@panic` in a debug build,
plus a `Parse.max_depth + 104` guard on the constraint chain. All of that is right, and Roc's code is
not an argument against any of it — Roc's structural termination argument is *stronger* but costs two
non-trivial algorithms (a 32-byte state digest and an embedding walk with pairwise cycle cuts) that
the spike does not need for the programs it will measure. The one thing worth importing is Roc's
diagnostic: a bound that fires should say *which two dispatch states* repeated, not just "too deep".
`recursive_dispatch`'s `grown_from_snapshot` is that message.

## 9. The mapping table

Roc mechanism → the spec section it informs → what beni has today → what differs, and which is
likely right. Rows are ordered by slice. **Bold** rows are the ones that look like spec defects.

### S3 — the checker

| # | Roc mechanism | Spec § | beni today | Difference, and the verdict |
|---|---|---|---|---|
| S3-1 | `Flex.constraints` / `Rigid.constraints` as a `Range` on the content (`roc:src/types/types.zig:305`, `:334`) | §6.1 | `TypeStore.Flags { name, kind, equatable }` (`beni:src/check/TypeStore.zig:148-158`) | The spec's extra indirection (`ConstraintSet` → `constraint_sets: ArrayList(Range)`) keeps `Flags` one word narrower than Roc's inline `Range`. Both work; Roc's is one fewer load. **Spec is fine**; the M1a claim that `Descriptor` does not grow is confirmed by Roc's own pinned sizes (`roc:src/types/types.zig:34`). |
| S3-2 | append-only sets, merge appends a third (`roc:src/check/unify.zig:3524-3540`); rollback is `shrinkRetainingCapacity` (`roc:src/types/store.zig:515`) | §6.1 inv. 2 | journal + `rollback` (`beni:src/check/TypeStore.zig:563-585`) | **Confirmed by Roc, for Roc's own reasons.** One addition: Roc asserts savepoints never nest (`roc:src/types/store.zig:425`); beni's journal has a `depth`. If beni keeps nesting, the constraint-table truncation must be per-snapshot, not a single length. |
| S3-3 | **`partitionStaticDispatchConstraints`: declarative constraints share one callable; dot-calls stay separate** (`roc:src/check/unify.zig:3599-3607`, `:3807-3824`) | §6.1 inv. 3, §6.2 U1, §11 stretch 1 | — | **Spec defect, narrow.** Invariant 3 ("at most one constraint per name") is right for `where` clauses and for `==`/`<` desugarings, and wrong for two independent `x.m` calls at different types — which is exactly report 18 §2.2's program. The spec already parks this as stretch item 1; what this report adds is that the fix is **not** "keep several per name" but "partition by origin class", and that it costs a sort by origin plus one arity/effect pre-check (`roc:src/check/unify.zig:3709-3746`), not a new representation. Estimate the stretch item from that, not from the Zulip description. |
| S3-4 | **A scheme is root type + a side table of promoted requirements** (`roc:design.md:5461-5468`, `captureSchemeDispatchRequirements`, `roc:src/check/Check.zig:28361-28471`) | §6.4, §7.2 | `generalize` (`beni:src/check/Solve.zig:1209-1254`), `Interface.Quantified` | **Spec defect.** §6.4's "constraints ride on `Flags`, so `generalize` carries them for free" holds only for constraints on variables the scheme quantifies. A constraint on an **outer-rank** receiver whose `fn_var` mentions the inner scheme's quantifiers is invisible to §7.2's quantifier walk, and two instantiations of the inner scheme then share one method type — the same failure §6.4 already guards against in `copyHelp`, one scope out. Roc's promotion rule (`:28427-28439`) also shows the subtlety that a receiver at the boundary's *own* rank is undecided until rank adjustment runs. Minimum fix for the spike: at generalisation, **assert** that every constraint reachable from the generalised rank sits on a quantified variable, and report `ambiguous_method_receiver` if not. The full side table is only needed if the assert fires in real code. |
| S3-5 | **Probe rollback shrinks 24 checker side tables, not just the store** (`roc:src/check/Check.zig:25285-25340`) | §6.1 inv. 2, §7.1 | `TypeStore` journal only | **Spec gap.** The `Dispatch` builder is appended to during discharge (§7.1: "A builder that appends while discharging must therefore sort and remap once, at the end"). beni's one speculator today is `?` (`checker.md` §6.5); the spike adds a second speculation source if `dischargeMethod` ever runs under a mark. Either state that `dischargeMethod` never runs speculatively — Roc asserts exactly that for promotion (`roc:src/check/Check.zig:28368-28370`) — or the site builder needs a snapshot length too. |
| S3-6 | Ordering by **ident text**, never ident index (`roc:src/check/unify.zig:3634-3639`); constraints never sorted on the artifact boundary (`roc:src/check/checked_artifact.zig:3787-3793`) | §6.5 rules 1–2 | `Schemes.Writer.quantifierOf` (`beni:src/check/Schemes.zig:341-364`), `Interface.Quantified.name` comment (`beni:src/resolve/Interface.zig:112-127`) | **Spec is right and Roc is not, for beni.** Roc can use producer order because a module is checked on one thread; beni hashes the interface bytes and checks on many. Sort by name text at the interface boundary and at rendering, exactly as §6.1 invariant 4 says. Note `sortByFnNameAsc` exists in Roc and is dead code — do not take its existence as evidence it is used. |
| S3-7 | The `alias` arm looks the method up **on the alias's own declaration** first, and only falls through to the backing var for derivable names (`roc:src/check/Check.zig:31863-32188`) | §6.3 `alias` row | transparent aliases (`fast-compiler.md` §3.1) | **Spec is probably right for beni, but for a different reason.** beni's aliases are transparent by decision, so "discharge against `actual`" is correct. Roc's aliases can carry their own associated block, which beni's cannot. Worth one sentence in §6.3 saying the row is a consequence of transparency, not an accident. |
| S3-8 | Method lookup is a sorted-array binary search on `(owner module, owner decl, method name)`, **deliberately not the exposure table** (`roc:src/canonicalize/ModuleEnv.zig:588-591`, `:5797-5812`) | §6.3.1 step 2 | `Interface.findValue` (`beni:src/resolve/Interface.zig:393-396`), `Types.Entry.module` (`beni:src/check/Types.zig:55-65`) | **Independent agreement** on the rule, but beni has only half the key. The spec reached the same conclusion for the same reason (a private method must be distinguishable from a missing one). `Interface.findValue` is keyed by **name alone** — it binary-searches one module's `values` for a `Symbol` — so it supplies the `name` half; the `TypeId` half comes from `Types.Entry.module` selecting *which* interface to search. That composition is the lookup, and it is cheap, but §6.3.1 should spell it out as two steps rather than as one `(TypeId, name)` probe. |
| S3-9 | **Resolve the method before checking arguments when the receiver's type is already known** (`roc:src/check/Check.zig:20054`) | §6.2, §1.2 | — | **Spec gap, quality not correctness.** `resolve_method_first` lets arguments check against the method's declared parameter types instead of fresh variables. Without it `xs.map (\x -> x.field)` loses the lambda's parameter type and cascades. One line in §6.2; the fixture is a lambda argument to a known method. |
| S3-10 | **`SurfaceOrigin` on the resolved node records *which* operator** (`roc:src/canonicalize/Expression.zig:756-770`); diagnostics map back with `getOperatorForMethod` (defined `roc:src/check/report.zig:5332`, called `:2605-2611`) | §1.3, §10 | `well_known` flag on `method_call` | **Spec defect, small.** A boolean says the call came from an operator but not which one. `fmt` must round-trip `a == b`, and every diagnostic wants to say `==` rather than `eq`. Make the flag an enum over the operators that desugar. |
| S3-11 | **`DeferredConstraintCheck.failure_expr` — "the expression whose instantiation created this obligation"** (`roc:src/check/unify.zig:3954-3956`), recorded but not used by the missing-method report | §6.2 U2, §10.4 | `Solve.Obligation` (`beni:src/check/Solve.zig:108-118`) — five fields, `kind, v, region, index, result`, the last two already a per-kind payload used only by `tuple_index` | **Spec gap, and the answer to report 18 §2.4.** §6.2's "report at the flex's region" is better than Roc, but the corpus case in §7.2 shows it is still not enough: the region that explains the error is the **instantiation site**, which lives on the obligation, not the constraint. Add it to `Obligation` and print both regions. The cost is one more field on a record that already carries a per-kind payload (`index`, `result`), so this is genuinely one `u32` and one diagnostic change — the cheapest place the spike can beat Roc on the thing report 18 said is worst about it. |
| S3-12 | Same-name evidence slots dedupe by name; the non-representative site is `independent_callable` (`roc:src/check/dispatch_evidence.zig:510-543`, `roc:src/check/static_dispatch_registry.zig:1344-1357`) | §7.2 | — | Only needed if S3-3's stretch item lands. Record it in §11 beside stretch item 1 so the two are costed together. |
| S3-13 | Termination is structural (two lineage detectors), with `recursive_dispatch` naming both states (`roc:src/check/Check.zig:30281-30378`, `:31021-31028`) | §6.3 Budget | `1 << 20` round bound (`beni:src/check/Solve.zig:1265`) | **Spec is right to keep a bound**, and right that reaching it must report. Import the *message*: name the repeated dispatch state, not just "too deep". |

### S4 — the backend

| # | Roc mechanism | Spec § | beni today | Difference, and the verdict |
|---|---|---|---|---|
| S4-1 | **`EvidenceChainIndex { depth, index }`** (`roc:src/check/static_dispatch_registry.zig:1336-1339`), resolved by walking out through enclosing callables (`roc:src/postcheck/monotype/lower.zig:992-1001`) | §7.1 `Target.evidence: u16`, §8.1 | — | **Spec gap, possibly benign.** A lambda nested inside a constrained declaration is itself a callable. beni lowers it to a JS closure that *captures* `$m$k` lexically, so one number may suffice — but the spec must say so explicitly, because the alternative (re-passing evidence into nested lambdas) needs `depth`. One sentence in §8.1, plus a `tests/corpus/run/` fixture with a constrained declaration whose body closes over `$m$0` inside a lambda. |
| S4-2 | `.boxy` hidden dictionary params become leading `opaque_ptr` arg locals (`roc:src/postcheck/boxy/lower.zig:12611-12635`) | §8.1 | — | **Same shape as `$m$0 …`.** Independent agreement on the encoding's *position*; the spec's choice of N separate function arguments over one record is the divergence, and Roc's code contains no argument against it — see S4-3. |
| S4-3 | Program-wide interned method slots so dictionaries of different shapes are interchangeable (`roc:src/postcheck/boxy/plan.zig:410-429`, `roc:design.md:7297-7305`) | plan §0 "N hidden function arguments" | — | **The spec's encoding avoids this machinery entirely.** Roc needed slot interning *because* it chose the record; report 18 §1.4 argued the record goes megamorphic on JS. Keep N arguments. Record in §11 that the cost is an arity that varies with the constraint set, which is what `constrained_constant` (§6.4) already trips over. |
| S4-4 | Forwarding is "pass the caller's own hidden local straight through", no materialisation statement (`roc:src/postcheck/boxy/lower.zig:26800-26812`) | §8.2 | — | Confirms the spec's `Target.evidence → $m$k`. The distinction Roc draws — `bound_dictionaries` (forward) vs `static_rep` (build a constant) — is beni's `evidence` vs `top`/`ext`/`derived`. **Independent agreement.** |
| S4-5 | Machine backends contain **no** dispatch logic; they know two LIR statements | §8.0 "the backend sees no types" | `backend.md` §3 | **Independent agreement**, and worth citing in §8.0: Roc's split is the same and it survived a whole-program specialiser and three code generators. |

### S5/S6 — derivation

| # | Roc mechanism | Spec § | beni today | Difference, and the verdict |
|---|---|---|---|---|
| S6-1 | **Roc derives six methods and `compare` is not one of them** (`roc:src/check/static_dispatch_registry.zig:1315-1322`) | §3.2, §9 | `foreign eq`, `equatable` obligation | The spike derives `eq` **and** `compare`, for every nominal type and every structural shape. That is a strictly larger derivation surface than Roc has ever shipped, and it is the direct consequence of the spike's decision to make `compare` a well-known method (plan §0). **Not a defect** — it is the decision report 18 §5 said should be argued on its own merits — but M2 must attribute the output-size delta to it separately from `eq`, or the measurement will blame dispatch for a cost that belongs to `compare`. |
| S6-2 | **Derivation is lazy and memoised on `(value_ty, result_ty)`** (`roc:src/postcheck/monotype/lower.zig:49044-49077`, `:56510-56516`) | §6.3.1 step 4, §8.5 | — | The spec derives **eagerly**, for every nominal type in a module, used or not, and gives a determinism argument for it that is correct: beni has no whole-program phase, and a lazily-requested derivation travelling backwards to the declaring module would make that module's output depend on `--jobs`. **Spec is right.** But say in §9 that eager is a determinism/size trade and that Roc chose the opposite because its phase ordering differs — otherwise M2's size numbers look like an unforced loss. |
| S6-3 | **One generic derivation ladder, parameterised by a comptime `Deriver` with `leaf` and `combine`** (`roc:src/postcheck/monotype/lower.zig:49077`, `56493`, `56541-56551`) | §9 | — | The spec writes `eq` and `compare` derivation separately across §9.1–§9.5. They differ only in the leaf operator and the fold. One walk with two hook sets is a smaller S6 and is how Roc does it. **Adopt.** |
| S6-4 | `is_eq`/`to_hash` on a structural shape require *every component* to support it, with a dedicated failure report (`roc:src/check/Check.zig:32196-32222`) | §6.3 record/tuple rows | `walkEquatable` (`beni:src/check/Solve.zig:1311-1364`) | **Independent agreement**; beni already has the walk and the `not_equatable` message. The spec's "register the same obligation on every field type" is the same rule expressed as obligations instead of a walk. |
| S6-5 | Derived recursion is broken by "an expansion stack plus a memoized generated helper def" (`roc:src/postcheck/monotype/lower.zig:49044-49072`) | §6.3 Budget, §9.4 | — | A recursive type's derived `eq` must not inline itself forever. The spec's `ConstraintChain{Ok,Deep}` fixtures cover the *constraint* chain; they do not cover a recursive **type**'s derived function. Add `tests/corpus/run/` coverage for `type Tree = Leaf \| Node Tree Tree` under `==`. |

### Cross-cutting

| # | Roc mechanism | Spec § | Verdict |
|---|---|---|---|
| X-1 | **`where` aliases shipped in August 2026** (`roc:design.md:3014-3027`, `s_where_alias_decl` at `roc:src/canonicalize/Statement.zig:192-206`, `w_alias` at `roc:src/canonicalize/CIR.zig:527-531`) | §11 | Report 18 §2.4 recorded Luke Boswell saying they had decided to see how much of an issue not having them would be. The answer was "enough": Feldman, #API design › Idea for alternative `parser_for` type signature, 2026-08-02, *"we actually have a design for `where` aliases"* (<https://roc.zulipchat.com/#narrow/channel/383402-API-design/topic/.E2.9C.94.20Idea.20for.20alternative.20.60parser_for.60.20type.20signature/near/614200216>), landed and demonstrated by Anton on 2026-08-07 (<https://roc.zulipchat.com/#narrow/channel/383402-API-design/topic/.E2.9C.94.20Idea.20for.20alternative.20.60parser_for.60.20type.20signature/near/615242889>). The spike is right not to build them, but §11 should record that Roc's own experience says a constraint set of more than one method wants a name within a year. |
| X-2 | Receiver-extension methods, resolved by searching every imported env (`roc:src/canonicalize/Can.zig:1010-1041`, `roc:src/check/Check.zig:20752-20758`) | §6.3.1, §11 | **Do not adopt.** It makes which method runs depend on the *caller's* import set. The spike's module rule is tighter. Record it as a deliberate divergence so a later reviewer does not "fix" it. |
| X-3 | Implicit graph edges: Roc requires the owning module env to be loaded and resolves it by **content identity hash**, not name (`roc:src/check/Check.zig:20784-20802`) | §6.8 | **Independent agreement** on the problem; different solutions. Roc keeps every transitively-loaded env addressable; beni adds graph edges. beni's is the one compatible with DAG-parallel checking, and §6.8's cost note (the DAG narrows) is real and unmeasured — M1 is the right place for it. |
| X-4 | The comparison-operator typing rule: `a == b` pins both sides and the result to `Bool`; `a.is_eq(b)` does not (`roc:design.md:3005-3012`) | §3.1 | **Spec gap, small.** If `==` lowers to exactly the constraint a hand-written `a.eq b` produces, inferred schemes get looser than they need to be — which directly worsens the §2.3 churn the spike is measuring. Say in §3.1 that the operator form pins `a, a -> Bool`. |

## 10. Could not determine

- **The exact size of `CheckedStaticDispatchConstraint` and of `Origin`.** No test pins either, and
  the repo was read, not compiled. `Origin` is dominated by `from_literal → LiteralInfo →
  NumeralInfo` (`roc:src/types/types.zig:914-952`: a `[16]u8` magnitude, a `u32` scale, a `Region`, a
  `FitSet` and five bools), which is why the whole constraint is 88 bytes.
- **Whether `.boxy` is used for production builds.** The default is `.lss`
  (`roc:src/cli/main.zig:11735`); `.boxy` is exercised in tests and `roc:src/postcheck/match_tree.zig:5`
  notes it does not yet use the decision-tree match compiler. No policy document was found. So the
  dictionary-passing design read in §6 is a real, complete implementation whose *production* exposure
  could not be established — report 07's "experimental" caveat still stands.
- **Whether `.lss` ever falls back to a runtime dictionary.** No `assign_call_dict` production was
  found in the `.lss` chain and `EvidenceParamRecord.runtime_dictionary` is consumed only by Boxy
  planning, but the negative was not proved exhaustively across `monotype/lower.zig`.
- **The cross-module missing-`where`-method location.** `roc:src/check/Check.zig:20926` instantiates a cross-module
  callee with `.{ .explicit = region }`, which *would* point at the caller and would therefore not
  exhibit §7.2's bug — but no snapshot exercises it, so this is inference from the region policy, not
  observed output.
- **Whether the `.rigid` `DispatcherType` branch of the missing-method report is reachable outside the
  derived-parser path.** Every other construction site passes `.nominal`, and no snapshot contains its
  "Did you forget to specify …" hint text, but unreachability was not proved.
- **No check-time cost figures for dispatch specifically.** Same gap report 18 §7 recorded. Nothing in
  the tree isolates constraint solving with and without `where` clauses, and no benchmark was run.
- **How `map`/`map!` derivation is handled in `.boxy`.** It is explicitly rejected at
  `roc:src/postcheck/boxy/plan.zig:9061`; whether a non-dictionary route exists was not established.
- **Whether any consumer of the checked artifact needs the dropped `provenance` /
  `derived_map_plan` / `interpolation` and reconstructs them elsewhere.** The drop site
  (`roc:src/check/checked_artifact.zig:8947-8969`) was traced; its downstream consumers were not.
- **Roc's own measurement of what the side table in §4.3 costs.** `roc:design.md:5461` argues the
  representation is *necessary*; nothing says how often a promoted requirement actually occurs, which
  is the number that would tell the spike whether S3-4's assert-only fix is enough.
