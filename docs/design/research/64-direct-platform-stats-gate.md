# 64 — The direct platform's stats gate: kill criterion 1, measured

*2026-10-09. The first step of `browser-direct.md` §14's slice S0: the analysis-only stats gate.
The dump lines §11 names — `site`, `markup_value_roots`, `carriers`, `pairs`, `reconciler`,
`patchAll`, and the `constructors` line kill criterion 1's static share needs — are built into
`beni dump --stage=writes` in the format the dated amendment to `browser-direct.md` §16 fixes,
and `bench/writesets/stats.mjs` runs them over every program the criterion names. Every figure
is **[measured]** by the commands in §8. Nothing here was tuned: the thresholds are §13's and the
programs are the repository's (CLAUDE.md rule 10).*

---

## 0. The verdict

**Kill criterion 1 fires, on four of its six sub-criteria.** By §13 and `plans/compile-away.md`
§7 the slice stops here, and the platform skeleton (S0b) proceeds only if the owner decides so.

| sub-criterion | bar | measured | verdict |
|---|---|---|---|
| **bounded** — Conduit's leaf keys bounded | ≥ ⅔ | **90 of 91 (98.9 %)** | holds |
| **static** — message constructors under a `*` key | ≤ 5 % on Conduit and on every corpus app | Conduit **1 of 69 (1.4 %)**; **48 of 79** corpus programs above 5 % | **fires** |
| **dynamic** — dispatches of Conduit's three scripts reaching `patchAll` | ≤ 10 % | **9 of 62 (14.5 %)**: Reader 2/18, Editor 1/12, Tour 6/32 | **fires** |
| **value roots** | ≤ 3 per program and ≤ 5 % of its sites | **0** in all 87 programs (344 sites) | holds |
| **pairs** — pairs ÷ keys on the largest program against 2× the median program's | ≤ 2× | Conduit **9.21** per key; median program **0.00–0.33** (bar ≤ 0.67); log-log slope **1.64** | **fires** |
| **trie** — the write half shipping where §13 assumed not | not shipped | the table app **without its prepend** still ships `fromPlain` and `triePushed`, through `Add`'s `++` | **fires** |

Two of the four are the design's own predicted cost showing up as larger than its bar (dynamic,
pairs); two are a definition meeting programs §13 did not picture (static, trie). §2–§6 give each
one's numbers and cause, and say plainly where the cause is a counting rule rather than a cost —
which is information for the owner, not a reason to restate a bar.

Building the gate also found **three unsound read rules in the write-set pass** (§7), each a page
that would have shown another model's value, TodoMVC's filter among them; they are fixed, with a
fixture that fails on `master`.

## 1. What was measured

**The programs** (87): research 61's TEA corpus as `bench/writesets/classify.mjs` lists it — every
`tests/corpus/browser/tea/*.beni` and project, less the three `Conduit*` script projects, which are
Conduit — 73 programs counting each `Browser.programs` entry; the table app
(`bench/ui/apps/beni/Main.beni`); TodoMVC's four bench builds (`bench/todomvc/apps/beni/`) beside
the corpus page `tea/TodoMVC.beni`; Conduit (`examples/conduit/src`); and Conduit's eight pages
mounted as programs of their own (research 62's `bench/writesets/conduit/Pages.beni`).

**The dynamic count**: `stats.mjs` builds Conduit for `browser-tea` (development), adds one
statement to its copy of the emitted `Main.mjs` — at the head of `Main$update`, pushing the
message's constructor tags into the driver's transcript as `(dispatch …)` — runs
`tests/browser/driver.mjs` under happy-dom on each script, and maps each message to the leaf key
whose name it matches most specifically (named steps over `_`). All 62 dispatches matched a key.
The compiler, the platforms and the fixtures are untouched; the logging lives in the harness.

**The trie**: development builds say which of `List`'s write-half functions ship (by name, in
`_core/List.mjs`); `--release` builds give bytes (every emitted file, brotli 11; beni's own
compaction, no terser, so the figures compare with each other and not with research 59's).

## 2. Static: 48 corpus programs above 5 %, Conduit at 1.4 %

Conduit's one `*` key is `ChangedUrl` (`changeRouteTo` builds another page); 1 of its 69 message
constructors. Its pages, analysed alone, have none. TodoMVC (all five builds) and the table app
have none.

The 48 corpus programs over the bar, by the type of their model:

| model | programs' `*` keys | their write set |
|---|--:|---|
| `List String` (a log of what happened) | 48 keys | `value ρ ⟨append⟩` |
| `Int` | 38 | `value ρ` |
| `String` | 10 | `value ρ` |
| unknown (`update` has no annotation, so the pass knows no fields: `write-sets.md`'s first 2026-10-09 amendment, item 5) | 11 | `value ρ`, `value ρ ⟨append⟩` |
| `Bool` | 1 | `value ρ` |
| a record | 2 (`DefectInUpdate`, `DefectReleasesHost`: `Boom → Debug.todo "update threw"`) | `value ρ` |

**What fires the bar is §8.1's class, not a coarse analysis.** 46 of the 48 programs' models are
not records: there is nothing below ρ, so every write is a root write, and §8.1 classes `value ρ`
as `*` whatever its tag (research 63 §3 item 1 found the same 74 root writes). `value ρ ⟨append⟩`
is an append to the root list — an edit script, not "everything" — and a scalar model's every hole
reads ρ, so `patchAll` and a bounded handler would do the same work there. The other two are
`Debug.todo` arms, which never return and whose write set the pass takes as `Fresh` at ρ rather
than nothing. Neither is a gap on a real app's shape; both are recorded, and the bar is not
moved. Whether a write at the root of a model with nothing below it should count as `*` for this
criterion is a question about §8.1's class, and the `Debug.todo` arm one about that row of
`Core.zig`; both are the owner's, and the criterion fires as written until they are settled.

## 3. Dynamic: 14.5 % of Conduit's dispatches reach `patchAll`

| script | dispatches | `ChangedUrl` | share |
|---|--:|--:|--:|
| `ConduitReader` | 18 | 2 | 11.1 % |
| `ConduitEditor` | 12 | 1 | 8.3 % |
| `ConduitTour` | 32 | 6 | 18.8 % |
| **all three** | **62** | **9** | **14.5 %** |

Every `*` dispatch is a navigation, as §13 meant the Tour to show: the scripts are short, and
roughly one dispatch in seven is a route change (the Tour has six, four of them after a
`ClickedLink · Internal`, the others after a command navigates). The rest is requests answering (`CompletedFeedLoad · Ok`
and the like) and typing or clicking inside a page. **The design's one known `*` key is reached on 14.5 % of dispatches, against a bar
of 10 %.** Each such dispatch runs `patchAll`: today's cost, every group of the page compared —
but on a route change most of the page is torn down and mounted anyway (§5.5), so how much
`patchAll` costs beyond the mount is S6's measurement; the share is the gate's.

## 4. Pairs: 9.21 per key on Conduit, against a median of 0–0.33

The series is the 62 programs with a bounded key, by bounded-key count; 25 others have none (their
keys are all `*`, §2). Pairs are counted over bounded keys only (the amendment: a `*` key calls
`patchAll`, not a group each).

| program | bounded keys | groups | pairs | per key | groups a key calls |
|---|--:|--:|--:|--:|--:|
| table app | 8 | 4 | 27 | 3.38 | 84 % |
| TodoMVC (sandbox) | 11 | 8 | 47 | 4.27 | 53 % |
| Conduit · login | 10 | 5 | 23 | 2.30 | 46 % |
| Conduit · editor | 12 | 7 | 50 | 4.17 | 60 % |
| Conduit · home | 13 | 35 | 134 | 10.31 | 30 % |
| Conduit · profile | 22 | 39 | 173 | 7.86 | 20 % |
| Conduit · article | 49 | 36 | 277 | 5.65 | 16 % |
| **Conduit** | **90** | **106** | **829** | **9.21** | **8.7 %** |

The median program of the series (by key count, 62 programs) is a two- or three-key corpus app
(`SyncCommandOrder`, 0.00; `DefectInRender`, 0.33), so the bar is 0.67 per key and Conduit is
14× over it; the least-squares slope of log pairs on log keys over the series is **1.64**, above
linear. Read against the larger programs only — the median of TodoMVC, the table app and the
pages is 1.55–4.25 per key — Conduit is still over 2×. **The criterion fires however the median
is taken**, and the cause is clear from the last column: a key calls a falling *share* of a
growing number of groups, so pairs per key track the size of the view more than the number of
keys. Conduit's keys each call 8.7 % of its groups, which is the selectivity the design wants;
there are simply 106 groups.

Where Conduit's pairs go: **three groups of the frame's header account for 249 of the 829** (30 %).
They are `Page.frame`'s holes that read the signed-in viewer through `toSession model`, a `case`
on the page variant, so their anchored reads include **ρ itself**; every page key writes `node ρ`
(the page is rebuilt with its own variant, §7.3), and a `node` write conflicts with a read of the
same path (`write-sets.md` §2.5). 88 of the 90 bounded keys call two of them, 73 the third — §5.2's
"a header showing `model.session`" exactly. A read of ρ there is a read of *which constructor* is at
ρ, which a `node` write keeps; a conflict rule that told a tag read from a value read would drop
those 249 pairs. Without them Conduit is 6.44 per key, still over every reading of the bar. The
next largest are the feed's and the article's shared helpers, whose groups read the union of
their call sites' paths (a group is per source position): 12–23 keys each.

At "~2 B per pair" (§3), Conduit's 829 pairs are about 1.7 kB of handler code. Whether that is a
problem for §13's Conduit bytes target (≤ 0.7× of 30 842 B) is S6's measurement; the gate's
question — do pairs grow linearly in keys — is answered no.

## 5. The trie's write half: shipped by `++`, not only by the prepend

| program (`--release`) | brotli | write half shipped |
|---|--:|---|
| the table app as written | 5 673 B | `fromPlain`, `triePrepend`, `triePushed` |
| the table app, `buildFrom`'s prepend replaced by a reader (`indexedMap` over `repeat`), as S3's building-loop rule would leave it | 5 440 B | `fromPlain`, **`triePushed`** |
| the same with `Add`'s `++` removed too | 4 813 B | none |
| a program whose one list write is `List.set` on 1 000 rows | 2 316 B | `fromPlain`, `trieSet` |
| its twin writing the element by `indexedMap` | 1 761 B | none |

§13's table-app bytes rest on core being "≈ 400 after §7.2's building loop", which "holds only if
the trie's write half is not reached". It is reached: `Add` is `model.rows ++ rows`, and since
`backend.md` §4's E1tp amendment `List.append` is a writer — it pushes onto a trie, or onto a list
of 32 or more when the rest is shorter — so it names `triePushed` and `fromPlain`, and the write
half ships whether or not the building loop removes the prepend. **627 B** of the table app's bundle
is `append` and the write half it pulls (5 440 − 4 813). The `set`-only program pays **555 B** for
`set` and its half, which is what §7.2 already said such a program pays (~500 B); that case was
expected and is not the finding. The finding is the table app: its writes are all `indexedMap`
and `filter` except `++`, §7.2 accounted for `buildFrom` and not for `++`, and the ≈ 400 estimate
does not survive it. This is a finding about `List` for the owner (`plans/compile-away.md` §6:
"Anything … B1 finds against `List`'s representation"); nothing here proposes a change to it.

## 6. What held

- **Bounded**: 90 of Conduit's 91 leaf keys, as research 63 found; the one `*` is `ChangedUrl`.
- **Value roots**: none in any of the 87 programs. No program of the set renders a `List Html`
  hole, a recursive helper, or markup a list's element builds; Conduit's composition is entirely
  by helpers and `Html.map` over constructors, which are unique or shared sites. `writes/StatsSites`
  pins both value-path causes so the count is known to work.
- **Sites**: 344 in all. Conduit has 79: 39 unique, 17 shared (before §5.2's size gate — the
  frame's helpers are called from all ten page arms, one 60 times), 23 instanced. The table app
  has 3 (the six buttons' helper is constants only, so it stays unique).
- **Carriers**: 75 of 87 programs have one, every `Tea.element`/`application` by `commands`; of
  the sandboxes only `TwoPrograms`' outer one (`Debug.log "outer got" msg`). The table app and
  TodoMVC's sandbox build have none, as §4.4 expects.
- **Reconciler**: 11 of the 12 programs with keyed lists reach it. The table app by `Run` and
  `RunLots` (`⟨replaced⟩`); every TodoMVC build through its derived `For` over the filter (§6.2's
  last paragraph: 8 of 11 keys); Conduit's two keyed lists by `ChangedUrl` and by lists loaded
  from the API (`value` above them). Conduit's other ten lists are positional (`keyed={False}`),
  reached by the positional pass on the same keys.
- **`view` walk caps**: Conduit's view walk meets cap D once, at `Author.profile`, a data helper
  eight calls deep that holds no markup, so no site is missed; no other program meets a cap.

## 7. Three unsound read rules, fixed

The `pairs` and `reconciler` lines read each hole's anchored reads, and checking them by hand
found three places where `write-sets.md` §3.6's anchor left out a path the hole's value depends on.
Each made a hole `static` (or a key not conflict with it) when a key changed what it shows: a
consumer would have left a stale page, the failure kill criterion 8 exists for. All three are in
the read-only pass, which nothing consumes yet, so no emitted byte was ever wrong.

1. **A list's shape reads what decided it.** `filter`'s predicate, `filterMap`'s callback,
   `sortBy`'s key and the counts of `take`/`drop`/`slice` were evaluated and dropped. TodoMVC's
   `<For each={List.filter model.todos (visible model.filter _)}>` read `ρ.todos` only, so
   `SetFilter` did not reach it — the page would have kept showing the old filter.
2. **`ρ.rows[model.sel]` reads `ρ.sel`**: a model-path index is now anchored as a read.
3. **`ρ.rows[?]` from a computed index reads the index's reads.**

`write-sets.md` gains a dated amendment; `writes/ReadsOfShape` has one hole per rule, each
`static` on `master` and `dynamic` now. No write set changes; on the corpus only TodoMVC's holes
move, gaining `ρ.filter` and `ρ.todos[*].completed`.

## 8. Reproducing it

```sh
zig build
beni dump --stage=writes --platform=browser-tea examples/conduit/src   # the S0 lines, per program
zig build test-blackbox-corpus -Dcorpus=corpus/writes/                   # the goldens, Stats* and ReadsOfShape
BENI=zig-out/bin/beni node bench/writesets/stats.mjs                     # §0's table, ~35 s
BENI=zig-out/bin/beni node bench/writesets/stats.mjs --json              # every row
```

The new corpus fixtures, each pinning one rule of the amendment: `writes/StatsSites` (all four
site classes, both value-path causes), `writes/StatsLists` (each reconciler cause, scripts, the
positional pass), `writes/StatsCarriers` (a non-constructor `Html.map`, a stored message, and the
two `Html.map` shapes that are not carriers), `writes/StatsConstructors` (sub-message, `Result`
and default-child counting, one `*`), `writes/StatsPairs` (groups by site and read set, the
every-key share), and `writes/ReadsOfShape` (§7). Every existing `writes/` golden gained the S0
lines and changed in no other line but TodoMVC's holes (§7).

---

## Addendum, 2026-10-09: tag reads, and the pairs re-measured

The owner approved the refinement §4 pointed at: a `case` reads **which constructor** its
scrutinee has, not everything under it. It is specified as `write-sets.md`'s dated amendment
*tag reads* and built in `src/writes/Writes.zig`. A `case` on a path now anchors `tag p`
where a constructor pattern tests the tag at `p`, and a whole-value read only where a literal
or list pattern tests more. A tag read conflicts with a `value` write at `p` or at a prefix of it,
and never with a `node` write. Nothing else changed: no write set, no threshold, no program. The
gate was re-run with the same command (§8) and nothing else.

| | before | after |
|---|--:|--:|
| Conduit's pairs over its 90 bounded keys | 829 | **650** |
| pairs per key | 9.21 | **7.22** |
| share of the 106 groups a key calls | 8.7 % | 6.8 % |
| median program's pairs per key, and the bar (2×) | 0.00–0.33, bar 0.67 | unchanged |
| log-log slope of pairs on keys | 1.64 | 1.62 |
| Conduit · home / profile / article (pairs) | 134 / 173 / 277 | 132 / 171 / 276 |

**The pairs sub-criterion still fires.** Conduit is at 7.22 pairs per key against a bar of 0.67,
eleven times over. The bar is not met by any reading of the median, and the slope is still above
linear. The other five sub-criteria are untouched by a read rule and read as in §0: bounded holds,
static fires, dynamic fires (14.5 %), value roots hold, trie fires.

**Why 179 pairs and not §4's 249.** §4 attributed three groups to "the frame's header". Two of
them are: `{header maybeViewer active}` (Page.beni:31) and the `case maybeViewer of` block inside
it (Page.beni:45). Each was called by 88 keys and is now called by **3**: the keys that replace a
page's session (`GotLoginMsg · CompletedLogin · Ok`, `GotRegisterMsg · CompletedRegister · Ok`,
`GotSettingsMsg · CompletedSave · Ok`). That is the shape `writes/TagHeader/` pins: typing leaves the
header alone, while sign-in and navigation reach it. Navigation is `ChangedUrl`, a `*` key that
runs `patchAll` and so is not counted in pairs. The third group is **not** the header. It is
`{page.content}` (Page.beni:32), the frame's slot for the page's own markup, whose reads are
every page's view. It went from 73 keys to 69 and remains the largest group, because almost every
page key changes something its page shows. The rest of the difference is five pairs on four holes of
the article, home and profile pages. §4's "6.44 without them" assumed all 249 pairs dropped; 7.22 is the
figure. Either is over the bar.

**What it cost.** No hole in any golden changed class (`static`, `literal`, `static-key`,
`dynamic`), on the corpus or in Conduit. The refinement moves only which keys mark a group. It
does not change which holes are static here, because none of these programs had a hole that read
only a tag nobody switches. Emitted JavaScript is unchanged: the pass runs only for the dump.
