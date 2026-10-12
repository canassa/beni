# 81 — The ownership checker's slice 3e: ownership words, and the decoder in `Expect`

*2026-10-12. What `beni dump --stage=ownership` says once core's and the platforms' signatures carry
ownership words (`ownership-checker.md` §24; thesis Change 5(a), the owner's decision of 2026-10-12), a
`foreign` without words gets the thesis's row, and the decoder an `Http.Expect` holds is followed into its
tagger's payload (§24.9) — over research 80's applications and corpus, per platform, line by line against
slice 3d. Every figure is **[measured]** by §7's commands on the branch (AMD Ryzen 9 5950X, Linux 6.12; the
machine was shared, load average 11–14 throughout, so timings are given as best and median of many interleaved
runs).*

---

## 0. The answer

1. **TodoMVC** is accepted on browser-direct, all four programs: each `update`'s push onto `model.todos` is
   `entry`. `Sandbox` and `NoStorage` were rejected `payload` because their messages carry an `Html.Event`, a
   foreign type that could stand for a list; `Html.Event` is `crossing` now, so their messages carry no cell.
   `NoEditing` and `NoRouting` were rejected `escaped` through `String.join`, which only reads now
   (`borrowed`). On browser-tea all four are `platform`, the position rule (Change 8), as they should be.
2. **Conduit**'s 26 rejections stand — 19 `need`, 5 `payload`, 2 `unknown` — but the 21 HTTP lines now have
   their real cause. The decoder is followed: `Api.send` returns at `#Ok.0` what its parser returns and fresh
   errors, with one `⊤` left at `#Err.0#Failed.0#BadRequest.0` — the request's `Problem`, which the decoders
   forward from the answer, and which comes back through `Task.callback` from JavaScript when a request fails in
   flight. **Measured counterfactually**, a two-constructor failure in `Http.wait`'s `Step` (no change of
   behaviour or API) clears all 21: Conduit is then 29 lines, 5 rejected, all `payload` (O6). Not built: that
   reshapes platform code to clear a check, which is the owner's call (§4, `ownership-checker.md` §24.11).
3. **The table app** is unchanged: `entry` on browser-direct, `platform` on browser-tea.
4. **Every verdict change** (§3): 42 corpus lines change, none an acceptance lost. Three entry lines become
   `entry` on browser-direct (`TypedKeys`, `KeyOrder`, `DefectReleasesHost`); 34 lines rejected `escaped` or
   `unknown` only because `Debug.toString`, `Debug.log` or a `foreign` escaped them now show the exact cause the
   text has — `top-level` 30, `later-use` 2, `alias` 1, `disjoint` 1; five browser-tea entries become `platform`.
   One assumed acceptance becomes `pending` (`ControlledInput`): a writing `update` handed to a `foreign` with no
   words is no longer taken to be called nowhere.
5. **Remaining rejections by cause** (§4): on the applications, 5 `payload` (O6) and 21 HTTP lines (the
   failure's type, above). Of the corpus's 45 on TEA targets on browser-direct: `platform` 11 (correct), `payload`
   9 (O6), `need` 8 and `unknown` 5 (the HTTP failure, `Random.generate`'s seed, `Http.send`'s decoder in a
   lambda), `call` 4, `top-level` 4 (correct), `escaped` 2, `disjoint` 1, `supply` 1.
6. **Cost.** Emitted JavaScript does not move: every `.mjs` is byte for byte master's, and Conduit's and the
   table app's `--release` trees are identical. The source maps of `core/` and platform modules embed the edited
   sources, so the run hashes were re-recorded, in a commit of their own. The pass is *faster* on Conduit — best
   of 41, 41–45 ms on master, 33–34 ms on the branch; medians 65–68 and 55–58 — because the `Js` words replace
   conservative calls whose `⋆` entries the walk carried everywhere.

## 1. What was measured

Research 80's applications and corpus sweep, re-implemented: every `.beni` file under `tests/corpus` and every
project directory there dumped under the first platform it checks with — none, `node`, `tests/platforms/page`,
`browser-tea`, `browser-direct`, `browser`, `html` — and each that checks under `browser-tea` dumped again under
`browser-direct`; master's binary (`e283176cf`) over master's tree and the branch's over its own. Lines are
matched by target, platform, operation, base and position. The ownership fixtures are counted on their own row.

## 2. The table, per platform

| Corpus | Lines | Accepted | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 123 (123) | 123 | 0 | 0 | — |
| table app, browser-tea | 5 (5) | 4 | 0 | 1 | platform 1 |
| table app, browser-direct | 5 (5) | 5 (… entry 1) | 0 | 0 | — |
| TodoMVC, browser-tea | 8 (8) | 4 | 0 | 4 (4) | platform 4 (payload 2, escaped 2) |
| TodoMVC, browser-direct | 8 (8) | 8 (4) | 0 | 0 (4) | — (payload 2, escaped 2) |
| Conduit, browser-tea and browser-direct | 48 (48) | 22 | 0 | 26 | need 19, payload 5, unknown 2 |
| Conduit, with a two-constructor HTTP failure | 29 | 24 (call 2) | 0 | 5 | payload 5 |
| corpus, first platform | 734 (735) | 533 (534) | 4 | 197 (197) | platform 73, top-level 57, call 17, later-use 15, payload 9, need 8, unknown 5, alias 4, disjoint 3, supply 3, escaped 2, exclusive 1 |
| corpus TEA targets, browser-direct | 319 (319) | 273 (270) | 1 | 45 (48) | platform 11, payload 9, need 8, unknown 5, call 4, top-level 4, escaped 2, disjoint 1, supply 1 |
| ownership fixtures | 419 (370) | 266 (237) | 3 | 150 (130) | the new fixtures' own lines (§24.10) |

Slice 3d's figures in parentheses where they differ. On the first platform `escaped` falls from 39 to 2 and
`top-level` rises from 27 to 57: the run fixtures print with `Debug`, which escaped everything it was handed,
so a write of a top-level list was reported as the escape. The corpus line lost is `ControlledInput`'s assumed
acceptance (§3).

## 3. Every verdict change against slice 3d

| Where | 3d | 3e | Why |
|---|---|---|---|
| TodoMVC `Sandbox`, `NoStorage`, browser-direct | `payload` | `entry` | `Html.Event` is `crossing` (`WordsBrowser` pins it) |
| TodoMVC `NoEditing`, `NoRouting`, browser-direct | `escaped` | `entry` | `String.join` is `borrowed` (`Words`) |
| TodoMVC, all four, browser-tea | `payload` / `escaped` | `platform` | the same, and then the position rule |
| `browser/tea/KeyOrder`, browser-direct | `escaped` | `entry` | its view joins `model.seen` with `String.join`, which only reads |
| `browser/tea/TypedKeys`, browser-direct | `escaped` | `entry` | its commands' keys are held by the key (`Hosted.keyOf`, `aliased`), not given to JavaScript, and `Debug.log` only reads |
| `browser/tea/DefectReleasesHost`, browser-direct | `unknown` | `entry` | an arm ends in `Debug.todo`, a `Js.throw`, which never returns: its result is `fresh` |
| the same four on browser-tea, and `browser/dom/LetInMarkup` on both | `escaped` / `unknown` | `platform` | the next cause; `LetInMarkup` is a `Browser.program` |
| `run/ListIndexed` (26), `run/ListForms` (4) | `escaped` | `top-level` | `Debug.toString` reads (`borrowed`): the write is of a top-level list |
| `run/ListSpreadPatterns` (4) | `escaped` | `later-use` 2, `alias` 1, `disjoint` 1 | the same: the sharing the text shows |
| `browser/ControlledInput`, `tests/platforms/page` | accepted `callback-param` (no summary: `Page.sandbox`) | — (`pending` stays) | a `foreign` without words keeps what it is handed and may call it later (§24.5) |

No acceptance was lost. HTTP lines did not change verdict: the decoder is followed, and what it returns still
holds the failure's `⊤`.

## 4. What is still rejected, by cause

| Cause | Applications | Corpus TEA targets, browser-direct | What clears it |
|---|---|---|---|
| `payload` — view events (P6) | 5 (Conduit) | 9 | **O6**: `update`'s summary split by its message's constructor |
| `need` / `unknown` — an HTTP answer's failure | 21 (Conduit) | 11 | `Http.wait`'s `Failed` holding a two-constructor failure rather than a `Response String` (measured: clears all of Conduit's), or a row for `Task.callback`'s `Resume` (thesis A2: what it is handed is given up and returned) |
| `need` — `Http.send`'s decoder | 0 | 1 | slots inside a lambda (§24.9): `Http.send` calls `transfer` in the body `Cmd.task` runs |
| `need` — `Random.generate` | 0 | 1 | a limit: the seed is a `Js.ref`; words on `Random` |
| `platform` | 0 | 11 | correct |
| `top-level` | 0 | 4 | correct |
| `call` | 0 | 4 | a limit: conservative calls |
| `escaped` | 0 | 2 | `EntryCommand`-shaped: a command's capture, correct; `HttpMultipart`'s body list handed to `FormData` through `Js.call`, honest |
| `disjoint`, `supply` | 0 | 2 | limits: arms joined (`ForForms`), a send handed to a record (`DebouncedSearch`) |

## 5. Behaviour, bytes and speed

**Behaviour.** No `.expected` moved; the words are erased by lowering. **Bytes.** Every emitted `.mjs` is
master's byte for byte; Conduit's and the table app's `--release` output trees are identical
(`diff -rq`). `core/`'s and the platforms' `.mjs.map` files embed the edited `.beni` sources, which is what moved
the run hashes. **The pass.** Conduit, `--self-profile`'s `ownership` event, interleaved, `taskset -c 7`, load
average 11–14:

| Platform | master best / median | branch best / median |
|---|---|---|
| browser-tea | 45.0 / 68.2 ms | 34.4 / 57.7 ms |
| browser-direct | 41.2 / 65.0 ms | 32.6 / 54.7 ms |

Research 80 measured 15–19 ms on a quieter machine; the ratio is what this run supports: about a fifth less.

## 6. What the next slice should measure

1. **The HTTP failure**: whether the owner takes the two-constructor failure, or a row for `Task.callback`.
2. **O6** is the whole remaining application cause after that.
3. **The trusted surface** (§24.11 item 2): rows for `Ref`, `Deferred`, `Task` and the schema engine, counted by
   what they clear.

## 7. How to reproduce

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out/fast
B=./zig-out/fast/bin/beni
$B dump --stage=ownership --platform=browser-direct examples/conduit/src      # and browser-tea
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/Sandbox.beni
$B dump --stage=ownership core                                                # the (words) lines
$B dump --stage=ownership --platform=browser-direct --self-profile=t.json examples/conduit/src
```

The corpus sweep is §1's; the counterfactual replaces `Http.wait`'s `Failed (Response String)` by `Failed
Failure` with `type Failure = TimedOut | Unreachable` and maps it back to `Timeout_` and `NetworkError_` where
the answer is read.
