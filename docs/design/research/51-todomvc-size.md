# TodoMVC's size against Solid 1, Solid 2, Svelte 5 and Svelte 4

**Status:** research, 2026-10-02. Not normative. Commissioned by the owner's question: *"10kb
looks big for a simple [TodoMVC]. Check it against Solid 1 and Svelte implementations."*
`tests/corpus/browser/tea/TodoMVC.beni`, built `--release --platform=browser-tea`, is 27 779 bytes
raw and **10 053 brotli** in one `_main.mjs`.

**What was built.** A harness next to `bench/size.mjs`: `bench/todomvc/` holds the other
frameworks' TodoMVCs as npm projects with lockfiles (`node_modules` and `out/` git-ignored), four
beni variants, `size.mjs` (builds everything, prints the size table, takes beni's bytes apart and
prices the candidate reductions; about a minute on a fresh checkout, 15 s after) and `parity.mjs`
(drives every built bundle through todomvc.com's features in a happy-dom page and says which work).
Measured on `master` at `f356f23e`, Node 24.19, brotli 11 and gzip −9 of every JavaScript byte the
page loads; CSS is excluded for every subject, and so is todomvc-common's `base.js`, which tastejs's
pages load beside every app. **Nothing here changes the compiler, core or a platform.**

**Read §0, then §5.**

---

## 0. Findings

### 0.1 The answer

| subject | features | raw | gzip −9 | **brotli 11** | ÷ beni |
|---|---|--:|--:|--:|--:|
| **Svelte 4.2.20**, tastejs + persistence | whole spec | 12 306 | 5 096 | **4 565** | 0.43 |
| Svelte 4.2.20, tastejs's, as is | no persistence | 12 183 | 5 044 | 4 524 | |
| **Solid 1.9.15**, solidjs/solid-todomvc as is | whole spec but the filter at start | 16 248 | 6 309 | **5 717** | 0.53 |
| **beni**, with editing (`apps/beni/Full.beni`) | whole spec | 29 901 | 11 937 | **10 696** | 1.00 |
| beni, the corpus page | everything but editing | 27 779 | 11 195 | 10 053 | |
| **Svelte 5.57.1**, tastejs + persistence | whole spec | 41 606 | 16 008 | **14 488** | 1.35 |
| Svelte 5.57.1, tastejs's, as is | no persistence | 41 484 | 15 960 | 14 437 | |
| **Solid 2.0.0-rc.9**, the official Solid 1 app ported | whole spec | 66 033 | 23 810 | **21 517** | 2.01 |

With beni's features exactly (no editing, everything else), the same order: **Svelte 4 4 246,
Solid 1 5 481, beni 10 053, Svelte 5 13 346, Solid 2 21 291** (§2).

**The owner is right against the two compile-time frameworks of the previous generation and wrong
against the current ones.** beni's TodoMVC is 1.9× Solid 1's and 2.3× Svelte 4's, and 0.74× Svelte
5's and 0.50× Solid 2's — both of which moved their reactivity into a larger runtime (Svelte 5's
signals and proxies; Solid 2's scheduler, async and lanes, research 29 §12.1).

### 0.2 Where beni's 10 KB goes

**Three of the ten kilobytes are the address.** The variant that sets the filter with clicks instead
of reading it from the URL (`apps/beni/NoRouting.beni`) is **6 991**, −3 062. `onUrlChange` is a
subscription, a subscription runs as a fiber (`boundary.md` §9.8.5), and that one fiber reaches the
whole fiber kernel (1 948 bytes, leave-one-out), the subscription table — a red-black `Dict` keyed through
a generic structural compare (331, and ≈ 200 of the compare) — the listener pump and its `bracket` (217), the diff in
`Tea` and the full `Url` parse (227). §9.8.11 (b) took commands that cannot wait off fibers;
subscriptions were not, and that is the largest single cause.

**Without persistence and routing the page is Solid 1's size.** `apps/beni/Sandbox.beni` — the same
page as a `Tea.sandbox`, no `Cmd`, no `Sub` — is **5 317**, against Solid 1 at 5 481 *with* both.
What is left is the DOM runtime, `List` and the app's own code, and of those only the app's code is
out of line with Solid's (§4.6).

| part of the release file (split at its module boundaries) | raw | brotli alone | leave-one-out |
|---|--:|--:|--:|
| DOM runtime (`Rt`) | 7 350 | 2 992 | **2 710** |
| fiber kernel (core `Task`) | 6 069 | 2 171 | **1 948** |
| the app (`TodoMVC`) | 4 522 | 1 652 | **1 521** |
| `List` | 3 153 | 1 294 | **1 126** |
| `Hosted`'s JavaScript (generic compare, relays) | 1 148 | 530 | 387 |
| `Dict` (the subscription and command tables) | 1 239 | 423 | 331 |
| `Tea` | 957 | 470 | 312 |
| `Browser` (the hosted program) | 694 | 357 | 268 |
| `Url` | 611 | 338 | 227 |
| `Listen` (the event pump) | 528 | 261 | 217 |
| `String` | 479 | 295 | 190 |
| `Storage` | 395 | 229 | 100 |
| `Browser.Navigation`, `Sub`, `Cmd`, `Html`, `Maybe`, `Basics`, the entry | 634 | — | 278 |
| **the file** | **27 779** | **10 053** | |

Solid 1's bundle, by the same instrument (`bench/ui/anatomy.mjs`'s source-map method): `solid.js`
1 857, `store.js` 1 407, `web.js` 1 245, the app 754. **beni's DOM runtime (2 710) is larger than
Solid's `web.js`, which needs Solid's reactive core beside it (3 102 together); beni's generated
app is twice Solid's.**

Nothing the page should not reach is dev-only: the crash screen is not in the release file (rule
9's development/release split holds), and neither is `Http`, `Time`, `Duration` or any derived `eq`
or `compare` — every `==` here is a `===` on an integer tag, a number or a string.

### 0.3 The reductions, ranked

Expected brotli saving on this page, each priced by building a variant or rewriting the release file
by hand (§5); the savings do not add exactly.

| # | change | saves | kind | runtime cost |
|--:|---|--:|---|---|
| 1 | **A subscription whose body only waits for its event runs without a fiber**: §9.8.11 (b)'s rule for commands, applied to `Sub.listen` — the listener calls the relay directly | **≈ 2 760** | platform (`Tea`, `Listen`, `Hosted`) and a spec amendment to `boundary.md` §9.8.5 | less: no fiber, no park and resume per event |
| 2 | the keyed `For`'s trimmed first pass (`Rt.trimmed`) dropped | 687 | runtime rewrite | **must be timed**: it is a fast path |
| 3 | a `Now` command runs with no scheduler queue when the program runs no fiber | ≈ 380 | platform and core `Task` | none or less |
| 4 | subscription keys compared as strings, not by `Hosted`'s structural compare | 201 | platform | less (subsumed by 1) |
| 5 | `String.join` as `Array.prototype.join` on the list's plain array | 181 | core rewrite | less |
| 6 | reads of fields no allocation site writes folded to `undefined` (the keyed `For` kind's `g`, `z`, `b`, `w`) | 151 | compiler rule (`Spec.zig`) | less |
| 7 | the `Url` fields no code reads not computed (here all but `fragment`) | 146 | compiler rule (whole-program unread fields) | less |
| 8 | a mount that writes its holes through its own patch | 123 | emitter (`dom` lowering) | **must be timed**: a first compare per hole, fields added after the literal |
| 9 | a literal `href` in the template, checked at compile time, not a hole through `safeUrl` | 111 | emitter (`dom` lowering) | less |
| 10 | a `case` whose other arms are constructors nothing builds collapsed to its live arm | 24 | compiler rule (`Opt.zig`) | less |
| 11 | the browser platform's macrotask without Node's `setImmediate` test | 15 | platform | none |
| 12 | `String.startsWith` as the string's own `startsWith` | 8 | core rewrite | less |

**Rows 5–7 and 9–12 together, measured as one rewrite: −863 (10 053 → ≈ 9 190).** With 1 and 3 the
page is ≈ 6 250; with 2 as well, ≈ 5 550 — Solid 1's 5 481. Rows 1 and 3 are design decisions for
the owner (§5.1); 2 and 8 wait on a measurement with `bench/ui`'s harness; the rest are zero-cost by
§1.4 of the `hand-minify` skill.

---

## 1. Method

**Subjects.** Each is a production build with the configuration its project ships, into
`bench/todomvc/out/<subject>/`:

| subject | source | build |
|---|---|---|
| `beni` | `tests/corpus/browser/tea/TodoMVC.beni` | `beni build --platform=browser-tea --release --no-cache` (beni 0.1.0-m1 at `f356f23e`) |
| `beni-full` | `bench/todomvc/apps/beni/Full.beni`: the corpus page plus editing (double-click, `Cmd.afterRender` focus, Enter/blur save, empty deletes, Escape cancels) | the same |
| `solid1-full` | solidjs/solid-todomvc `src/index.tsx` at `f4830237`, byte for byte | its own `rollup.config.js`: `@rollup/plugin-babel` 6.1.0 with `babel-preset-solid` 1.9.15 and `@babel/preset-typescript` 7.29.7, `@rollup/plugin-node-resolve` 15.3.1, `@rollup/plugin-terser` 0.4.4 with terser's defaults, Rollup 4.63.5, one IIFE; `solid-js` 1.9.15 (the repository pins 1.7.1; this is the version `bench/ui` measures) |
| `solid2-full` | the same app ported to Solid 2.0.0-rc.9 by its migration guide: store from `solid-js` with draft setters, the persisting effect split, the listener in `onSettled`, `class` objects, a `ref` for focus, closures for bound events | Vite 8.3.0 (Rolldown 1.2.12) with `@solidjs/vite-plugin` 3.0.0-next.35 and Vite's defaults, its default minifier included (Oxc); `bench/ui`'s pins |
| `svelte5-asis` | tastejs/todomvc `examples/svelte` at `ff43b02e` (Svelte 5, runes), its three stylesheet imports removed | Vite 8.3.0, `@sveltejs/vite-plugin-svelte` 7.3.1, `svelte` 5.57.1, Vite's defaults |
| `svelte4-asis` | the same example at `7c64d8f4`, the last Svelte 4 version | Vite 5.4.21 (esbuild minifier), `@sveltejs/vite-plugin-svelte` 3.1.2, `svelte` 4.2.20 |

There is **no official Solid 2 TodoMVC**: `examples/todos` in Solid's repository is a demo of
optimistic actions against a mock API that fails a third of its writes. Neither tastejs Svelte app
persists to `localStorage` (the tastejs suite lists the modern apps as in-memory), and neither reads
the filter from the address at start; Solid's official app does not read it at start either.
So each framework has three variants where it needs them: **as is**; **full** — the whole
todomvc.com specification, adding to the official source only what it lacks (Svelte: a
`localStorage` load and an `$effect`/`$:` save, and one `handleChange()` call in the router;
Solid 2: the start filter in the store's initial value); and **parity** — full without editing,
which is exactly beni's corpus page. Every variant's diff from its source is a few lines, named
in the file or the build config.

**Sizes.** Every `.js`/`.mjs` file of the subject's output, concatenated in sorted path order
(`bench/ui/sizes.mjs`'s method): raw, gzip −9, brotli 11 with the size hint. Every subject is one
file. A last column puts every file through one terser configuration (`compress: {passes: 2}`,
`mangle: {toplevel: true}`) so the minifiers' differences can be seen apart from the frameworks':
it moves every framework by 4 % or less and beni by 5 % (10 053 → 9 544, §6).

**Parity.** `parity.mjs` loads each bundle into a happy-dom page opened at `#/active`, in a process
of its own, adds two todos, toggles one, follows the hash to each filter, double-clicks a title and
renames it, reads `localStorage`, then toggle-all and clear completed. §3 is its output; it agrees
with the features column above in every cell.

**beni's breakdown** uses three instruments. (1) The **release file split at its module
boundaries**: a `--release` build is one scope-hoisted file in ES module evaluation order
(`backend.md` §9, *One scope-hoisted file*), so each module's statements are one contiguous run;
the boundaries were placed by reading the file at `f356f23e` (`§0.2`'s table; a one-off). (2) A
**proxy** the harness reproduces on any commit: the development build (one `.mjs` per module,
names kept) scope-hoisted by Rollup and minified by terser with source maps, every byte charged to
its module — 30 847 raw and 10 940 brotli against the release file's 27 779 and 10 053, with the
same ranking. (3) **Feature deletions**: release builds of variants of the page with one capability
removed (`NoRouting`, `NoStorage`, `Sandbox`), exact by construction. "Leave-one-out" is the whole
file's brotli minus its brotli without the part: the bytes the rest does not explain.

**Candidates** are text rewrites of the release file (`bench/ui/anatomy.mjs`'s *hand-applied
candidates*), each followed, as is the release file itself, by one pass that only drops top-level
bindings nothing mentions any more (terser with every other transformation off: 10 053 → 10 025
for the file alone), so a rewrite that strands a helper is charged without it.

## 2. The table

`node bench/todomvc/size.mjs`, first section:

| subject | features | raw | gzip −9 | **brotli 11** | each file through terser, brotli |
|---|---|--:|--:|--:|--:|
| beni | no edit | 27 779 | 11 195 | **10 053** | 9 544 |
| beni-full | whole spec | 29 901 | 11 937 | **10 696** | 10 212 |
| solid1-full | official; whole spec but the filter at start | 16 248 | 6 309 | **5 717** | 5 694 |
| solid1-parity | beni's features | 15 592 | 6 070 | **5 481** | 5 500 |
| solid2-full | port of the official; whole spec | 66 033 | 23 810 | **21 517** | 21 330 |
| solid2-parity | beni's features | 65 328 | 23 562 | **21 291** | 21 110 |
| svelte5-asis | official; no persistence, no filter at start | 41 484 | 15 960 | **14 437** | 14 008 |
| svelte5-full | whole spec | 41 606 | 16 008 | **14 488** | 14 055 |
| svelte5-parity | beni's features | 37 859 | 14 751 | **13 346** | 13 048 |
| svelte4-asis | official; no persistence, no filter at start | 12 183 | 5 044 | **4 524** | 4 344 |
| svelte4-full | whole spec | 12 306 | 5 096 | **4 565** | 4 401 |
| svelte4-parity | beni's features | 11 295 | 4 730 | **4 246** | 4 090 |

**Editing costs every framework about the same**: beni +643, Solid 1 +236, Solid 2 +226, Svelte 5
+1 142 (an `{#if}` block and `tick`), Svelte 4 +319. Persistence and the start filter together cost the
Svelte apps 41–51 bytes (`JSON`, one effect, one call); in beni it is 769 (`NoStorage`), because a `Cmd.do` reaches the scheduler's
queue (§4.1) and `Storage` wraps each documented failure by name (rule 9) — Svelte's and Solid's
calls catch nothing.

For scale, from `bench/size.mjs --pages-only` on the same commit: the empty mounted page is 446
brotli, an empty `Tea.element` 1 199, and a page whose only effect is `onUrlChange` (`browser-tea
navigation`) 5 841 — the one of them that reaches `Task`. A day earlier, at `8ddc9c2c` (keyed rows restored),
this page was 9 796; `boundary.md` §9.8.10's "TodoMVC is 8 120" was the first version, with
positional rows and no toggle-all or destroy, and is not comparable.

## 3. Feature parity

`node bench/todomvc/parity.mjs` (after `size.mjs`):

| subject | add | counter | toggle | filter by hash | filter at start | edit | toggle all | clear completed | persistence |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| beni | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| beni-full | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| beni-norouting | yes | yes | yes | **no** | **no** | **no** | yes | yes | yes |
| beni-nostorage | yes | yes | yes | yes | yes | **no** | yes | yes | **no** |
| beni-sandbox | yes | yes | yes | **no** | **no** | **no** | yes | yes | **no** |
| solid1-full | yes | yes | yes | yes | **no** | yes | yes | yes | yes |
| solid1-parity | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| solid2-full | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| solid2-parity | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| svelte4-asis | yes | yes | yes | yes | **no** | yes | yes | yes | **no** |
| svelte4-full | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| svelte4-parity | yes | yes | yes | yes | yes | **no** | yes | yes | yes |
| svelte5-asis | yes | yes | yes | yes | **no** | yes | yes | yes | **no** |
| svelte5-full | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| svelte5-parity | yes | yes | yes | yes | yes | **no** | yes | yes | yes |

Differences the table does not show, none of them worth more than a few bytes: Solid's app adds new
todos at the top and removes `.main` and `.footer` when the list is empty (so do both Svelte 4
variants), where beni and Svelte 5 hide them; Svelte 4's as-is app does not trim a new title; beni
stores its list as one line per todo, the others as JSON; Solid's and Svelte's ids are a counter and
`crypto.randomUUID()`.

## 4. What beni's page reaches, and why

### 4.1 The fiber kernel, for one subscription and one storage write

Core's `Task` is 6 069 bytes raw in the release file: the scheduler's ready queue and its 64-step
drain, the macrotask, fibers with stacks, interruption and masks, scopes and their children,
observers for `join`, finalisers and `bracket`, and the shutdown with its deadline. It is reached
through `Tea`:

- **The subscription.** `Tea.arrive` spawns `Hosted.run relay` into the program's scope with
  `Task.spawnIn` for each new subscription key; `Hosted.run` runs `eachUrlChange`, which is
  `Listen.eachOf2`: a `Task.bracket` that adds the `popstate` and `beni:navigate` listeners and a
  loop that parks the fiber with `Task.callback` until the next event. Leaving the set cancels the
  fiber, and that reaches interruption, masks, finalisers and the cleanup walk.
- **The storage write.** `Cmd.do` builds a `Now` job (§9.8.11 (b)): no fiber, but it is queued with
  `Task.soon` in the fiber scheduler's queue so it runs where a fiber would have started. That
  alone is **380 bytes** — the part of `Task` the `NoRouting` variant still ships.

`NoRouting` drops 3 062 bytes in all: 1 568 of `Task`, the `Dict` and the generic compare, `Listen`,
the relay functions, the diff, `Url` and `Browser.Navigation`. A routing that is a plain listener
calling the program's `send` (§5, row 1's rewrite) costs ≈ 300 of those back.

### 4.2 The subscription table

`Tea`'s state keeps live subscriptions in a `Dict Key (Live msg)` and recomputes the set on every
render: `Tea.diff` builds a `Dict` of the declared keys, folds the live one into kept and gone, and
spawns the arrivals. `Dict` is the red-black tree (1 239 raw: `insert`, `balance`, `get`,
`foldl`), and `Hosted.Key` compares through `Hosted`'s structural compare — a `typeof` rank, a
`$plain` unwrap and a recursive walk of sorted `Object.keys` — although the only key this page
declares is the string `"UrlChange"`. For a program whose `subscriptions` returns the same set
every time, all of it runs once per render and finds nothing to do.

### 4.3 `Url`, parsed whole for its fragment

`Browser.Navigation.currentUrl` and every change of the address build a whole `Url` record: the
protocol, host, port (through `String.toInt`), path, query and fragment. The page reads only
`fragment`. Release field elimination (`backend.md` §9, item 4's allocation-site analysis) drops
fields nothing reads only inside one allocation site's reach; here the record is built in core and
read in the app, and every field survives (146 bytes).

### 4.4 `List`

1 126 bytes, leave-one-out. Two thirds of it is the decided representation (the owner, 2026-10-01:
one array-backed sequence with a 32-way trie): `model.todos ++ [ new ]` reaches `List.append`,
whose path for long lists builds the trie, so the trie's builders are in the page although no list
here reaches 32 (395 bytes; information, not a candidate). The rest is `map`, `filter`,
`indexedMap`, `isEmpty`, `length` and the views. **`String.join` is the one avoidable piece**: it
is written as a fold over `head` and `tail`, which reaches the trie's `pop` and the view's
`$plain`, where `Array.prototype.join` on the list's plain array is shorter and faster (181).
`String.startsWith` is written as `left (length prefix) == prefix` over code-point arrays, where the
string's own `startsWith` gives the same answer for any well-formed string (8).

### 4.5 The DOM runtime

`Rt` is the keyed `For` (the reconcile Solid also ships, plus beni's own two passes), the slots,
templates, delegated events and the render loop: 2 710 bytes, close to Solid's `web.js` and the part
of `solid.js` a page uses. Three things in it this page does not need:

- **`Rt.trimmed`**, a first pass of the keyed `For` that matches a common prefix, suffix and swap
  before the general pass: 687 bytes. It is a speed path; whether it pays for itself is a question
  for `bench/ui`'s js-framework-benchmark operations, not for this report.
- **Fields of the `For` kind no kind writes.** The row kind the page passes is `{m, p, i, f}`; the
  runtime reads `g` (inputs), `z` (an identity), `b` (a block) and `w`, which are `undefined` for
  every kind this program builds, so `sameInputs`, its twin and the input re-patch loop are dead,
  and Spec's constant folding leaves `if (a === null || true || a.length !== null.length)` behind in
  them, with the loop that re-patches the rows of a changed identity (151 bytes).
- **Constant `href`s as holes.** `<a href="#/">` is lowered as a hole whose value is the literal and
  written through `safeUrl`'s regular expression on mount, so the regex ships for three constants
  that could have been checked at compile time and written into the template, as every other static
  attribute is (111 bytes).

### 4.6 The app's own code

1 521 bytes against Solid's 754 for the same component. Most of it is the shape of a compiled kind:
the mount (`m`) writes every hole and the patch (`p`) compares and writes every hole again, the
instance record stores a copy of every hole value beside its node, and each row re-creates its
message closures on every patch. Writing the mount through the patch saves 123 on the page kind
alone (row 8), but adds a compare per hole at mount and fields after the literal, so it is timed
before it is taken. Research 41 §5.2 has the rest of this; it is not re-measured here.

## 5. The reductions

`node bench/todomvc/size.mjs`, last section; "Δ" is against the release file after the same
unmentioned-binding pass (10 025):

| candidate | Δ raw | Δ brotli |
|---|--:|--:|
| constant `href`s in the template, not holes through `safeUrl` | −239 | −111 |
| reads of `For` kind fields no kind writes (`g`, `z`, `b`, `w`) folded | −683 | −151 |
| a `case` on `Cmd` items collapsed to the one constructor built | −112 | −24 |
| `String.join` as the array's `join` | −506 | −181 |
| `String.startsWith` as the string's `startsWith` | −29 | −8 |
| the `Url` fields the program never reads not built | −307 | −146 |
| the browser's macrotask without Node's `setImmediate` test | −77 | −15 |
| subscription keys compared as strings, not by the generic structural compare | −579 | −201 |
| the page kind's mount writing its holes through its own patch (time it) | −477 | −123 |
| the keyed `For`'s trimmed first pass gone (time it) | −1 741 | −687 |
| routing as a plain `popstate` listener: no subscription fiber, table or relay (an estimate) | −8 486 | −2 761 |
| *information:* `++` on lists without the 32-way trie (the decided representation) | −1 004 | −395 |
| **every zero-cost rewrite above together** | −2 532 | **−863** |

### 5.1 The two design changes

**Row 1: listener subscriptions without fibers.** §9.8.11 (b) made the choice for commands: a body
that cannot suspend runs with no fiber, decided per use from the inferred bit. A subscription's
body today is a direct form that never returns (`eachUrlChange`, `eachKeyDown`, …: `suspends`,
because it parks between events), so every subscription takes the fiber path. The proposal is the
same split for `Sub.listen`: a subscription built over a **listener primitive** — add a listener,
call the relay's `send` from it, remove it when the key leaves — is a `Now`-style subscription
that the diff starts and stops directly, with no fiber, no `bracket` and no park per event; a body
that really waits (a timer loop, a request) keeps its fiber. The `each…` direct forms stay what
they are for code that wants them in a fiber. What it buys here: the page's routing for ≈ 300 bytes
instead of ≈ 3 060, and no fiber kernel at all unless something waits. It needs an amendment to
`boundary.md` §9.8.5 (*one fiber runs `body`*) and §9.8.11, so it is the owner's (rule 1). Row 4
(string keys) is part of it: the subscription table can be a `Map` from the key's string when keys
are strings, which `Sub.listen`'s `k.compare` does not require today.

**Row 3: `Now` jobs without the queue.** A `Now` body runs "exactly where its fiber would have
started" (§9.8.11 (b)), which is what lets commands that wait and commands that do not keep one
order. In a program that can never spawn a fiber there is no other order to keep, and that place is
"after the update returns and the render it queued", which the host can schedule with one
microtask of its own instead of `Task`'s queue, drain budget and macrotask. Whether a program can
spawn a fiber is the static whole-program question §9.8.11 already asks per use
(`Js.maySuspend`), one level up; reachability (`backend.md` §9) already knows whether anything
that spawns a fiber is reached. Together with row 1,
the page ships no `Task`.

### 5.2 Where each zero-cost row lives

- **Compiler rules**: row 6 (`Spec.zig`: a field no allocation site of the type writes reads as
  `undefined`, after which the existing constant folding removes `sameInputs` and the `||true`
  remnants), row 7 (whole-program unread record fields, across modules), row 10 (`Opt.zig`: a
  `switch` whose arms but one return `undefined` for constructors nothing builds).
- **Emitter** (`platforms/browser/zig/dom.zig`): row 9, a literal URL attribute checked by the
  compiler and written into the template; row 8 after timing.
- **Core** (`String.beni`): rows 5 and 12, each a property access on the host string or array —
  inside the `Js` wall, as `String` already is.
- **Platform**: rows 1, 3, 4 and 11 (the browser platform owns its macrotask; `Task`'s
  `setImmediate` test is for Node).

## 6. What this report did not do

- **No reduction is implemented.** The rewrites are measurements of the bytes, not programs, and
  none was run; rows 2 and 8 have no speed figure, and both must have one from `bench/ui`'s
  harness before they are taken (the `hand-minify` skill's §1.4).
- **The terser column says the release optimiser leaves about 500 bytes** a general minifier finds
  (10 053 → 9 544): the `||true` remnants, the dead `switch` arms and the duplicated reads in row
  kinds are some of it. It was not taken apart further.
- **Solid 2 was measured at 2.0.0-rc.9**, `bench/ui`'s pin and `references/solid`'s; npm's `next`
  is rc.13. Its size is research 29 §12.1's 22 kB floor and is not expected to move by much.
- **The module split of §0.2 was placed by hand** on this commit's file; the harness reproduces the
  picture through its proxy and the feature variants, which do not need the boundaries.

## 7. Reproduce

```sh
zig build                              # zig-out/bin/beni
node bench/todomvc/size.mjs            # builds every subject (npm ci the first time), all tables
node bench/todomvc/size.mjs --no-build # measure what bench/todomvc/out/ holds
node bench/todomvc/size.mjs --json     # one JSON line per row
node bench/todomvc/parity.mjs          # §3, after size.mjs
```

## 8. What was taken (added 2026-10-02)

The owner approved row 1 and the zero-cost rows; row 2 was declined. Each row taken is its own
commit, priced after brotli across `bench/size.mjs` and every `browser/` corpus page, and kept only
when smaller overall. `node bench/todomvc/size.mjs` afterwards, on `master` plus those commits:

| subject | brotli 11 |
|---|--:|
| **beni** (the corpus page) | **7 894** (9 722 on `master` before them; 10 053 when this report was written) |
| beni-full | 8 529 (10 369) |
| Svelte 4 (full / parity) | 4 565 / 4 246 |
| Solid 1 (full / parity) | 5 717 / 5 481 |
| Svelte 5 (full / parity) | 14 488 / 13 346 |
| Solid 2 (full / parity) | 21 517 / 21 291 |

| row | taken | where | TodoMVC |
|--:|---|---|--:|
| 1 | yes: `Sub.on`, listener subscriptions with no fiber (`boundary.md` §9.8.5's amendment) | `browser`, `browser-tea`, `core/Task.onShutdown` | −1 579 |
| 5 | yes: `String.join` is the array's `join` (−32 648 across `bench/size.mjs`) | `core/String` | −178 |
| 12 | yes: `startsWith`/`endsWith` are the string's own | `core/String` | −54 |
| 9 | yes: a literal URL attribute checked by the lowering and baked into the template | `dom.zig` | −74 |
| 10 | yes: a `case` arm no value takes is left out of the decision tree | `Lower.zig` | −35 |
| 4 | gone already: keys carry their type's identity and compare by its own `compare` | — | — |
| 8 | no: a block's kind mounting through its patch, under the rows' conditions, grew 49 of 86 pages (+294 in all; TodoMVC +23); the page kind's own form needs class lists, stateful properties and slots written through the patch, and a `bench/ui` timing | — | — |
| 6 | no: the `For` kind's fields do not fold because fact 3 loses the markup values — the slot's instance is ⊤, so every values array and row kind escapes; index-precise array reads alone do not reach it | `Spec.zig` | — |
| 7 | no: the `Url` escapes into `Hosted.js`'s relay at a type variable, which may walk it; its unread fields could go only if the relay were beni and fact 3 read a program array's `push` | — | — |
| 3, 11 | not attempted: 3 is a design decision the owner has not taken; 11 needs a platform hook whose bytes eat its 15 | — | — |
