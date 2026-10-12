# 78 — The ownership checker's slice 3b: the entry protocol, per platform

*2026-10-12. What `beni dump --stage=ownership` says once the functions a platform calls are checked through
its entry row (`ownership-checker.md` §20), `Cmd.map` and `Sub.batch` stop extending their callers' lists
(§19 item 1), and `Dict.update` is a focus primitive (§20.8) — over research 77's corpora, line by line
against slice 3a, and now per platform. Every figure is **[measured]** by §8's commands on the branch that adds
the slice (machine: AMD Ryzen 9 5950X, Linux 6.12, timings pinned with `taskset -c 7`).*

---

## 0. The answer

1. **All 88 pending TEA `update`s are decided, and they are decided differently per platform.** The 80 corpus
   programs, TodoMVC's four, the table app and Conduit now get one `entry` line per model path `update` writes
   (89 lines in the corpus). On **browser-direct** 56 of the corpus's 89 are **accepted `entry`**, and the table
   app is accepted; on **browser-tea** each of those is **rejected `platform`** — the same computation, then the
   template runtime's hold on the model (Change 8). Every other verdict is the same line on both platforms (§3).
2. **No acceptance was lost outside the entry protocol, and the platform change removes every key-path
   rejection.** Rejections outside the list-runtime tests went from 91 lines to 120, but 67 of the 120 are the new
   `platform` lines and 32 the entry lines' real causes; 70 of slice 3a's 91 are gone — `Cmd.map`'s and
   `Sub.batch`'s 69 (Conduit's 57, the six `Sub.batch` pages, the platforms' lines) and core's one
   `Dict.update` rejection (`Url.Parser`), which `Dict.focus` accepts (§2, §4). The other 21 stand.
3. **The applications, on browser-direct:** the table app is accepted. TodoMVC is rejected in all four
   variants: `top-level` where `init` is a top-level value (Change 4, T53), and `escaped` where `save` encodes
   the todos inside the command (thesis §7, *Fibers*). Conduit's five `update` paths are rejected `escaped`: one
   command, `Main.beni:205`, captures the whole model. Each fix the thesis proposes moves the program to the next
   wall, measured in §5: `owned sends` (Change 7) for Conduit and the coarse view-event rule (P6) for TodoMVC.
4. **The platform change costs nothing measurable.** `Cmd.map` now holds key paths outermost first and puts a
   new segment in front of a list of its own; browser-tea stops reversing paths. Conduit's release bundle is
   31 407 → 31 395 brotli bytes, every `bench/size.mjs` total is unchanged in release (721 314) and +51 bytes in
   development (+0.003 %), and the command micro-benchmark is within noise. `Sub.batch`'s joined list costs one
   `append([], …)` call: 260 → 270 ns (+4 %) on a micro-benchmark of three subscriptions, which a page evaluates
   once per render (§2).
5. **Cost.** The entry protocol made the pass 2.5× slower on Conduit as first built (29 ms); carrying the view's
   messages round the fixpoint doubled the entry model for no verdict, and without it the pass is **13.9 ms**
   against slice 3a's 11.9 (46 % of a check against 40 %). `bench/corpus` and core grow by 16 % and 9 % for the
   dictionary's representative conditions (§6).

## 1. What was measured

Research 77's corpora and commands, with two additions. Every corpus target that checks under browser-tea is
dumped a second time under browser-direct, and the table app, TodoMVC and Conduit under both; "corpus" below is
each target under the first platform it checks with, as before. The slice-3a column is master's binary
(`af7c8b24a`) on the same tree.

## 2. The platform change, and `Dict.focus`

**Key paths** (§19 item 1). Three forms were built and measured (`cmds n` is three `Cmd.map` over a batch of
three keyed items, `subs n` one `Sub.batch` of three listens; release builds, median of 28 rounds, 6 runs):

| Form | `Cmd.map` | `Sub.batch` | Bytes |
|---|---|---|---|
| master: `[ …path, segment ]`, `List.append list more` | 1 240 ns | 260 ns | — |
| `[ …List.copy path, segment ]`, `[ …List.copy list, …more ]` | +18 % | +22 % | ~0 |
| `List.concat [ list, more ]` (`Sub.batch`) | — | 124 ns (−52 %) | +130 brotli bytes on a page that reaches no other `concat` |
| **built**: `[ …[ segment ], …path ]` outermost first; `[ …[], …list, …more ]` | 1 285 ns (within noise) | 270 ns (+4 %) | Conduit −12 release brotli bytes |

`List.copy` copies before the construction copies again; `concat` is faster but drags in its loop. The built
`Cmd.map` form makes the new one-segment list the construction's base, so `path` is read, not written, and since
a path is now held as the architecture reads it, browser-tea's `item` drops its four `List.reverse`s. The six
browser-tea pages that use `Cmd.map` or `Sub.batch` run and print what they printed; their development run
hashes moved (`Tea.mjs`), their release hashes did not change behaviour.

**`Dict.focus`** (§20.8). `Dict.update` calls `focus`, whose body is `update`'s old one. A micro-benchmark of
`Dict.update` (grouping 2 000 keys into 37 lists, counting into 101, removing 2 000) is within noise in a
development build (305/188/914 µs against 320/188/938), and release output is byte-identical (`bench/size.mjs`).

## 3. The table, per platform

| Corpus | Lines | Accepted (fresh / call / param / callback-param / once / entry) | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 123 (120) | 123 (10 / 20 / 86 / 6 / 1 / 0) | 0 | 0 (1) | — |
| platforms | 15 (30) | 7 | 2 | 6 (12) | escaped 4, call 2 |
| table app, browser-tea | 5 (5) | 4 | 0 (1) | 1 (0) | platform 1 |
| table app, browser-direct | 5 | 5 (… entry 1) | 0 | 0 | — |
| TodoMVC, browser-tea | 8 (8) | 4 | 0 (4) | 4 (0) | escaped 2, top-level 2 |
| TodoMVC, browser-direct | 8 | 4 | 0 | 4 | escaped 2, top-level 2 |
| Conduit, browser-tea | 27 (100) | 22 | 0 (1) | 5 (57) | escaped 5 |
| Conduit, browser-direct | 27 | 22 | 0 | 5 | escaped 5 |
| corpus, not list-runtime | 520 (519) | 414 (53 / 49 / 286 / 26 / 0 / 0) | 2 (82) | 104 (21) | platform 66, top-level 12, payload 8, escaped 4, call 4, unknown 4, disjoint 2, exclusive 2, supply 2 |
| corpus TEA targets, browser-direct (80) | 297 | 260 (… entry 56) | 0 | 37 | platform 10, payload 8, top-level 4, unknown 4, escaped 4, call 4, exclusive 2, disjoint 1 |
| corpus, list-runtime tests | 179 (179) | 100 | 0 | 79 (79) | unchanged |

Slice 3a's figures in parentheses. On browser-direct the ten `platform` lines are programs written with
`Browser.program`, the `browser` platform's own constructor, which keeps the template row on every chain (and
which browser-direct refuses to build). Conduit's and the platforms' line counts fell because the key-path
call-site demands are gone.

**The entry lines of the 80 corpus programs**, both platforms:

| Verdict | browser-direct | browser-tea |
|---|---|---|
| accepted `entry` | 56 | — |
| rejected `platform` | 10 (`Browser.program`) | 66 |
| rejected `payload` — a message a view builds may hold the list (P6, coarse) | 8 | 8 |
| rejected `top-level` — `init` or a `Reset` arm names a top-level list (Change 4) | 4 | 4 |
| rejected `unknown` — the model's list came from JavaScript | 4 | 4 |
| rejected `escaped` — §18.6's rule: `view` calls `String.join` on a model list, whose `Js.pure` lambda is taken to keep it | 3 | 3 |
| rejected `escaped` — a command captured it | 1 | 1 |
| rejected `exclusive` — `NestedFor`: `List.swap`'s inferred summary loses exclusivity | 2 | 2 |
| rejected `disjoint` — `ForForms`: two model paths may hold one list after some message (arms joined) | 1 | 1 |

## 4. Every verdict change against slice 3a

**Pending → decided (88 lines).** The 80 corpus `value … pending: it is stored in a record` lines, TodoMVC's
four, the table app's and Conduit's are gone; their programs' `entry` lines are §3's. Two corpus lines,
`callback-param` demands of lambdas handed to the constructor, are now decided at the entry (`pending →
accepted`). The `value … accepted (no summary: Tea.sandbox)` lines browser-direct printed are gone too: the
constructor is no longer a callee without a summary.

**Rejected → gone (70 lines).** `Cmd.map`'s key-path call-site demands (Conduit 57, the platforms' `Cmd` 4),
`Sub.batch`'s (six pages, browser-tea's `Tea` 1), browser-tea's `settle` (1), and the platforms' `escaped`
lines of `Cmd`. Core's `Url.Parser` `Dict.update` line is accepted `callback-param` (`Dict.update supplies it
owned`), and the three `Dict` lines it reached moved with the text added above them.

**Accepted → rejected: none** outside the entry lines, which are new. Fixture summaries changed where a
dictionary is re-filled from itself: `Toplevel`'s `bump` (`Dict.get` then `Dict.insert` at the same key) now
says its values may share (`{lost}`) — the analysis cannot tell the key is the same, and the idiom `Dict.update`
replaces is now the precise one.

## 5. The applications, and what each fix leads to

| Program | browser-direct, as written | After the thesis's fix | Then |
|---|---|---|---|
| table app | accepted `entry` | — | — |
| TodoMVC `Sandbox`, `NoStorage` | `top-level`: `init = init`, a top-level model (T53) | `init = init ⊤`: rejected `payload` (view events carry `Html.Event`, a foreign type that may hold anything, so the coarse P6 rule fires) | a summary split by message constructor (§20.11 item 3), or a crossing `Html.Event` |
| TodoMVC `NoEditing`, `NoRouting` | `escaped`: `save` encodes the todos inside `Cmd.do` | `text = encode todos` before the command: still `escaped`, because `encode` hands the list to a `Js.pure` lambda (§18.6) | Change 5's words on `Js.pure` |
| Conduit | `escaped`: `Main.beni:205` captures `model` whole in a command (thesis T45's second form) | `key = Session.navKey (toSession model)` first: rejected `payload` on its five paths — articles, comments and errors arrive by HTTP and are stored in the model | owned sends (Change 7) |

## 6. What it costs

`--self-profile`'s `ownership` event against the `check` events of the same run, best of 7:

| Target | Slice 3a | Slice 3b as first built | Slice 3b |
|---|---|---|---|
| Conduit, browser-tea | 11.9 ms, 40 % | 29.3 ms, 98 % | **13.9 ms, 46 %** |
| Conduit, browser-direct | 9.8 ms, 31 % | 29.4 ms, 92 % | **14.0 ms, 43 %** |
| `bench/corpus` | 6.7 ms, 40 % | 7.6 ms | **7.8 ms, 46 %** |
| core | 12.5 ms, 74 % | 13.2 ms | **13.6 ms, 79 %** |

Conduit's entry model reached 2 107 entries when the cells a view puts in messages rode the fixpoint; read once
from the settled model instead (every demand they reach is the payload rule's anyway, §20.4 *As built*), it
settles at 1 174 in four rounds, and the rounds compute cells only, the settled one lowering conditions once.
The `bench/corpus` and core growth is the dictionary's representative conditions (`sep` atoms between what a
tree stores at one folded path); slice 4's embedded summaries remain the large lever (§19 item 4).

## 7. What the external-corpus slice should measure next

1. **Owned sends** (Change 7) are the next wall for real applications: Conduit's five paths, after the one
   capture is hoisted, are all HTTP payloads stored in the model. Count, per ported app, the entry lines
   rejected `payload` with a stored payload and no view-event cause — the number Change 7 would recover.
2. **The coarse view-event rule** (P6). Count entry lines whose only cause is a view message, and how many of
   those messages' types are foreign (`Html.Event`) or cross: a constructor-split `update` summary, or foreign
   types that declare they cross, decides them.
3. **`init` as written in Elm apps** (Change 4): the share of ported programs whose `init` is a top-level value;
   each is rejected at its first in-place edit until it becomes `init ⊤`.
4. **§18.6's `Js.pure` rule** at the entry: `String.join`, `encode` and every core function over `Js` that a
   `view` or an `update` calls escapes the model's list; Change 5's words on those functions are the fix, and the
   count says which first.
5. **Commands that capture the model whole** (T45): count captures of `model` against captures of a field;
   per-path captures through callee summaries would narrow the first kind.
6. **Permutations**: `List.swap`'s inferred summary loses exclusivity (`NestedFor`); count element edits in
   programs that also swap or sort.

## 8. How to reproduce

```sh
zig build -Doptimize=ReleaseFast
B=./zig-out/bin/beni
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni          # and browser-tea
$B dump --stage=ownership --platform=browser-direct examples/conduit/src
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/Sandbox.beni
$B dump --stage=ownership --self-profile=p.json --platform=browser-tea examples/conduit/src
node bench/size.mjs --beni=$B
```

The corpus sweep is research 77's, with each target that checks under browser-tea dumped again under
browser-direct; lines are matched with slice 3a's by target, module, position, operation and base. The
command and dictionary micro-benchmarks build a `--library` program and time its exported functions in Node,
the builds interleaved round by round.
