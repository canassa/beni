# 80 — The ownership checker's slice 3d: owned sends, navigation as commands

*2026-10-12. What `beni dump --stage=ownership` says once a send hands its payload to `update` owned
(`ownership-checker.md` §23, the owner's decision of 2026-10-12, thesis Change 7) and `Browser.Navigation`'s
Elm names are commands that take values (`boundary.md` §9.8.17) — over research 79's corpora, per platform,
line by line against slice 3c. Every figure is **[measured]** by §7's commands on the branch that adds the slice
(AMD Ryzen 9 5950X, Linux 6.12; the machine was shared, load average 7–12, so timings are pinned with
`taskset -c 7` and given as ranges).*

---

## 0. The answer

1. **TodoMVC** is unchanged on both platforms: `Sandbox` and `NoStorage` rejected `payload`, now the
   view-event rule alone (P6); `NoEditing` and `NoRouting` `escaped` through `String.join` (Change 5). None of
   its four programs sends a list, so owned sends change nothing in it.
2. **Conduit**'s five `update` paths stay rejected `payload` on both platforms, but the cause moved: slice 3c's
   reason — the HTTP answer stored in the model may still be held by its sender — is gone, since every send now
   gives its payload up, and what is left is the view-event rule (its view's markup holds the model's lists, P6).
   The owner's rule puts the check at the senders instead: **21 new lines, all rejected, all approximate** — 19
   `need` at a `Cmd.task` tagger whose work answers an HTTP request (the decoder is a function stored in `Expect`,
   which the walk does not follow, over text from JavaScript) and 2 `unknown` at bodies that send a list decoded
   from JavaScript. Navigation is commands now: no Conduit command reads its model.
3. **The table app** is unchanged: accepted `entry` on browser-direct, `platform` on browser-tea.
4. **Every verdict change** (§3): the five Conduit paths change reason, not verdict; `EntryPayload`'s two
   owned-send rejections become `entry`; one corpus entry line (`HttpMultipart`) shows its next cause,
   `escaped`; two list-runtime lines are reported `later-use` where they said `once` (§23.7's order); and 12
   send-site lines per platform appear in 11 corpus pages. **No acceptance was lost.**
5. **Remaining rejections by cause** (§4): on the applications, 7 `payload` (view events: O6), 19 `need` and 2
   `unknown` (HTTP answers: Change 5 and a class for `Expect`'s callback), 2 `escaped` (Change 5). Of the 44 the
   corpus's TEA targets have on browser-direct, 9 are `payload` (O6), 8 `platform` (programs written with
   `Browser.program`, correct), 21 are Change 5's or the HTTP limit's, and 6 are limits of the analysis.
6. **Cost.** The table app and all four TodoMVC programs build byte for byte as on master; a create-1 000 on the
   table app is within noise (§5). The navigation API costs a `browser-tea` navigation page 19 brotli bytes,
   `ApiAndRoutes` 11 and Conduit 37 — each a refusal tagger and its arm the API now asks for. The pass costs
   about a fifth more on Conduit (15.4–16.1 → 18.8–19.2 ms), which has 21 more lines to decide.

## 1. What was measured

Research 79's applications and commands, and its corpus sweep, re-implemented: every `.beni` file under
`tests/corpus` and every project directory there (2 160 targets on this branch, 2 155 on master) dumped under the
first platform it checks with — none, `node`, `tests/platforms/page`, `browser-tea`, `browser-direct`,
`browser`, `html` — and each that checks under `browser-tea` dumped again under `browser-direct` (1 414 dumps
here, 1 404 on master). Lines are matched by target, platform, module, line and operation. The slice-3c column is
master's binary (`f86d202bb`) over master's tree, since master's binary cannot check the migrated programs; the
migrated pages (`Routes`, `Router`, `ListenerOrder`, …) moved by a few lines, and a moved line with its verdict
unchanged is counted as unchanged. The corpus rows leave out `tests/corpus/ownership/`, whose fixtures exist to
be rejected and are counted on their own row.

## 2. The table, per platform

| Corpus | Lines | Accepted | Pending | Rejected | Rejected by cause |
|---|---|---|---|---|---|
| core | 123 (123) | 123 | 0 | 0 | — |
| platforms | 18 (15) | 10 (7) | 2 | 6 | escaped 4, call 2 |
| table app, browser-tea | 5 (5) | 4 | 0 | 1 | platform 1 |
| table app, browser-direct | 5 (5) | 5 (… entry 1) | 0 | 0 | — |
| TodoMVC, browser-tea | 8 (8) | 4 | 0 | 4 | payload 2, escaped 2 |
| TodoMVC, browser-direct | 8 (8) | 4 | 0 | 4 | payload 2, escaped 2 |
| Conduit, browser-tea | 48 (27) | 22 | 0 | 26 (5) | need 19, payload 5, unknown 2 |
| Conduit, browser-direct | 48 (27) | 22 | 0 | 26 (5) | need 19, payload 5, unknown 2 |
| corpus, not list-runtime | 535 (520) | 421 (419) | 3 (2) | 111 (99) | platform 67, payload 9, need 8, top-level 8, unknown 6, call 4, escaped 4, supply 3, disjoint 2 |
| corpus TEA targets, browser-direct | 309 (294) | 264 (… entry 59) | 1 (0) | 44 (33) | payload 9, need 8, platform 8, unknown 6, call 4, escaped 4, top-level 3, supply 1, disjoint 1 |
| corpus, list-runtime tests | 179 (179) | 100 | 0 | 79 | unchanged but two `once` → `later-use` |
| ownership fixtures | 350 (302) | 229 (204) | 3 | 118 (95) | the new fixtures' own lines (§3) |

Slice 3c's figures in parentheses where they differ. The platforms gained three lines, all accepted: the sends
`Cmd.task`, `Storage.save` and `Navigation`'s command helper make (`send <call>: accepted call`). The corpus
grew by `NavigateCommands` (3 lines on each platform, the entry accepted on browser-direct).

## 3. Every verdict change against slice 3c

| Where | 3c | 3d | Why |
|---|---|---|---|
| Conduit `Main.update`, 5 paths, both platforms | `payload` (sender may hold it) | `payload` (view events) | sends give their payload up (§23.2); the view's markup holds the model's lists (P6) |
| Conduit, 19 `Cmd.task … Completed…` taggers, both platforms | — | `need`, approx | the work answers HTTP: its decoded value is `⊤` at `⋆`, through `Expect` (§23.12 item 2) |
| Conduit `Home` 135, `ProfilePage` 164, both platforms | — | `unknown`, approx | a body sends `CompletedFeedLoad` of a list decoded from JavaScript |
| `ownership/EntryPayload` `stores`, `edits` | `payload` | `entry` | T38, T50: owned at the send |
| `browser/tea/HttpMultipart` entry | `payload` | `escaped` | its payload is owned; the next cause is a command's capture |
| `browser/tea` `ApiItems`, `ApiLogin` ×2, `HttpMultipart`, `RaceTwoServices`, `TimeoutAroundRequest`, `ValueCommands` (new lines) | — | `need`, approx | HTTP answers, as Conduit's |
| `browser/tea/RandomValues` (new line) | — | `need` | `Random.generate`'s value comes from a seed held in JavaScript |
| `browser/tea` `HttpCancel`, `HttpProgress` (new lines) | — | `unknown`, approx | a body sends a list decoded from JavaScript |
| `browser/tea/DebouncedSearch` (new line) | — | `supply`, approx | `search` hands its send to the page's API record, which the walk does not follow |
| `browser/tea/ReentrantSend` (new line) | — | `pending` | it sends its own send value, stored in a tuple |
| `run/ListForms` 95, 97 | `once` | `later-use` | a once closure's exact creation failure is reported first (§23.7) |

No acceptance was lost. The new ownership fixtures — `OwnedSend`, `ViewEventPayload`, `NavigationCommands`, `T29`
(§23.11) — are 48 lines; `T29` is `escaped`, as before owned sends, and `browser/tea/SyncCommandOrder` still pins
the dispatch order T29 rests on.

## 4. What is still rejected, by cause

| Cause | Applications (browser-direct) | Corpus TEA targets, browser-direct | What clears it |
|---|---|---|---|
| `payload` — view events (P6) | 7 (Conduit 5, TodoMVC 2) | 9 | **O6**: `update`'s summary split by its message's constructor, and markup whose handlers' messages are told apart from what it renders — Conduit's and TodoMVC's views hold the model's lists in their markup, not in a message |
| `need` — an HTTP answer handed to a tagger | 19 (Conduit) | 7 | **Change 5** (the array `JSON.parse` makes is new: `Js` words for it) **and a class for `Expect`'s callback**, a function stored in a record (§16.5) — a real limit of the analysis today |
| `need` — `Random.generate` | 0 | 1 | a limit: the seed is a `Js.ref`; Change 5's words on `Random.value` |
| `unknown` — a list decoded from JavaScript, sent or stored | 2 (Conduit) | 6 | **Change 5** |
| `escaped` — §18.6 (`String.join`, a `Js` lambda) | 2 (TodoMVC) | 3 | **Change 5** (`String.join`, `Schema.print` only read) |
| `escaped` — a command's capture | 0 | 1 | correct rejection: the program says `List.copy` (§22.4) |
| `platform` | 0 | 8 | correct: programs written with `Browser.program`, which browser-direct does not build |
| `top-level` | 0 | 3 | correct: the program's own `init` returns a top-level list |
| `call` | 0 | 4 | a limit: conservative calls |
| `supply` — a send handed out of sight | 0 | 1 | a limit: `DebouncedSearch` hands its send to a record field |
| `disjoint` | 0 | 1 | a limit: arms joined (`ForForms`) |

**Change 5** would clear 26 lines of the applications (19 `need` with `Expect`'s class, 2 `unknown`, 2 `escaped`;
Conduit and TodoMVC) and 17 of the corpus's TEA targets (7 + 1 `need`, 6 `unknown`, 3 `escaped`). **O6** would
clear the 16 view-event lines where no view message actually carries a model list. **A send whose payload no
arm writes** (§23.12 item 1, T34) — rejected at the send by the owner's rule where the thesis accepts it — is
none of the lines above: every send-site rejection measured is of a payload the checker cannot see owned, not of
one a sender reads after sending. `OwnedSend`'s `reused` is that case, deliberately.

## 5. Behaviour, bytes and speed

**Behaviour.** Every `browser/` and `run/` page prints what it printed; no `.expected` moved. Run hashes were
re-recorded, in their own commit, for the 14 pages whose emitted JavaScript changed (the ones that import `Browser.Navigation`, and the
migrated ones). The new page `browser/tea/NavigateCommands` pins the commands: a push or replace sends nothing of
its own and `onUrlChange` hears it; a cross-origin push, a replace that does not resolve and a `javascript:`
load send their refusal; `back 0` does nothing. `writes/Conduit`'s golden gained the `RouteRefused` keys (exact,
writing nothing) and moved its line numbers; its gate is 96 of 97 keys bounded (98 %), as before.

**Bytes** (`bench/size.mjs`, and the applications built with `--release`, brotli 11):

| Page | Release brotli, 3c → 3d |
|---|---|
| every `bench/size.mjs` program and page but one | unchanged, byte for byte |
| `browser-tea navigation` page | 3 942 → 3 961 (+19) |
| `bench/size-apps/ApiAndRoutes` | 16 657 → 16 668 (+11) |
| table app, browser-tea and browser-direct; TodoMVC's four programs | unchanged (same SHA-256) |
| Conduit (browser-tea) | 31 422 → 31 459 (+37, +0.12 %) |

The growth is the API's: a command that sends a typed refusal where `Cmd.task` over the direct form sent a
`Result`, and the arm for it. It is the cost of rule 9 on a command (`boundary.md` §9.8.17 (b)), measured; it is
not growth the checker causes, which emits nothing.

**Speed.** The table app's release build is byte-identical on both branches, so its operations cannot move; the
create-1 000 operation, timed anyway (the release build in happy-dom in Node, click then a macrotask, ten runs
after two warm-ups, three processes each, interleaved): medians 75.5, 61.8, 68.0 ms on 3c and 73.4, 64.7, 61.0
ms on 3d — within noise.

**The pass** (`--self-profile`'s `ownership` events, best of 7, `taskset -c 7`, two interleaved runs): Conduit
15.4–16.1 → 18.8–19.2 ms on browser-tea, 15.9 → 19.2 ms on browser-direct. A first build that carried the view's
messages round the entry's fixpoint cost 28 ms and changed no verdict; the built rule marks the stored payload
instead (§23.6).

## 6. What the next slice should measure

1. **O6** is now the whole `payload` cause: 16 lines, Conduit's five and TodoMVC's two among them.
2. **The HTTP answer** (§23.12 item 2) is the largest new cause: 26 `need` lines over the corpus and Conduit,
   each a decoded list the checker cannot see is new.
3. **T34's rule** (§23.12 item 1) costs no measured line today.

## 7. How to reproduce

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out/fast
B=./zig-out/fast/bin/beni
$B dump --stage=ownership --platform=browser-direct examples/conduit/src      # and browser-tea
$B dump --stage=ownership --platform=browser-direct bench/ui/apps/beni
$B dump --stage=ownership --platform=browser-direct bench/todomvc/apps/beni/NoRouting.beni
$B dump --stage=ownership --platform=browser-tea platforms/browser
node bench/size.mjs --beni=$B
```

The corpus sweep is §1's, master's binary over master's tree and this branch's over this one.
