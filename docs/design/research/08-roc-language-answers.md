# How Roc answered the same questions — and why it changed its syntax

Evidence for §3.1's open decisions. Sources: the vendored Roc compiler at `references/roc`
(Zig, master), its git history, and roc.zulipchat.com via
[`.claude/skills/roc-zulip`](../../../.claude/skills/roc-zulip/SKILL.md).

---

## 1. Top-level annotations and the cost of inferring interfaces

**Not required** — Roc infers everything; `roc format annotate` is opt-in.

The interesting part is what their caching pays for that. Roc's cache key is a content-hash chain
(`design.md:1985`, "Cache Boundary"): `source_hash + compiler_build_hash + module_identity +
checking_context_identity + direct_import_checked_module_ids`. It hashes whole *checked modules*,
not interfaces — so **any** source edit to a leaf invalidates every direct importer's cache entry,
even when its exposed types are unchanged. There is no Elm-style interface comparison.

Feldman's unimplemented fix is precisely our §8.1 + required annotations. A module whose exposed
values all carry full annotations (no `_`) is a "non-global module": its exposed types can be read
lexically without checking it, which lets importers be checked in parallel with it, and —

> "if I'm one of these non-global modules, and a module I import changes its types... *I* need to
> have my type-checking redone, but nobody who imports me does"

— #compiler development › "zig compiler - non-global modules", 2025-02-22, id 501221282. He adds
"I don't think this is written down anywhere... this seems like something we should definitely try
at some point." Grepping the source for `non_global` finds nothing; it is still a proposal.

**Bearing on us:** the interface firewall in §8.1 is *ahead of* Roc's shipped behaviour, and
required annotations are the mechanism their own lead designed to get there. Nobody has argued for
*requiring* them, so there is no evidence on the ergonomic cost.

## 2. User-defined infix operators — no, deliberately

Fixed, closed operator set (`docs/langref/operators.md`), each desugaring to a static-dispatch
method (`+` → `.plus`). No fixity-declaration syntax exists in the grammar.

Feldman, #beginners › "Bit shifting operators?", 2024-09-19 (id 471389274):

> "Elm used to have custom infix operators and removed them, and I think that decision was for the
> best in retrospect based on how they were used in practice."

Note the reasoning is **misuse in practice, not parser ambiguity** — no source or chat ties the ban
to grammar simplicity. Our LL(k) argument stands on its own and is independent corroboration.

## 3. Import cycles — forbidden, for caching

Enforced mechanically: Kahn's-algorithm topological sort returning `error.CyclicDependency`
(`src/compile/dependency_sort.zig`). The rationale is entirely about build times
(`docs/langref/modules.md`, "Design Notes on Imports"): Roc caches at module granularity, so cycles
are banned because they are

> "a footgun for build times; it becomes very easy to accidentally create a cycle, get no feedback
> that you have done this, and silently lose a huge amount of caching."

It contrasts explicitly with Rust, which permits cyclic module imports because it caches at crate
level.

*Correction to §3:* the claim that Roc bans wildcard imports specifically to parallelise name
resolution comes from Roc's FAQ (report 05). A direct search of the repo and Zulip could not
independently confirm that link — `exposing [...]` is simply an explicit whitelist with no
wildcard form. Treat the parallelism rationale as FAQ-sourced, not source-verified.

## 4. Shadowing — allowed, permanently, as a warning

`src/canonicalize/Scope.zig` emits `shadowing_warning` (severity `.warning`) for values, type
variables, aliases and exposed items; same-scope *type* redeclaration is a hard error.

Feldman, #beginners › "inner functions and shadowing", 2026-09-02 (id 621142416):

> "the plan is to have it always be a warning — shadowing is intentionally not something we want to
> support, for design reasons"

with the reason being that if shadowing is banned "you can look at a local snippet of code, or a
diff, and have stronger guarantees about what names mean." Note that this is an argument *for*
banning; Roc chose a warning anyway. Elm makes it an error.

## 5. Type aliases — transparent, but interned rather than expanded

Semantically transparent: "Aliases are transparent — substituted away during compilation — so an
alias and its definition are the *same* type" (`docs/langref/types.md:235`).

Representationally they are **not** expanded. `Content.alias` (`src/types/types.zig:354`) is a
compact `Alias{ ident, vars, origin_module, source_decl }` node pointing at a backing type variable,
resolved lazily through the store. The cached checked-module artifact therefore holds one interned
alias node plus a shared backing var, not a copy of the expanded structure at every use site —
avoiding elm/compiler#1453-style interface bloat by construction. (Verified in source; no chat
discussion contrasting it with Elm was found.)

## 6. Effects — two arrow types, tracked in the type system

`->` is pure, `=>` is effectful (`docs/langref/functions.md`). The `!` name suffix is a **lint**;
the checked source of truth is the resolved function type, with real `fn_pure` / `fn_effectful` /
`fn_unbound` variants in `src/check/unify.zig` and effect-polymorphic dependencies resolved by
directed dataflow (`design.md`, "Effect Slots"):

> "Effects are not inferred from source spelling alone. A `!` name contributes to identifier parsing
> and annotations, but the checked source of truth is the resolved function type and dispatch
> result."

The guarantee: "A function is effectful if it calls another effectful function, and otherwise it's
pure. Effectful functions can only be called by other effectful functions." Pure functions may still
crash, allocate or emit `dbg`/`expect` — those are defined as not observable.

Feldman's original "Purity Inference" proposal (2024-08-28) listed **dead code elimination is
maximally effective** among its benefits. But the agent could not find a pass that prunes unused
pure top-level bindings *because* of the purity type — only ordinary reachability DCE in the
LLVM/wasm backends, plus purity-driven compile-time evaluation and const-root selection.

**Transfers to JS:** the type-level pure/effectful split is a type-checker property, so yes. The
platform mechanism (linking a compiled native host) does not; on JS, effects would arrive as
imported JS functions.

## 7. Numbers — trap by default, `Dec` as the literal default

- `I8`…`I128`, `U8`…`U128`, fixed width regardless of target.
- **Overflow traps by default.** `+` desugars to `.plus`, which crashes on overflow
  (`roc_ops.crash("Integer addition overflowed")`, `src/builtins/num.zig`). `plus_wrap`,
  `plus_saturated` and `plus_try` (returning `Try(T, [Overflow, ..])`) are opt-in named methods.
- **`Dec`** is i128-backed fixed point with 18 fractional digits, and an unpinned numeric literal
  defaults to `Dec` rather than a float (`docs/langref/numbers.md`, "Defaulting to Dec") — chosen so
  `0.1 + 0.2` behaves.

**Native-only affordances.** `Dec` is 128-bit integer arithmetic; JS has no exact integer beyond
2⁵³ without BigInt, which is boxed and much slower than a double. Roc has never targeted JS, so
there is no discussion of this tradeoff at all — the judgement is ours to make.

## 8. `List` is a flat refcounted array, not a cons list and not a persistent tree

```zig
pub const RocList = extern struct {
    bytes: ?[*]u8,
    length: usize,
    capacity_or_alloc_ptr: usize, // capacity<<1, or (seamless slice) original alloc ptr | tag bit
};
```
(`src/builtins/list.zig`) — contiguous heap array, refcounted, with **seamless slices**: a sublist
shares the parent allocation via a tagged pointer instead of copying.

Brendan Hansknecht, #beginners, 2024-10-21:

> "roc uses the same low level data structures that would be seen in C/C++/rust/zig. Generally one
> dense allocation... everything is refcounted and immutable... If you only have a single reference,
> roc can be significantly faster than persistent data structures. It will mutate in place... flat
> data structures are much more cpu friendly than persistent ones... if you have two references in a
> hot loop, roc has no option but to copy."

Pattern matching uses slice patterns, not cons: `match list { [] => ..., [first, .. as rest] => ... }`.

**Transfers to JS in spirit** (array + copy-on-write, mutate when uniquely referenced), but not in
mechanism: the refcount lives in an allocation header manipulated by pointer arithmetic, and the
seamless-slice pointer-tagging trick has no JS equivalent. JS is already GC'd, so uniqueness would
need real aliasing analysis rather than a refcount check.

---

# Why Roc changed its syntax

Most surface churn happened just before the Rust→Zig rewrite (~Feb 2025) and has continued since.

| Change | Old → New | Why | When |
|---|---|---|---|
| Lambdas | `\n -> n + 1` → `\|n\| n + 1` | Uniformity: "functions are ordinary values like any other value" | parser 2025-01-15; old syntax dropped 2025-03-17 |
| Case expressions | `when x is` (indentation-delimited) → `match x { … => … }` | Human readability, explicitly *not* machine need | Feb 2025 |
| Function calls | `Num.add 1 2` → `Num.add(1, 2)` | **Parser ambiguity** — see below | 2024; WSA deprecated 2025-02-12 |
| Naming | camelCase → snake_case (flip-flopped twice) | Familiarity; settled alongside the 2025 overhaul | stdlib migration Jan 2025 |
| Ad-hoc polymorphism | module-prefix calls → `x.foo().bar()` static dispatch | No runtime overhead; chaining readability | Dec 2024 – Mar 2025 |
| Backpassing | `task <- await getTask` → effectful `!` fns + `?` | Semantic footgun: early return targeted the wrong function | removed 2025-01-02 |
| Effect marking | none → `!` suffix, `->` vs `=>` | "easy to see at a glance which parts of your code are potentially performing effects" | 2024–2025 |
| App header | bespoke multi-clause header → `app [main] { pf: platform "…" }` + `import` lines | Simplification; `platform` made an ordinary binop so header parsing reuses the binop path | 2024-07 onward |
| Optional fields | `name :? T` → `name ?: T` | Bikeshed; reversed once already | 2026-07-29 |
| Pipe `\|>` | deprioritised during the dot-chaining push → re-added | Dot chaining didn't cover piping into a lambda | re-added 2026-07-31 |

## The parser lessons — directly relevant to our LL(k) requirement

**1. Whitespace application is ambiguous without indentation rules.** Roc moved calls from
whitespace application (`f a b`) to parens-and-commas (`f(a, b)`). Joshua Warner constructed
examples where WSA plus Roc's *indentation-insensitive* grammar admits two parses of the same token
stream, and noted "with WSA you can continue on the next line with no symbol" — a real hazard in a
delimiter-free grammar. Whether **type** application (`List Str`) should also move is still openly
undecided.

*Caveat for us:* Elm keeps WSA and is fine, because it is indentation-**sensitive**. The lesson is
conditional — WSA and indentation-insensitivity don't mix — not "WSA is bad."

**2. `|x|` lambdas collide with `||` and `|>`.** Anthony Bullard, #compiler development › "New
lambda syntax / BinOp contention", 2025-01-15:

> "The new lambda syntax `|_| ...` has an issue. When parsing a term, we had to peek before trying
> to parse this to make sure we don't try to consume the `||` and `|>` operators as part of the
> lambda args."

That is lookahead added purely by a syntax choice, it produced fuzzer-caught bugs, and the same
class of ambiguity was still generating parse errors on `->`-plus-lambda in user code as late as
2026-02. **If we keep `|>` — and we do — `|x|` lambdas are not free.** Elm's `\x ->` has no such
collision.

**3. Delimiters are for humans, and that is a sufficient reason.** Bullard, same thread: "for
machine parsing there is no need for commas in ANY collection-like syntactic construct... They are
there for the humans." `match` ended up brace-delimited partly for editor selection ergonomics.

**4. A formatter that auto-migrates makes micro-syntax reversible.** The optional-field marker
flipped twice, each time with formatter-driven migration and a did-you-mean diagnostic. Cheap to
change late — *if* the formatter exists early.

## Contested or reversed

Backpassing (removed, still missed, and its absence prompted a list-comprehension thread);
naming convention (flip-flopped twice); optional-field marker (reversed within a year); `|>`
(dropped, then restored after real code hit gaps); type application WSA-vs-PNC (still open).

## Could not determine

No single design-rationale document for `when/is` → `match` — only in-the-moment chat. No
Zulip/commit rationale for the app-header reshape beyond the commit title. With a 15-request Zulip
budget the agent did not read all 28 static-dispatch topics, so more first-party reasoning exists.
