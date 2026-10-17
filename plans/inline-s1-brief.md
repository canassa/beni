# S1 brief — `browser-inline`: holes and handlers inlined per key, across modules

*2026-10-17. Slice S1 of #295 (`plans/direct-rewrite.md` §5 S1, amended 2026-10-17), issue #297.
The design pass is summarised here. Its hand-written targets are in `plans/inline-s1/`:
`n1-spread.js` (unique-components N = 1 seed 1, release, beni naming, 1 565 B brotli against
tea-inline's 1 696 B), `n1s2-spread.js` (seed 2, 983 B against 1 016 B) and `n1-inplace.js` (the
shape once #315 lands). S1 lands as several PRs; this brief covers all of S1, and each PR's scope is
stated in the manager's message to you.*

## 0. Rules (unchanged from S0; read `plans/inline-s0-brief.md` §0)

- **tea-inline's output is the spec and the yardstick.** It lives in
  `../reactivity-research/frameworks/tea-inline/`; see also `./rr generate unique-components
  tea-inline --size 1 --seed 1` and `--size 4`.
- **Stop and report; never work around.** Every deviation from this brief, and every compiler or
  conceptual limitation, goes to the manager with evidence. Never weaken a test, raise a budget, add
  a fallback or a coarse path, or move code behind `foreign`.
- **Refusals come in two kinds** (`browser-inline.md` §5).
  - *Compiler limits* begin "A limit of the compiler", are temporary, and are closed by their slice.
  - *Language rules* never say "not yet".
  - Keep the idiom / intended-global / compiler-cap split.
- **No plan codes in user-facing diagnostics.** House-style commits. Do not push or open PRs; the
  manager does.
- **Every commit passes `zig build test`.** `zig build gates` is green at the end of each PR.

## 1. The owner's decisions (2026-10-17)

- **Lifting (option 2).** Each module lowers its own pieces as exported functions, named by
  declaration plus ordinal. The program site calls them, and release single-use inlining fuses a
  piece used once. There are two kinds:
  - **arm pieces**, one per branch of a `case` at which the key tree splits a message inside this
    module, taking the branch's pattern variables, then the function's other parameters;
  - **view pieces**: the static HTML string, one binding function per distinct local read set, and
    the event wiring.

  Inlining another module's code at the program site was rejected.
- **The first refusal to remove** is a view through `Html.map` returning markup from another module.
- **D3, synchronous.** One write pass at the end of the dispatch, inside the guard. It calls the
  binding pieces whose groups conflict with the key's writes, each once, deduplicated statically.
  S1 measures it against tea-inline's microtask flush; a microtask win beyond noise is reported.
- **D-b:** `if c then <markup> else <></>` is an eager `when` (runtime `when(node, cond)`, as
  tea-inline does).
- **D-c:** a cross-module reader is a static call from the writer key's handler to the reader's
  binding piece. There is no run-time registration and no "readers above their source" rule.
- **D-d:** a view `let` read by one hole is substituted. One read by several holes is S3's: refuse
  it as a compiler limit naming that.
- **D-e:** an arm that reads its message whole builds the message value in that arm only.
- **Handlers** live at the program site. Measure bytes at N = 256 against tea-inline's in-widget
  handlers.
- **Records keep spreads** until #315: the checker does not judge records yet. Do not add identity
  guards; changes are driven by the write set.
- **The write-set caps:** lift the leaf cap (`cap_leaves`), the alternative cap (`cap_alt`) and the
  size cap (`cap_size`) (`src/writes/Writes.zig:57-67`). `k_limit` and `cap_rounds` wait for #286's
  folding: do not touch them.
- **Lists.** `List` is positional only. A by-id edit of `List` rows is a language-rule error naming
  `Dict.update`. Keyed rows are S2's.
  - Positional append (`[ …xs, x ]`), clear, and whole reads (`length`, `join`, `foldl`) are in
    scope.
  - A keyed `For` is a compiler limit naming S2's feature, without the plan code.
  - A positional `For` (rows by index) is in scope only if it stays small. Report its size before
    building it.

## 2. The mechanism (from the design pass; verify every claim against the code, citing file:line)

- **What S0 refuses today, and S1 must accept:**
  - `inline.zig:219`: a hole that is not text;
  - `:60-65`: `no_markup_values` on every markup root that is not the program's `view`;
  - `:237`: events;
  - `:188`: a hole beside other children;
  - `:226`: a second binding;
  - `:105`: a `view` from another module.
- **Arms today.** `Lower.zig` `directArm` (~12423) and `specialisedArm` (~12480) write in place only
  the program module's own `update` and its top-level `case`. Otherwise they build `keyMessage(…)`,
  the first platform's surviving message (~12441, ~12447). Key params are the constructor fields for
  one-step keys only; a nested key gets 1 param, the message itself (`Emit.zig` ~2648). That must
  become the leaf constructor's arity.
- **Holes are already known per call path across modules:** `Writes.zig` ~4015-4021, `directHole`
  `Lower.zig` ~12125-12175, `programCalls` ~12177. `programCallee` already detects
  `.other_module` (`Interface.zig` ~313-345).
- **Lifting exists for subscription starts:** `findLifts` (`Emit.zig` ~2549), `Lift.zig`, and the
  call pattern `directSubscriptionStart` (`Lower.zig` ~11952-12030). Generalise it to arm pieces
  and view pieces (a `findPieces` pre-pass).
- **Interface 1.15:**
  - `Lowering.pieces` and a `piece(cx, tree, root, *const PieceRequest)` hook, run in the module that
    owns the root;
  - `Program.Callee.piece`;
  - `Context.programPiece(node)`, giving the html piece's name, per binding piece the name, group
    and static flag, and per event the element ordinal, leaf key and argument kind;
  - `Program.Key.params` = the leaf arity;
  - `Program.Key.refusal` (`none`, `opaque_update`, `message_read_whole`, `deep_split`, `cap`) and
    `cap`;
  - `programArmTails`/`programCallsAt` (per-path passes);
  - `programGroupsOf(key)` (sparse).

  Interface 1.15 must be specified in `boundary.md` §9.4.6 first.
- **Per-path passes.** External events come through one key (`Pushed`) whose write set is every
  widget's. Write the pass at each tail of the arm, with that path's write set (the `Alt` before
  `diff` joins it). This is a new analysis output: amend `write-sets.md` first.
- **Quadratic spots to remove** (the plan's compile-linear rule):
  - group numbering scans every group per hole (`Emit.zig` ~2783-2789, ~2805-2811);
  - the dense key × group conflict matrix (~2829-2834);
  - each key skipping the N+1 arms of `step` (select by constructor index).
- **Release:**
  - arm pieces must be called with a *name* as argument, so single-use fusion applies (see
    `emit/release/core/InlineOnce.beni`);
  - a `case` on literals with expression arms becomes a conditional chain (enum cycles);
  - optional end tags are left out and attribute values unquoted where HTML allows, which is part of
    the bytes now. S0 wrote every end tag and quoted everything, for correctness only.
- **The cache.** A piece's output depends on whole-program facts (the piece list, bakes, groups).
  Extend `fast-compiler.md` §8.1's amendment to say so, and make the cache key sound.

## 3. Goldens (red first, in `tests/pending/`, moved into the corpus by the commit that passes them)

`tests/corpus/emit/release/inline/` goldens, plus `browser/inline/` pages with `.steps` and
`rr-push` dispatches:

| Golden | What it pins |
|---|---|
| `CounterLocal` | One module: events, two holes, mixed text, `disabled=`, the arm in place, the sync pass |
| `Counter/` | Main plus `Counter`: `Html.map (Counter.view model.c) CounterMsg`, the fused arm piece, view pieces, no `case`, no message, no `$$cx` |
| `Texts/` | A widget with a list of texts: positional append, remove-last, clear, read by `length`/`join` |
| `Reader/` | W2's view reads `W1.Model`; a W1 key's handler calls W2's piece; static dedup |
| `Research/S2`, `Research/S3` | unique-components n1-s2 (a number input via `Ui`) and n1-s3 (select, bool, enum cycle), with `Push` serverSet and snapshot |

`build/bad/inline/` fixtures: `OpaqueUpdate`, `MapNotCtor`, `MarkupValue`, `StarNotReplace`
(language rules); `ResearchListWidget` (n1-s1, the keyed-`For` compiler limit); `CapFired`, if any
cap survives.

## 4. Bars

**Per PR:** the goldens pass, the gates are green, and every commit passes `zig build test`.

**For S1 as a whole**, on the no-list-widgets generator variant (the manager arranges it), sizes
1–256, seeds 1–3, every item from `plans/direct-rewrite.md` §4:
- `./rr check`, same-task included;
- bytes ≤ 1.1 × tea-inline at N = 1 and N = 256;
- CPU ≤ 1.1 × on local events. The N = 256 miss is owed to #315: report it, don't hide it;
- locality ≤ 1.1× calls from N = 16 to 256;
- compile time and RSS linear to N = 256 and 512;
- the owner's hand check through `./rr serve`.

Measure `--self-profile` phases at N = 1, 16, 64, 256 and 512.

## 5. Your report per PR

Commits; bytes per golden with attribution; red-before proofs; the gates; every deviation and every
wall, with file:line.
