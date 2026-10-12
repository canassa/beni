# 79 — The ownership checker's slice 3c: `init` a function, commands that take values, `swap`

*2026-10-12. What `beni dump --stage=ownership` says once every platform's `init` is a function of `⊤`
(`boundary.md` §9.8.16 (a), `ownership-checker.md` §22.2), the platform has commands that take values
(§9.8.16 (b)), TodoMVC and Conduit use them, and `List.swap`'s row keeps exclusive contents (§22.5) —
over research 78's corpora, line by line against slice 3b, per platform. Every figure is **[measured]**
by §7's commands on the branch that adds the slice (machine: AMD Ryzen 9 5950X, Linux 6.12, timings
pinned with `taskset -c 7`).*

---

## 0. The answer

1. **TodoMVC** is rejected in all four variants on both platforms, each now at the wall the thesis
   names next. `Sandbox` and `NoStorage`, whose `init` was a top-level value, are `init ⊤ = …` and no
   longer `top-level`; they are rejected `payload` — the coarse view-event rule (P6): their view events
   carry `Html.Event`, a foreign type that may hold anything. `NoEditing` and `NoRouting` save with
   `Storage.save`, so no command holds the todos; they stay `escaped`, now because `encode` calls
   `String.join`, whose `Js.pure` lambda §18.6 takes to keep the list (`summary encode: π1[*] RJ`) —
   Change 5's words, not a command.
2. **Conduit**'s five `update` paths went from `escaped` to `payload` on both platforms: the one command
   that captured the whole model (`Main.beni:205`) reads its navigation key first, and what is left is
   every list the model stores from an HTTP answer — **owned sends** (Change 7), which slice 3d builds.
   These five are the only owned-send rejections measured.
3. **The table app** is unchanged: accepted `entry` on browser-direct, `platform` on browser-tea.
4. **Every verdict change** (§3): those 7 application lines; `NestedFor`'s two `exclusive` lines, which
   `swap`'s row turns into `entry` on browser-direct and `platform` on browser-tea; and the new fixture
   page `ValueCommands`, whose two entry lines are rejected `payload` (P6: its view renders the lists
   it pushes). Nothing accepted became rejected; core and the platforms did not move.
5. **Remaining rejections by cause** (§4): on browser-direct, the corpus's TEA targets have 37 — 10
   `platform` (`Browser.program`), 10 `payload` (all view events, P6), 4 each `top-level`, `escaped`,
   `unknown` and `call`, 1 `disjoint`; `exclusive` is gone. **`payload` rejections from owned sends:
   5, all Conduit**; from view events: 12 (the corpus's 10, TodoMVC's 2).
6. **Cost.** The migration changed no page's output: every `browser/` and `run/` golden is what it was
   but `InitThrows`' browser-tea one, which is now the same as browser-direct's (§5). Release bytes move
   by −48 to +23 brotli per page — an `init` record field and its call where a value was, and `Storage.save`
   with a message in TodoMVC — and the table app's operations are within noise (§5). The pass costs
   what it did (Conduit 15.6 ms against 15.8).

## 1. What was measured

Research 78's corpora and commands. The slice-3b column is master's binary (`7ac788fbe`) over master's
tree, since master's binary cannot check the migrated programs; lines are matched by target, module,
line and operation, the column ignored (the migration moves it), and a line moved by the formatter's
reflow of a record is counted as unchanged.

## 2. The table, per platform

| Corpus | Lines | Accepted (fresh / call / param / callback-param / once / entry) | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 123 (123) | 123 (10 / 20 / 86 / 6 / 1 / 0) | 0 | 0 | — |
| platforms | 15 (15) | 7 | 2 | 6 | escaped 4, call 2 |
| table app, browser-tea | 5 (5) | 4 | 0 | 1 | platform 1 |
| table app, browser-direct | 5 (5) | 5 (… entry 1) | 0 | 0 | — |
| TodoMVC, browser-tea | 8 (8) | 4 | 0 | 4 | payload 2 (top-level 2), escaped 2 |
| TodoMVC, browser-direct | 8 (8) | 4 | 0 | 4 | payload 2 (top-level 2), escaped 2 |
| Conduit, browser-tea | 27 (27) | 22 | 0 | 5 | payload 5 (escaped 5) |
| Conduit, browser-direct | 27 (27) | 22 | 0 | 5 | payload 5 (escaped 5) |
| corpus, not list-runtime | 530 (523) | 421 (53 / 49 / 292 / 27 / 0 / 0) | 3 | 106 (104) | platform 68, top-level 12, payload 10, call 4, escaped 4, unknown 4, supply 2, disjoint 2 |
| corpus TEA targets, browser-direct | 304 (297) | 267 (… entry 58) | 0 | 37 (37) | platform 10, payload 10, call 4, top-level 4, escaped 4, unknown 4, disjoint 1 |
| corpus, list-runtime tests | 179 (179) | 100 | 0 | 79 | unchanged |

Slice 3b's figures in parentheses where they differ. The corpus grew by `ValueCommands` (7 lines, 2 of
them entry lines rejected `payload`); without it the corpus's rejections are 104 → 104, `exclusive 2`
having become `platform 2` on browser-tea and `entry 2` on browser-direct.

**The entry lines of the corpus programs**, both platforms:

| Verdict | browser-direct | browser-tea |
|---|---|---|
| accepted `entry` | 58 (56) | — |
| rejected `platform` | 10 (`Browser.program`) | 68 (66) |
| rejected `payload` — a view event's message may hold the list (P6) | 10 (8; +2 `ValueCommands`) | 10 (8) |
| rejected `top-level` — `init` returns, or a `Reset` names, a top-level list (T53) | 4 | 4 |
| rejected `unknown` — the model's list came from JavaScript | 4 | 4 |
| rejected `escaped` — §18.6 (`String.join`, a `Js` lambda) or a command | 4 | 4 |
| rejected `exclusive` — `NestedFor`'s `swap` | 0 (2) | 0 (2) |
| rejected `disjoint` — `ForForms` | 1 | 1 |

The four `top-level` lines are T53 through `init = λ⊤ → { rows = rows }` with `rows` a top-level list
(`KeyedInPlace` twice, `KeyedInPlaceMap`) and a component's top-level `init` value (`writes/Pages`'
`Feed.init`): the migration wrapped them, as `frontend.md` §11.10 says it does, and they stay rejected
until each writes its list in a function.

## 3. Every verdict change against slice 3b

| Where | 3b | 3c | Why |
|---|---|---|---|
| Conduit `Main.update`, 5 paths, both platforms | `escaped` | `payload` | `ClickedLink`'s command reads the key first, so it holds no model (§22.3); HTTP payloads stored in the model remain (Change 7) |
| TodoMVC `Sandbox`, `NoStorage`, both platforms | `top-level` | `payload` | `init ⊤ = …` builds the list per mount; their view events carry `Html.Event` (P6) |
| TodoMVC `NoEditing`, `NoRouting`, both platforms | `escaped` | `escaped` | the same cause line; the escape moved from the command's closure to `encode`'s `String.join` (§18.6) |
| `browser/direct/NestedFor`, `model.groups` and `model.groups[*].kids` | `exclusive` | `entry` (direct), `platform` (tea) | `swap`'s asserted row keeps exclusive contents (§22.5) |
| `browser/tea/ValueCommands` (new) | — | 5 accepted, 2 `payload` | a new fixture page; its view renders the lists it pushes |

No acceptance was lost. The platforms' and core's lines are the same lines (`browser-tea`'s `Tea` moved
three lines down, its doc comments longer). Of the ownership fixtures, `EntryInit` gains
`fromTopFunction` (`top-level` through a named `init ⊤ = initialModel`) and `fromLambda`, and runs on
browser-tea too; `EntryInitProgram`, `EntryValueCommand` and `Permutations` are new (§22.6).

## 4. What is still rejected, by cause

| Cause | Corpus TEA targets, browser-direct | Applications, browser-direct | Next |
|---|---|---|---|
| `payload`, owned sends (Change 7) | 0 | 5 (Conduit) | slice 3d |
| `payload`, view events (P6) | 10 | 2 (TodoMVC `Sandbox`, `NoStorage`) | a summary split by message constructor (O6), or `Html.Event` declared to cross |
| `escaped` | 4 | 2 (TodoMVC `NoEditing`, `NoRouting`) | Change 5's words on `String.join` and `Js.pure` (3 corpus lines and TodoMVC); one corpus `TodoMVC` page saves through `Cmd.do` |
| `platform` | 10 | — | programs written with `Browser.program`, which browser-direct refuses to build |
| `top-level` | 4 | — | the program's own `init` |
| `unknown` | 4 | — | lists from JavaScript |
| `call` | 4 | — | conservative calls |
| `disjoint` | 1 | — | arms joined (`ForForms`) |

## 5. Behaviour, bytes and speed

**Behaviour.** Every `browser/` and `run/` page prints what it printed, in development and release, but
`browser/direct/InitThrows` under browser-tea: its `init` now throws at mount, inside the dispatch
guard, and the page shows the crash screen as browser-direct's does, so its `.tea-expected` is deleted
and the two platforms share one golden. Run hashes were re-recorded in their own commit (229 records).
`emit/direct/` did not move by a byte; two `emit/release/split/` pages did (`backend.md` §15.11's
amendment), and four `build/bad/direct/` diagnostics: a column, the `program_mounted_twice` hint's
example, and `SuspendingInit`, whose suspending `init` is now refused where it is written
(`sync_boundary`) instead of at `main`.

**Bytes** (`bench/size.mjs`, and the applications built with `--release`, brotli 11):

| Page | Release brotli, 3b → 3c |
|---|---|
| empty `browser`, `browser-tea` page | 446 → 447 |
| `browser-tea element` | 1 148 → 1 156 |
| `browser-tea random`, `links`, `navigation` | 1 917 → 1 935, 3 786 → 3 805, 3 919 → 3 942 |
| `browser-direct` pages, the table app on browser-direct | unchanged |
| table app, browser-tea | 5 407 → 5 408 |
| TodoMVC `Sandbox`, `NoStorage` (browser-tea) | 6 225 → 6 228, 8 607 → 8 559 |
| TodoMVC `NoEditing`, `NoRouting` (browser-tea, `Storage.save` and a `NotSaved` message) | 8 282 → 8 298, 7 649 → 7 665 |
| `tests/corpus/browser/tea/TodoMVC` (`bench/size.mjs`'s TodoMVC line) | 8 976 → 8 958 |

The growth on an `element` page is `init` as a record field the release optimiser cannot see through:
`Tea.element`'s hosted `init` calls `app.init()`, which it does not know to be pure, so the record keeps
the function and the call where it used to inline the model into the first state (`{a:"",…}` stays
inlined; `a.init()` and `init:()=>({})` are added). It is at most 23 bytes, on the navigation page;
the owner's API decision buys it, and a purity fact for a record field's lambda would take it back.

**Speed** (the table app on browser-tea, `--release`, happy-dom in Node, 16 interleaved processes, the
median of six operations each after two warm-ups, `[q1–q3]`):

| ms | mount | create 1 000 | swap | update every 10th | clear |
|---|---|---|---|---|---|
| 3b | 8.69 [8.36–9.16] | 147.2 [136.4–152.9] | 0.88 [0.60–0.92] | 0.34 [0.31–0.37] | 11.31 [10.87–11.80] |
| 3c | 8.89 [8.35–9.15] | 143.2 [139.2–151.0] | 0.93 [0.85–1.01] | 0.36 [0.31–0.39] | 11.51 [11.38–11.71] |

Every quartile range overlaps: within noise. `init` is called once per mount; no per-message path
changed.

**The pass** (`--self-profile`'s `ownership` event, best of 7): Conduit 15.8 → 15.6 ms on browser-tea
(46 → 45 % of the check), 16.1 → 15.9 ms on browser-direct.

## 6. What the external-corpus slice should measure next

1. **Owned sends** (3d): Conduit's five paths are now the only `payload` lines whose cause is a send.
2. **The view-event rule** (O6): 12 lines, TodoMVC's two among them, are its alone.
3. **The encoders** (Change 5): `String.join` decides TodoMVC's two saving variants and three corpus
   lines; `Schema.print` would decide the same for a page that sends JSON with `Http.send`.
4. **Navigation commands** (`ownership-checker.md` §22.7 item 1): Conduit's capture was a `Cmd.do` that
   computed its key inside; count such bodies in ported programs.

## 7. How to reproduce

```sh
zig build -Doptimize=ReleaseFast
B=./zig-out/bin/beni
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni          # and browser-tea
$B dump --stage=ownership --platform=browser-direct examples/conduit/src
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/NoRouting.beni
node bench/size.mjs --beni=$B
```

The corpus sweep is research 78's: every target dumped under the first platform it checks with, and
each that checks under browser-tea again under browser-direct, master's binary over master's tree and
this branch's over this one. The speed figures load the release build of `bench/ui/apps/beni` into
happy-dom (`tests/browser/happy-dom.mjs`), time the module's import as the mount, then click each
benchmark button and call the runtime's `flush`, eight times per process.
