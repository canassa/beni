# 63 — The write-set gate: the read-only pass on Conduit and research 61's corpus

*2026-10-09. The result of `write-sets.md` §8.2's gate, run by the pass that document specifies
(`src/writes/Writes.zig`, `beni dump --stage=writes`), not by hand: per dispatchable message key
whether its write set is bounded, the share bounded on Conduit against the two-thirds bar, a
comparison with research 61/62's prototype classifier per constructor, the pass's cost, and every
place the specification was ambiguous or wrong with how this slice resolved it. Every figure is
**[measured]** by the commands in §6. The resolutions that change what the document says are
recorded in `write-sets.md` as the amendment of 2026-10-09; nothing here deviates silently.*

---

## 0. The answer in six sentences

1. **The gate is cleared: 90 of Conduit's 91 leaf keys are bounded (98.9%)**, against a bar of
   two thirds; the one `*` is `ChangedUrl`, the route change that genuinely replaces the page,
   exactly as §8.2 predicted (`tests/corpus/writes/Conduit/_expected.writes`, whose harness check
   asserts the ratio on every gate run).
2. The tree has **91 leaves, not the ~101 §8.2 estimated**: the estimate counted Main's 9
   constructors and the 65 page constructors as leaves plus "a few `Ok`/`Err` splits"; the pass
   splits `ClickedLink` (`Internal`/`External`), splits every `Result` payload a page matches, and
   puts the feed's constructors under `GotHomeMsg · GotFeedMsg` and `GotProfileMsg · GotFeedMsg`
   rather than counting them separately. The bounded share is the same either way.
3. Every write set §10 works by hand comes out of the pass as written there — `GotHomeMsg ·
   ClickedTag`, `GotEditorMsg · EnteredTitle` with its four status variants, the feed's
   `CompletedFavorite · Ok` as `node …articles ⟨kept⟩; value …articles[*]`, the table app's
   `SwapRows` at `[1]` and `[998]` and `Update` at `[*].label`, TodoMVC's `Toggle`.
4. Against research 61's classifier, **153 of 231 constructors get the same class; all 78 others
   are explained** — 74 are root writes of a model that is not a record (`Int`, `List String`),
   which §8.1 defines as `*` and the prototype called exact or indexed; 2 are a list replaced
   (`indexed` by §8.1, `exact ʳ` in the prototype); 1 is `SwapRows`, finer here; 1 is a program
   the comparison could not pair. No constructor is coarser in its write set; three of Conduit's
   are coarser in class name only because the pass now sees the list idiom the prototype's
   wrappers hid (§3).
5. **The pass costs 4.8 ms on Conduit** (3 387 lines; ReleaseFast, one thread), beside its 26.8 ms
   of checking, and **4.2 ms on the 100k-line generated corpus** wired into 215 programs
   (860 keys) beside 97 ms of checking — within `fast-compiler.md` §2's budget with room, since the
   pass alone runs above 700 000 lines a second on Conduit.
6. Writing the pass found eleven places where the document was ambiguous, inconsistent or too
   coarse to give its own worked examples (§5), the largest being that §3.1's depth cut, read
   literally with an `Alt` as a level, would have made `CompletedFavorite · Ok` `value ρ`.

## 1. The gate, per key

`beni dump --stage=writes --platform=browser-tea examples/conduit/src` prints one line per leaf
key; the corpus case `writes/Conduit/` is that dump, and its `.gate` makes the harness parse
`keys 91: bounded 90 (98%)` and fail if `3·B < 2·N`. Grouped by the constructor a page matches
(each group is one constructor of research 62's Appendix A; `· Ok`/`· Err` and the feed's
messages are the leaves under it):

| key (leaves) | class | what the set says |
|---|---|---|
| `ChangedUrl` (1) | **`*`** | `value ρ`: `changeRouteTo` builds another page |
| `ClickedLink · Internal`, `· External` (2) | exact | ∅: a navigation command only |
| `GotHomeMsg ·` 7 constructors (13) | exact ×6, structural ×1 | under `ρ.Home#0`; `GotFeedMsg · CompletedFavorite · Ok` is the map-by-slug, `node …articles ⟨kept⟩; value …articles[*]` |
| `GotSettingsMsg ·` 9 (11) | exact ×8, indexed ×1 | the `Entered*` keys write one field of `status.Loaded#0` |
| `GotLoginMsg ·` 4 (5), `GotRegisterMsg ·` 5 (6) | exact, indexed (`SubmittedForm`) | `form.<field>`; `problems ⟨replaced⟩` |
| `GotProfileMsg ·` 10 (17) | exact ×8, indexed ×1, structural ×1 | under `ρ.Profile#1`, the username kept; its feed as Home's |
| `GotArticleMsg ·` 17 (24) | exact ×12, indexed ×4, structural ×1 | `CompletedDeleteComment#1 · Ok` is `comments.Loaded#0.1 ⟨removeSome⟩`; `CompletedPostComment · Ok` prepends |
| `GotEditorMsg ·` 9 (12) | exact ×9 | `EnteredTitle` writes `title` under each of the four form-holding variants (§10.2); `ClickedSave` is `value ρ.Editor#1.status` |

All 90 bounded keys carry `node ρ`: the page is rebuilt with its own variant, which reaches only
the holes that read the model whole (§2.5). The holes: 145 source positions (research 62 counted
507 per call site; §5 item 7), of which 19 static, 6 literal (bakeable by §9.1), 120 dynamic.

## 2. What §8.2 expected, and the difference

§8.2 expected "about 100 of 101, one `*` (`ChangedUrl`)". The `*` is the one predicted, and no
other key is unbounded; the denominator differs as §0 item 2 says. Two things the estimate assumed
and the pass does differently, both by the document's own rules:

- **`node ρ` where the example says ∅.** §8.1's example prints `GotProfileMsg · ClickedFollow
  exact ∅`. By §3.4 a constructor re-applied under its own tag is `node p` even when every part is
  the very value (`Profile username profile`), so the pass prints `node ρ`. Either is sound; `node
  ρ` is what the table says and what §9.2's last paragraph describes for `Feed.ClickedFavorite`.
- **A key with no split.** A program whose `update` never matches the message (one constructor,
  or a `case` on a single-constructor type) has one key; the dump names it `(any)` so that it
  cannot be read as the `*` class.

## 3. Against research 61 and 62's classifier

`bench/writesets/compare-pass.mjs` runs the pass on every program
of research 61's corpus and pairs each constructor with the prototype's class, joining the pass's
leaves under a constructor.

| | constructors | exact | indexed | structural | `*` |
|---|--:|--:|--:|--:|--:|
| research 61's classifier | 231 | 142 | 58 | 31 | 0 |
| the pass | 231 | 94 | 32 | 30 | 74 |
| same class | **153** | | | | |

Every disagreement, by kind:

1. **74 root writes** (`DefectInFiber`, `HttpJson`, `RandomValues`,
   `StorageBasics`, `SyncKeyedPolicies`, …). The model is an `Int`, a `String`, a `Bool` or a
   `List String` log, and the constructor replaces or appends to it: the set is `value ρ` or
   `value ρ ⟨append⟩`. §8.1 defines the class as `*` whenever `value ρ` is in the set; the
   prototype's `*` row needed a record model, so it said exact or indexed. **The write set is the
   same information** — research 62 §2 already counted a root write as unbounded, and a root write
   does reach every hole (§2.5) — so the pass is not coarser; the two tools name the same set
   differently. For R5 the `⟨append⟩` tag on `ρ` still says what it is.
2. **2 lists replaced** (the table's `Run`, `RunLots`): `value ρ.rows ⟨replaced⟩`. §8.1 puts any
   list tag other than `kept`, `removeSome` and `permute` under indexed; the prototype classed
   them exact with a flag. Same set, different name.
3. **1 finer** (the table's `SwapRows`): the prototype saw a map (`structural`); the pass's index
   guards give `[1]` and `[998]` (`indexed`), §10.4 exactly.
4. **1 unpaired** (`LinkOutsideMount`'s mounted program): the prototype excluded the shell beside
   it, so the comparison paired the wrong program; the pass gives `value ρ ⟨append⟩` for both keys,
   the root-write case.

§8.2 says a constructor the prototype classed exact that the pass classes indexed "is a defect in
the pass, since the prototype's rules are a strict subset". Items 1 and 2 meet that letter and not
its intent: the classes are names over a set, §8.1's names and the prototype's disagree on root
writes and replaced lists, and the sets do not disagree. The amendment says so (§5 item 10).

**Conduit, against research 62's Appendix A.** Of its 9 Main and 65 page and feed constructors,
every root write research 62 found but `ChangedUrl`'s is now bounded below its variant; the nine same-variant rebuilds among its 16 "coarse
status writes" (its §5) are now field writes; and three constructors move to a *later* class
because the pass sees through the wrapper the prototype stopped at: `GotFeedMsg` on Home and on
Profile (exact `feed` → structural, the feed's `articles` map), and Article's
`CompletedDeleteComment` (indexed → structural, the `List.filter` by id). Each is a finer write set
under a class name that ranks the list edit it found.

## 4. Cost

ReleaseFast LLVM (`zig-out/perf/bin/beni`), `--jobs=1`, `--self-profile`'s `writes` event beside
the summed `check` events, best of five:

| program | lines | programs | keys | `writes` | `check` |
|---|--:|--:|--:|--:|--:|
| Conduit (`examples/conduit/src`) | 3 387 | 1 | 91 | **4.7–5.3 ms** | 26.6–27.3 ms |
| the generated corpus, `--generate=100000`, no program | 100 082 | 0 | 0 | 0.33–0.65 ms | 89–244 ms |
| the same with a `Main` mounting one `Tea.sandbox` per `Store` module | 100 082 + 1 082 | 215 | 860 | **4.2 ms** | 97 ms |

The generated corpus has no program of its own (`bench/gen.zig` writes `init`/`update`/`view`-shaped
functions and no `main`), so on it alone the pass is the one scan of declarations §6.2 promises;
`bench/writesets/gen-main.sh` adds a `Main` that mounts every store's `update`, which is the
whole-program measurement. The corpus needs `beni fmt --migrate-names` first (removed names, as
the handover of 2026-10-02 notes); its remaining diagnostics are 85 warnings.

Against `fast-compiler.md` §2 (250 000 checked lines a second per core): the pass is about 18% of
Conduit's check time and under 5% of the large corpus's, so it fits inside the checking budget
that §6.2 assigns it to. The C1 chain is in `tests/blackbox/perf_test.zig`: 1 000 and 2 000 lines
cost 200.6 M and 277.4 M instructions (ratio 1.38, linear). In the gates' ReleaseSafe build one
Conduit dump retires 1.83 G instructions, 0.46 G of which is the pass (the rest is checking all of
core from source, which `dump` does for every stage); the corpus case fits the default budget.

## 5. Where the specification was ambiguous or wrong, and the resolution

Each is in `write-sets.md`'s amendment of 2026-10-09.

1. **The depth cut (§3.1, C1's amendment).** Read literally — every structure and every `Alt` a
   level, the part "below the cut" made `Fresh` — a key's result is nine levels deep on Conduit
   (Main's `Alt`, `Home`, `Home.update`'s keyed `Alt`, its `case model.feed`, the record, `Loaded`,
   `Feed.update`'s keyed `Alt`, `Model`, the record, the list), and `CompletedFavorite · Ok`
   became `value ρ`. And a cut applied as each node is built cuts at the *root* of a deep term, not
   below level k. Resolution: a keyed `Alt` is not a level (it is bounded by its type, as for A);
   the cut is applied top-down to every finished term (a summary, a call's value, a key's result),
   memoised on (term, level).
2. **A join that a fixpoint can see is stable (§4.3).** Kleene iteration over symbolic terms
   nests: round two of `bumpTimes` is `Alt[Same(π₂), Alt[Rec(…), Alt[…]]]`, never equal to round
   one, so every recursion hit I. Resolution: a plain `Alt` is kept in a normal form — an
   alternative that is itself a plain `Alt` on the same choice (or on none) is flattened into it
   under both sets of facts, ⊥ disappears, equal alternatives are one. `bumpTimes` then settles in
   two rounds as §4.3 says.
3. **A record update of a value chosen by control flow (§3.3).** `first = case msg of A → {…}; _
   → model` then `{ first | b = 1 }`: `first` is an `Alt`, the rule gives `base = none` and every
   unnamed field `Fresh`, and the third review's own fixture (one split per path) wrote every
   field. Resolution: an update distributes over an `Alt`, as `proj` already does; it is exact.
4. **`[]` placed (§3.4).** The table sends `Lst(none, clear)` to `value p ⟨replaced⟩`; §2.6 and
   §10.3 print `⟨clear⟩`. Resolution: `clear` promises an empty list whatever the base, so it stays
   `⟨clear⟩`.
5. **The type at a placement path (B2, N7).** "Every other field of the type" needs the record
   type at the path where a rebuilt record lands. Resolution: it is read from `update`'s
   annotation, following aliases, constructor arguments and `List`'s parameter through the BIR
   type instructions; with no annotation the write is `value p`, never a guess.
6. **What `literal` means in the dump (§8.1 against §8.3 items 5 and 16).** §8.1 says a hole is
   literal when every read is literal at `init`; items 5 and 16 want a hole whose read is literal
   at `init` to be `static` when its value is chosen at run time or its parent is a `tr`. Those are
   §9.1's baking rule. Resolution: `literal` is the bake-eligible class of §9.1 (exactly a model
   path with a plain string at `init`, or an empty read set and a plain string literal; alone;
   allowlisted parent), and research 62's 264 "literal-init" holes are mostly `static` here.
7. **Holes per site or per position (§3.6, §8.1's example).** Research 62 counted a helper's holes
   once per call site (507 on Conduit); a template is per source position, and R3 can bake or mount
   a position only if every call agrees. Resolution: a hole is a source position, its reads the
   union over the calls that reach it, its reads the dependencies of its value as the pass's own
   interpreter computes it with every call of the program's functions inlined (rather than slice
   B's per-local paths, which live in the backend). 145 positions on Conduit.
8. **Splitting where the message is matched through a single-constructor wrapper (§4.4).**
   `GotPageMsg sub → pageUpdate sub …` with one `Msg` constructor gives no fact at μ, so the key's
   path starts below it; the dump still names it (`GotPageMsg · M1`) from the path.
9. **The W fixture (N6).** With terms shared and joins flattened, C1's thirty-line chain costs a
   few hundred visits, so `--writes-work=4096` does not reach W. Resolution: the W fixture writes
   the chain in `update` itself over the model and runs under `--writes-work=256`; the key is
   `(cap W)`, `value ρ`. The chain in a helper (C1's own fixture) settles with no cap.
10. **"No coarser than research 61" (§8.2) against §8.1's classes.** See §3: the classes name
    root writes and replaced lists differently from the prototype. Resolution: the comparison is
    stated on write sets; §8.1's class definitions stand.
11. **Programs the recognition of §1.1 did not name.** Research 61's corpus mounts programs with
    `Browser.programs`, `Browser.mountAt` and top-level values holding the call. Resolution: those
    are traced to the program call; each mounted program is printed by the declaration that holds
    it.

Smaller choices, each sound and each stated in the code: a method call whose evidence is a
`where` parameter is `Fresh` rather than an application node resolved at instantiation (no
program measured has one; coarse, never wrong); recursion is found on demand from `update`'s walk
(Tarjan's low link) rather than from a precomputed call graph, so its order is the program's text
and not its declaration order, and a component that does not settle makes every member `Fresh`;
`diff` skips an alternative whose facts contradict the context (it cannot hold); a `?` joins the
early return as `Fresh`; paths print in a structural order (fields by name, constructors by
declaration) rather than by id; a summary that hit I, W or S gets a `summary` line (Conduit has
one: `Url.Parser.firstMatch (cap I)`, under `ChangedUrl`, which is `*` anyway).

## 6. Reproducing it

```sh
zig build                                   # beni, and zig-out/perf/bin/beni via test-perf
beni dump --stage=writes --platform=browser-tea examples/conduit/src
zig build test-blackbox-corpus -Dcorpus=corpus/writes/     # every golden, the gate's ratio
zig build test-blackbox-ordering -Dtest-filter=write-set   # reversed declarations, --jobs
zig build test-perf -Dtest-filter=write-set                # C1's chain, linear
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --json > r61.json
BENI=zig-out/bin/beni node bench/writesets/compare-pass.mjs r61.json   # the §3 table
bench/writesets/gen-main.sh <a copy of .zig-cache/bench-gen>        # §4's 215 programs
```
