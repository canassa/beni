# The browser runtime, moved to beni one piece at a time

*Started 2026-10-02.* The owner's decisions R47-1..3 (`plans/browser-decisions.md`, *The runtime in
beni*): the DOM runtime (`platforms/browser/runtime.js`) is rewritten in beni now, gradually, and
**each step lands only if, for the piece it moves, the generated JavaScript is no larger** (release
brotli: the empty page, the `bench/ui` app, and a page that uses the piece), **no slower** (`bench/ui`
per-operation script medians against the hand-written build and Solid 1, in one batch) **and
equivalent in shape** (a side-by-side listing in the step's report). A piece that cannot meet the
bar stays hand-written until the compiler feature it needs lands, and the step builds that feature
first. The mechanism is `boundary.md` §9.2's runtime module (`"markup": { …, "module": "Rt" }`) and
`backend.md` §15.1: the module's `pub` values stand in for runtime exports of their names, the file
imports the rest from `beni:Rt`, and both are compiled with the program, so `--release` specialises
the runtime to the page (§9, *Whole-program specialisation*).

## The steps

| # | Piece | State |
|---|---|---|
| 1 | **Slot and mount**: an instance's nodes (`first`, `last`, `put`, `drop`, `swap`), `template`, `slot`, `parentOf`, `unit`, `patch`, `place`, `childHtml`, the render queue, `flush`, `run` and the mount | **landed 2026-10-02**, below |
| 2 | **Templates and holes**: `childMaybe`, `childList`, `insertText`, `attr`, `attrNS`, `rawHtml`, `safeUrl`, the text and map kinds (`text`, `map`) | open |
| 3 | **Render loop, events and host**: `fire`, `delegated`, `delegate`, `start`, `listen`, `identity`; `Browser.program`/`hosted` and the hosted loop of `Browser.js` | open — `Browser.program` needs the two features below |
| 4 | **Keyed lists**: `forKeyed`, `forPosition`, `trimmed`, `reconcile`, `park`, `mountRow`, `patchRow`, `show`, `hide`, `fallback` | open |
| 5 | **Class and style helpers**: `classes`, `styles`, `classSet`, `styleMap` | open |

## Step 1 — slot and mount (2026-10-02)

**What moved.** `platforms/browser/Rt.beni` (the port research 47 made in
`tests/platforms/beni-runtime`, now the real platform's; the test platform, its `-tea` twin and
`browser/split/`'s two duplicate pages are gone, and `emit/release/split/EmptyPage` is built for
`browser`). `runtime.js` lost those functions and imports them. The lowering is unchanged.

**What changed besides.** A `--library` build roots the module's `run`, `start` and `flush`, since
the page's own entry calls them (`backend.md` §15.1); `bench/ui`'s micro page and `browser_test`'s
library page read them from `_platform/_browser/Rt.mjs`. `Minify`'s test that every shipped file
scope-hoists reads the manifest's `"module"`; the oracle extractor accepts `Rt$template`.

**Sizes** (release, brotli, the whole bundle; `bench/size.mjs`'s pages plus the `bench/ui` app and
four `browser/dom/` pages; `--allow-debug` where a page logs):

| page | hand-written | beni | |
|---|--:|--:|--:|
| empty `browser` | 978 | **838** | −140 |
| empty `Tea.sandbox` | 986 | **844** | −142 |
| empty `Tea.element` | 1 724 | **1 601** | −123 |
| `Tea.element` with effects | 5 968 | **5 832** | −136 |
| `bench/ui` app | 6 139 | **6 084** | −55 |
| `dom/Keyed` | 5 322 | 5 227 | −95 |
| `dom/KeyedMoves` | 5 025 | 4 944 | −81 |
| `dom/RenderLoop` | 3 822 | 3 743 | −79 |
| `dom/ShowAndBranches` | 2 091 | 1 993 | −98 |
| `dom/Events` | 5 007 | 4 918 | −89 |
| `tea/AfterRenderFocus` | 4 390 | 4 285 | −105 |

Development builds fall 125–190 brotli bytes each (the module is written as a module of its own and
only what is reached).

**Speed.** `bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, n = 8, 1-minute load 0.9–2.8,
release builds of the same app with the compiler before and after, and Solid 1, one batch per
group; script median ms:

| | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| hand-written | 4.96 | 10.7 | 1.45 | 1.38 | 1.14 | 0.51 | 54.4 | 5.34 | 21.9 |
| beni | 4.97 | 10.7 | 1.65 | 1.23 | 1.00 | 0.50 | 53.3 | 5.32 | 22.1 |
| Solid 1 | 4.92 | 11.7 | 1.50 | 1.53 | 1.54 | 0.56 | 56.8 | 5.25 | 22.8 |

`update10th` and `select`, re-run at n = 16 (load 0.8): hand-written 1.65 / 1.20, beni 1.33 /
1.38, Solid 1 1.85 / 1.50 — each flips between the two runs, so both are noise. No operation is
slower.

**Shape.** Every function is the hand-written one; on the `bench/ui` app `template` is specialised
to the one flag value the app passes (`e=(a)=>{let b=null;return()=>{…b=d.content;b=b.firstChild}
return b.cloneNode(true)}}` against the hand-written three flag tests), and a slot on the empty page
has no list fields. `emit/release/split/EmptyPage` is the listing.

**What is still paid, and why `Browser.program` stayed.** A plain page keeps the hosted branch of
`run` and the after-render phase (`backend.md` §15.11: 26 bytes). Writing `Browser.program` in beni
would let fact 3 fold `m.h === undefined` and drop both — measured by hand on the empty page,
**838 → 816** — but it needs two things the compiler lacks:

1. **`sync` on an ordinary declaration's signature.** `program`'s signature demands that `update`
   and `view` do not suspend; only a `foreign` signature may write `sync` (`language.md` §5.4,
   `misplaced_sync`), and without it a program whose `update` suspends would build and misbehave.
   A language change, so the owner's.
2. **The entry file's `run(main)` seen as a call.** `Emit` lists `run` and `main` as escaping
   (`Spec.Input.escaping`), so `main`'s mount object escapes and its `h` never folds, even with
   `program` in beni (tried: the branch stays). The entry is the compiler's own output; the pass
   could model it as one call of `run` with `main`.

Both belong to step 3.
