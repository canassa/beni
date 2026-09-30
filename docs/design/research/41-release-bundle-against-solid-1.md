# The benchmark app's release bundle against Solid 1, byte by byte

**Commissioned by** the owner's rule for the UI — match or beat Solid, and where beni does not,
find out what Solid does differently — applied to size. Research 39 §11.6 measured the
js-framework-benchmark app at **6 195** brotli bytes under `--release` against Solid 1.9.15's
**4 356**, 1.42×. This report takes both bundles apart, ranks the causes by bytes, builds the
contained fixes, and specifies the rest.

**What this is.** Measurements on `master` at `2c2dc17c` and after this report's commits, Node
24.19, brotli 11, of every JavaScript file the page loads, concatenated (research 29 §12.1's method,
`bench/ui/sizes.mjs`), and the new instrument `bench/ui/anatomy.mjs`. Five changes to `src/`, each
red first and in the gates, and the amendments they needed in `backend.md` §4, §5 and §9.
**What this is not.** A change to `platforms/browser/runtime.js` or `zig/dom.zig`, which another
agent owns: two findings are theirs to act on (§5.2, §5.4). Research 40 (the adaptive `Array`
sibling under brotli) specified the compactor passes A2 and A3; they are built here and measured on
this app, and its rules are not repeated.

**Read §0, then §5.**

---

## 0. Findings

### 0.1 The answer

| | files | raw | **brotli 11** | ÷ Solid 1 |
|---|--:|--:|--:|--:|
| beni `--release`, before (`2c2dc17c`) | 12 | 18 810 | **6 195** | 1.42 |
| … `==` in place keeps no `eq` alive (§3.1) | 12 | 17 756 | ≈ 5 856 | |
| … and exports cut, one entry `import` (§3.2) | 11 | 17 691 | **5 828** | 1.34 |
| … and renaming and rewriting hand-written JavaScript (§3.4) | 11 | 15 372 | **5 467** | **1.26** |
| Solid 1.9.15 (js-framework-benchmark's Rollup build) | 1 | 11 513 | **4 356** | 1.00 |
| beni after, as one scope-hoisted file (§5.1, not built) | 1 | 14 585 | 5 164 | 1.19 |
| beni after, scope-hoisted and through terser (a bound) | 1 | 12 636 | 4 675 | 1.07 |

**−728 bytes, 11.8 %**, and the ratio to Solid 1 from 1.42 to 1.26. The empty mounted page fell
1 393 → **1 296** (`browser`) and 1 420 → **1 320** (`browser-tea`), the Node floor 304 → **279**,
and the release builds of all 229 corpus programs, summed, 226 559 → **216 198** (−4.6 %).

**Minified alike, beni's runtime is smaller than Solid's library and its generated code is three
times Solid's.** Each through terser on its own: the browser runtime is **2 644** brotli against
Solid 1's two library files at **3 583**; everything else beni ships — `Main.mjs`, core, the small
siblings — is **2 665** against Solid's compiled `main.jsx` at **883**. The gap that is left is
delivery (twelve ES modules, §5.1) and the shape of the generated view (§5.2), not the runtime.

### 0.2 Ranked causes, before and after

Brotli bytes each is worth on the app, leave-one-out or hand-applied (§1). "After" is on the
bundle this report ships.

| # | cause | before | after | status |
|--:|---|--:|--:|---|
| 1 | twelve ES modules, not one scope-hoisted file | 773 | **303** | proposal, §5.1 |
| 2 | hand-written JavaScript's locals not renamed | 452 | 88 | **built** (A2), §3.4 |
| 3 | derived `Maybe.eq` and `_derived.mjs` shipped for an `==` tested in place | 339 | 0 | **built**, §3.1 |
| 4 | a helper's constant arguments memoised and re-checked by the parent block | 192 | 192 | proposal, §5.2 (the `dom` lowering) |
| 5 | the runtime's `map` export kept alive by a local named `map` | 116 | 40 | finding for the runtime, §5.4 |
| 6 | constructor tags as strings | 71 | 44 | proposal, §5.3 (with §9 item 4) |
| 7 | export lists naming what no file imports | 65 | 0 | **built**, §3.2 |
| 8 | the entry file's two `import`s of one runtime | 55 | 0 | **built**, §3.2 |
| 9 | `;` before `}`, `(x) =>`, `const` (A3) | 32 | 0 | **built**, §3.4 |
| — | the word lists as nested cons literals | 31 | 5 | not a cause: Solid ships the same words |
| — | one shared empty list | 9 | — | not a cause |

---

## 1. Method

`bench/ui/build.mjs` builds the app (`bench/ui/apps/beni/Main.beni`, `--platform=browser-tea
--release`) and Solid 1 exactly as js-framework-benchmark's keyed `solid` entry does (Rollup,
`babel-preset-solid` with `omitNestedClosingTags`, `@rollup/plugin-node-resolve`, terser with three
passes, one IIFE). `bench/ui/anatomy.mjs` then prints four tables:

- **Leave-one-out.** A file's or a part's cost is the bundle's brotli minus the bundle's brotli
  without it: the bytes the rest of the bundle does not already explain. Parts do not sum to the
  whole; "brotli alone" is the other bound.
- **Hand-applied candidates.** A text rewrite of the built tree that prices a fix before it is built
  (backend.md §9's discipline): one scope-hoisted file (Rollup over the release tree), terser, the
  runtime's locals renamed, integer tags, the `map` export gone, the word lists as arrays.
- **Minified alike.** Each beni file through terser on its own, the runtime and the rest apart.
- **Solid 1 by source.** Its bundle rebuilt through its own config with a source map, and every
  minified byte charged to the module the map names.

The before column of §0.2 and §2.1 is the same script on `2c2dc17c`'s build.

---

## 2. The two bundles taken apart

### 2.1 beni, before

| file | raw | brotli alone | leave-one-out |
|---|--:|--:|--:|
| `_platform/_browser/runtime.foreign.mjs` | 9 775 | 3 140 | 3 078 |
| `Main.mjs` | 6 087 | 2 145 | 2 014 |
| `_core/List.mjs` | 943 | 430 | 338 |
| `_core/_derived.mjs` | 871 | 365 | 294 |
| `_core/Maybe.mjs` | 256 | 173 | 140 |
| `_core/Basics.foreign.mjs` | 341 | 196 | 117 |
| `_main.mjs` | 186 | 116 | 72 |
| the other five | 340 | 304 | 201 |

By kind of text: the 20 `import`/`export` statements are 794 raw and **270** leave-one-out; the
three templates 620 / 203; the three word lists, written as nested cons literals, 963 / 246; the
fourteen `$:"Tag"` strings 148 / 75. `Main.mjs` by declaration, leave-one-out: the container's
kind `A` (the jumbotron and six `button` calls) **428**, `view` 376, `update` 155, the button's kind
138, `buildFrom` 137, the word lists 267, the templates 205.

Two of these were surprises and are §3's first two fixes: `_derived.mjs` and `Maybe.mjs`'s
derived `eq` were never called — `rowClass`'s `model.selected == Just row.id` is written as a tag and
field test in place (backend.md §4) — and `List.mjs` exported five functions no other file imports.

### 2.2 Solid 1

| source | minified raw | brotli alone |
|---|--:|--:|
| `solid-js/dist/solid.js` (signals, `createSelector`, `mapArray`) | 5 288 | 2 006 |
| `solid-js/web/dist/web.js` (`template`, `insert`, `reconcileArrays`, delegation) | 4 413 | 1 699 |
| **the library, both** | 9 701 | **3 583** |
| `src/main.jsx` (the app: templates, word arrays, `buildData`, handlers) | 1 831 | 883 |

How the build gets there, in the order the bytes go:

1. **One file, scope-hoisted.** Rollup concatenates every module into one IIFE and renames what
   collides; there is no `import`, no `export` and no module specifier in the output. That is the
   largest single difference (§0.2 row 1).
2. **terser, three passes, locals and top-level names mangled.** Properties are not mangled
   (`$$click`, `observers`, `.data` all survive): neither side renames properties.
3. **babel-preset-solid compiles the view.** Each JSX root is one `template()` call, cloned; static
   attributes live in the template string (`omitNestedClosingTags` drops closing tags); a dynamic
   attribute is an `effect` closure comparing to the last value; `onClick` is `$$click` on the node
   with one `delegateEvents(["click"])` at the end. beni's `dom` lowering does the same thing with
   the same string shapes — the three template strings are within a few bytes of Solid's.
4. **The app is small because the runtime does the work.** `Button` is a component called six times
   with its three values; the parent does not remember them, because nothing reactive reads them.
   The rows are `mapArray` over a plain array; the model is signals, so `update` has no list code.

### 2.3 What minification alike says

Through terser file by file, beni's eleven release files (after §3) are 5 172 brotli (14 171 raw)
against Solid's 4 354. The runtime alone is **2 644 against Solid's library's 3 583** — smaller, by 26 %. So the
difference is entirely delivery (module boundaries) and the generated code: beni's generated and
core code is **2 665** against Solid's app at **883**. Of that, `List` and `Basics` are about 400
(Solid's app uses JavaScript arrays and operators), the model's `update` and generator are about
300 (Solid's handlers and `buildData` are inside its 883), the container block with six inlined buttons is 428
(§5.2), and the rest — templates, word lists, row kind — is the same text Solid ships.

---

## 3. What was built

Each is red first and in the gates; a development build did not change except by §3.1, which is a
reachability fix and applies to both builds.

### 3.1 An `==` tested in place keeps no derived `eq` alive (−339)

`backend.md` §4 writes `x == Just y` as `x.$ === "Just" && x.a === y`, calling nothing. §9's
reachability walk ran before lowering and followed every dispatch site's callee, so `Maybe`'s
derived `eq` — and through it `_core/_derived.mjs`, the comparison engine — shipped uncalled.
`src/js/CtorEq.zig` is now the one decision both passes ask: `Lower.ctorEquality` to decide what to
write, `Reach` (through a site filter on `Edges.declEdgesExcept`) to decide the edge. One function,
because a disagreement is dead code shipped or, the other way, a `ReferenceError` at load.
Fixture: `emit/app/DceEqAgainstConstructor` (no `Shape$$eq`; `_expected.absent` names
`_core/_derived.mjs`). **Development output changes too**: the same dead code left every dev build
of a program that compares against a constructor; `bench/size.mjs`'s dev gross fell 1 099 945 →
1 096 406. backend.md §4 and §9 amended.

### 3.2 Release exports cut to what is imported, and one entry `import` (−65, −55)

§5 had ruled out consumer-driven export lists as "a determinism hazard for nothing". Under
`--release` the hazard is already paid — every module's bytes depend on the whole-program name
table — so an application's export lists are cut to the names some file imports
(`Emit.markImported`, serial, after `numberGlobals`); `--library` keeps every export. The entry
file names `run` and `start` in one `import` when one file exports both (both browser platforms);
`tests/browser/driver.mjs` reads the runtime's path from either form. Tests: `build_test`'s *a
release application exports only what another file imports; --library keeps every export*, and
`external_platform_test`'s release entry file. backend.md §5 amended.

### 3.3 A sibling's `function f(a, b)` parameters are bindings

Research 40 §0.5's defect: `Sibling.zig`'s check 3 took `function` through its declarator branch
before the parameter-list branch, so a parameter named nowhere else was refused as an unbound
reference. The branch order is fixed and the function's name is bound too. Fixture
`run/SiblingFunctionParams` (its platform's `function repeat(piece, count)`; red was
`UNBOUND JAVASCRIPT REFERENCE … uses 'count'`), which the release pass also runs renamed:
`function d(e,f){let a="";for(let b=0;b<f;b+=1)a+=e;return a}`.

### 3.4 Renaming and rewriting hand-written JavaScript (A2, A3)

Research 40 §7's A2 and A3 in `src/js/Minify.zig`, under `--release`, after elimination; the rules
are in backend.md §9's amendment, *Hand-written JavaScript under `--release`*. Two decisions the
report left open, taken here:

- **Which globals may never be renamed.** `Sibling.isStandardGlobal`'s list plus the hosts'
  (`document`, `window`, `process`, `parent`, `name`, …). Check 3 cannot see a free read of a global
  when the same name is bound somewhere else in the file, and a renaming would break exactly that
  read; the list is what makes the injective-renaming argument hold for the names a runtime really
  reads. The browser runtime binds a local `parent` and a local `document`; both keep their names.
- **`const` → `let` is all or none per file.** Per declaration is sound (an assignment to a binding
  is an assignment to its name, and a declaration none of whose names is ever assigned cannot
  throw), and it was built first — and it **cost 9 bytes** on the browser runtime, which it
  converted all but twenty `const`s of: a file mixing both keywords compresses worse than one with
  either.
  Whole-file, it converts the small siblings and leaves the runtime (whose `let i`, assigned in
  `forKeyed`, keeps `unit`'s `const i`) as written.

| pass (on top of §3.1–3.2) | app brotli | Δ |
|---|--:|--:|
| neither | 5 828 | |
| A3 alone | 5 796 | −32 |
| A2 alone | 5 473 | −355 |
| **both** | **5 467** | **−361** |

On the runtime file alone, A2 takes 3 140 → 2 839 (alone) against terser's 2 644; what is left is
terser's `compress` (−88 on the app, row 2 of §0.2) and the one-letter names A2 must keep because
they are also object keys (`i`, `s`, `t`, `m`, `p`, `x`, `y`) — they are already one letter.

---

## 4. Re-measured

`bench/size.mjs`, raw / brotli, release:

| | before | after |
|---|--:|--:|
| floor (`Empty`, Node) | 621 / 304 | **525 / 279** |
| empty page, `browser` | 3 965 / 1 393 | **3 267 / 1 296** |
| empty page, `browser-tea` | 4 068 / 1 420 | **3 361 / 1 320** |
| 229 programs' release builds, summed | 741 479 / 226 559 | **695 871 / 216 198** |

(Two `run/` fixtures, `UndeterminedCompareSlot` and `WideTypeArityEq`, are multi-module and
`size.mjs` builds them as one file, so they fail to build before and after; the totals are over the
same set both times.)

---

## 5. What is left, specified

### 5.1 A release build as one scope-hoisted file (303 now; 792 with a minifier's compress)

**What Solid does**: Rollup. **What beni would do**: under `--release` of an application, write the
whole program into the entry file — every module's surviving declarations in dependency order, the
hand-written files inlined — and nothing else. It is backend.md §5's own sentence, "with one entry
point and no `lazy`, that is one file", reached before §10's chunking rather than through it.

Why it is mostly mechanical in beni and not in general:

- **Generated names already cannot collide.** §9 item 2 gives every top-level name of the build one
  whole-program namespace; the `import`/`export` pairs between generated modules simply disappear.
- **Module evaluation order is a topological order of the module graph**, which is a DAG and
  already checked in dependency order (M2's DAG-parallel checking), and §9's *Purity* paragraph
  proves no top-level initialiser is observable, so any topological order is as good as ES module
  evaluation's.
- **The hand-written files are the work.** Their top-level names are their own and can collide with
  the generated alphabet. Two sound options, neither a parser: (a) A2's renaming extended to
  top-level names, with the export names mapped to the generated names the importers use — the
  compactor already knows every top-level binding and export (`Minify.shake`'s units); or (b) wrap
  each file in a function scope returning its exports, `const [h, g] = (() => { …; return [add,
  sub]; })();`, at a few bytes a file. (a) is the smaller output and the one to build. A sibling's
  own `import` of a host module (`node:process`) stays an `import` at the top of the one file.

What it must answer before it is built, which is why it is a proposal:

- **The test harness reads the runtime by path.** `tests/browser/driver.mjs` imports the runtime
  file for `flush`; `bench/ui/lib/serve.mjs`'s micro pages import `Main.mjs` by name. A one-file
  build needs the runtime's `flush` reachable another way — an export of the entry file, which is
  harmless.
- **§10's chunking and research 26 §8.2** decide how a multi-entry build splits; one file is the
  degenerate case and must be the same code path, not a second one.
- **Determinism** is unchanged in kind: the order is the module order and the names are the table's.

Acceptance: the app at or below 5 164 brotli (Rollup's hoisting of today's tree), dev output
byte-identical, every `run/` and `browser/` fixture's release pass unchanged.

### 5.2 A helper's constant arguments (192) — for the `dom` lowering

`view` calls `button "run" "Create 1,000 rows" Run` six times. The lowering inlines each call as a
hole of the container's kind and **memoises every argument**: the instance keeps eighteen fields
`a0_0` … `a5_2`, and `p` re-checks eighteen values on every render before it reaches the `For`.
All eighteen are literals or nullary constants (backend.md §4, *A nullary constructor is one
object*): they cannot change. Solid's `Button` gets its three values once and nothing remembers
them. **A hole whose value is a compile-time constant needs no memo field and no check**: the
mount writes it and `p` never looks at it. Hand-applied — only the `For` left in `p`, no `a*_*`
fields — the app is **−192** brotli, and every render of the table does eighteen fewer
comparisons. The constants could also leave the view's `v` array for the kind itself, which this
does not price. It is `zig/dom.zig`'s, and the agent working there should take it.

### 5.3 Integer constructor tags (44)

Fourteen `$:"Tag"` strings and their `case"Tag"`/`.$==="Tag"` tests; integers save 44 now. That is
backend.md §9's integer-tag item, which rides with item 4 (declined on its own numbers) and needs
the sibling contract (`{$:0}`/`{$:1}` for lists, `Debug`'s reading of `$`) settled. 0.8 % of this
app; not worth building on its own.

### 5.4 The runtime's `map` (40) — for the runtime

`Html.map`'s runtime export `map` and its kind `mapKind` survive elimination in every program
because `reconcile` declares a local `let map = null`, and a lexical pass must count a mention of
the name as a use (backend.md §9; research 40 §8 rule 4). Renaming that local — to `keyed`, say — in
`platforms/browser/runtime.js` drops both from every browser program that does not map: 40 bytes
here (116 before A2 renamed the rest), more on a small page. It is a one-word edit to a file this
report does not touch.

### 5.5 What is not worth doing here

`List` in cons cells against Solid's arrays is the `core/Array` decision (research 38, 40) and not a
size question; arithmetic through `Basics.add`/`sub` calls is §4's peephole, worth tens of bytes
once hoisted (terser inlines them in the one-file bound); the word lists as an array plus a helper
(5), one shared empty list (9).

---

## 6. Could not determine

- How much of §5.1's 792 (hoisted and through terser) a hoisted build would keep **without** a
  general-purpose `compress`: the 303 of hoisting alone is the floor, A2 on the one file adds some
  of the rest, and nothing short of building it says how much.
- Whether §5.2's constant holes change the benchmark's render times measurably; eighteen fewer
  comparisons per render of the whole view should be visible only on `select`, which re-renders the
  container too.

## 7. How to re-run

```sh
zig build                                  # zig-out/bin/beni
node bench/ui/build.mjs                    # the app, dev and release, and Solid 1 and 2
node bench/ui/sizes.mjs                    # §0.1's rows
node bench/ui/anatomy.mjs                  # §0.2, §2 and §3.4's tables
node bench/size.mjs                        # §4
```
