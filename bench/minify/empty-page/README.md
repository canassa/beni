# The empty `browser` page, minified by hand to its limit

A study under the `hand-minify` skill: how small can the empty mounted page get —
a program whose `view` is `<></>`, built `--platform=browser --release`
(`bench/size.mjs`'s `browser` page line) — with behaviour unchanged and nothing
slower? Measured on `master` at `1f1deab4`, Node 24.19, brotli 11 (gzip 9
second, raw a diagnostic). `platforms/browser/runtime.js` is not edited: the
study works on a copy (`src/runtime.js`) and on the shipped file.

## Answer

| stage | raw | gzip 9 | **brotli 11** |
|---|--:|--:|--:|
| `master` ships (`steps/00`) | 2 262 | 1 106 | **978** |
| every page could ship this: runtime source rules and compiler passes that need no whole-program fact (`steps/06`) | 2 087 | 1 048 | **928** |
| terser (`compress` passes 3, toplevel, `mangle` toplevel) over `steps/00`, a reference only (it inlines by making closures) | 1 704 | 879 | 778 |
| `steps/06` with only the facts `Spec.zig` already derives for a runtime written in beni (steps 08, 09, 11, 16: −132) | | | ≈ 796 |
| **the limit: the whole program in view** (`steps/25`) | **279** | **212** | **157** |

**The hand-written runtime is already tight for bytes that every page shares**:
50 brotli bytes (5 %) is all that source rules and compiler passes without
whole-program facts buy, and half of those are single-digit, below the ±5 noise.
Spelling tricks price as noise or worse (`results/trials.md`). **Everything
else — 771 of the 821 bytes between 978 and 157 — is whole-program
specialisation**: this page never passes `template` a flag, never mounts a
hosted program, mounts once at the body, renders one constant block, and its
render loop has no observable effect. The limit program is:

```js
let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");S.$$root=ca=>{};S.appendChild(globalThis.document.createComment(""));export let flush=()=>{};
```

It fails exactly as before (the same two messages, `${null}` folded to
`"null"`), marks the body, appends the same empty comment after the body's
children, and exports a `flush`.

## Ledger

One technique per step; `steps/NN-name.mjs` is the one before plus that
technique. Δ under 10 is a direction, not a magnitude (skill §1.2).

| step | technique | raw | gz | br | Δbr | bin (skill §5) |
|---|---|--:|--:|--:|--:|---|
| 00 | baseline | 2262 | 1106 | 978 | | |
| 01 | `childHtml` puts its first instance itself (`place`'s `swap` arm is dead there) | 2219 | 1089 | 961 | −17 | source rule |
| 02 | `head`/`tail` as one conditional expression each | 2175 | 1078 | 955 | −6 | source rule |
| 03 | `const` → `let` over the whole one file | 2103 | 1062 | 945 | −10 | Minify (A3 over kept tokens) + source rule |
| 04 | a kind's unread trailing parameters dropped | 2097 | 1056 | 943 | −2 | printer (`Opt` knows reads) |
| 05 | the emitted half's `,\n`/`;\n` newlines dropped | 2090 | 1050 | 930 | −13 | printer |
| 06 | no newline after a `}` that closes a block | 2087 | 1048 | 928 | −2 | Minify |
| 07 | program record fields `init`/`update`/`view` → `i`/`u`/`v` | 2062 | 1033 | 918 | −10 | types: field renaming across the runtime |
| 08 | `template`'s constant html and flags folded | 1843 | 949 | 841 | **−77** | Spec fact 1 (built for beni code) |
| 09 | no hosted mount: `m.h` undefined, `phase` never set | 1802 | 923 | 820 | −21 | Spec facts 3, 2 (built) |
| 10 | every mount record's `n` is `null`: mount at the body, messages folded | 1692 | 877 | 777 | **−43** | Spec+: a field whose every write is one literal |
| 11 | the slot's constant marker/context folded, unread fields dropped | 1611 | 844 | 754 | −23 | Spec facts 1, 3 (built) |
| 12 | calls through the one kind pass no arguments | 1598 | 836 | 749 | −5 | Spec+: call through a property resolved |
| 13 | `view` returns the one block, so `patch` returns at `b === i.b`: `patch`, `swap`, `drop` go | 1338 | 746 | 674 | **−75** | Spec+: must-alias on a singleton site |
| 14 | a render after the mount does nothing | 1326 | 744 | 672 | −2 | Spec+: flow + purity |
| 15 | every instance's ends are nodes: `head`/`tail` go | 1135 | 672 | 602 | **−70** | Spec+: non-null field fact |
| 16 | unread keys and writes (`t`, `b`, `p`, `v`) dropped | 1088 | 656 | 591 | −11 | Spec fact 3 (built) |
| 17 | `update` is the identity and `view` ignores the model: the model goes | 1050 | 631 | 563 | −28 | Spec+: inline a resolved identity, drop unread params |
| 18 | every function called once written where it is called | 867 | 535 | 451 | **−112** | §9 *called once*, extended to the runtime |
| 19 | scalar replacement of the slot; the one-node instance's `put` loop peeled | 709 | 455 | 382 | **−69** | escape analysis, guard flow fact |
| 20 | the record, block, kind and `view` constant-propagated away; one-record loop peeled | 577 | 380 | 308 | **−74** | constant propagation through non-escaping literals |
| 21 | the cloner called once: no memo, no clone | 510 | 346 | 276 | −32 | Spec+: closure called once |
| 22 | `<!>` is `createComment("")` | 457 | 312 | 255 | −21 | `dom` lowering (every page; faster) |
| 23 | one program: the render queue is a flag, the two flags one | 357 | 263 | 211 | −44 | the limit only |
| 24 | nothing observes the render loop: `send` and `flush` are empty | 285 | 215 | 163 | −48 | the limit only |
| 25 | `insertBefore(x, null)` → `appendChild(x)` | 279 | 212 | 157 | −6 | peephole |

Every step's reason and what beni would need is in `steps.mjs` (`what`, `sound`,
`needs`).

## Behaviour

- **The page** (`node measure.mjs test`): every step in happy-dom — the load
  (exactly one empty comment in the body), `$$root` set, `flush` exported and
  callable, two sends rendering on one microtask to the same node, the body
  already holding a program, no body yet (`no element has the id "null" …`),
  mounting after the body's existing children, and up to step 09 the id path
  (missing id, taken id, after an element's children) by rewriting the mount
  record. `tools/mutants.mjs`: 16 of 16 one-token mutants of the first and last
  step are caught.
- **Every page** (`node measure.mjs verify`): each source step is built into all
  28 `browser/dom/` and `browser/tea/` fixtures against a patched copy of the
  platform, `--release`, and compared with their goldens; each generic output
  step's rewrite is applied to all 28 one-file builds. 28/28 at every step.
  Building the page against the unpatched copy reproduces `master`'s file byte
  for byte, so the source steps' files are exactly what beni would ship.
- **Chrome** (`nix develop .#browser`, `node measure.mjs chrome --timing`):
  the final runtime with every generic rewrite, 28/28; the load transcript of
  `steps/00` and `steps/25` equal (`results/chrome.txt`).
- **A corpus gap** (`tools/mutants.mjs --corpus`): four mutants of `head`'s
  list arm and of `tail` survive — no `browser/` page mounts a component whose
  first or last node is a `For` or a slot with no marker. Step 02 is therefore
  argued equivalent (an `if … return; return` rewritten as the same tests in the
  same order), not tested; the corpus should gain such a page.

## Speed (skill §1.4)

Only steps 01 and 02 change what runs on pages other than this one.

| hot path | Node 24 (V8), median | Chrome 153, median |
|---|--:|--:|
| `first` over 4 096 instances ×2 000: `!==null ?:` / `??` | 14.0 / 16.0 ms | 12.9 / 13.2 ms |
| `parentOf` ×2 000: `!==null ?:` / `??` | 11.7 / 13.1 ms | 8.8 / 9.9 ms |
| `childHtml` first mount, 4 096 ×100: through `place` / step 01 | 5.29 / 5.23 ms | 5.5 / 4.4 ms |
| a comment marker ×50 000: template clone / `createComment` (step 22) | — | 16.9 / 13.5 ms |

`bench/ui` (the table app, `browser-tea --release`, only the runtime
different; `results/ui-batch-*.md`): script medians of the final runtime
(`beni-min`) against the current one — batch 1 (n=4, nine operations, with
Solid 1) mixed within noise, run1k 5.12 against 4.80; batch 2 (n=12, run1k and
create1k-after1k) 4.96 against 5.12 and 5.25 against 5.45. No difference beyond
noise. On the app the two source steps save 19 raw bytes and cost +5 brotli
(noise): `Show` keeps `place`, so step 01 only pays on pages without one.

## Not taken

**Refused for speed.** `x ?? y` for `x !== null ? x : y` in `first`, `last`,
`parentOf` (−6 br): 10–14 % slower in V8 in Node, 2–12 % in Chrome
(`??` tests `undefined` too). `do…while` for `put`/`drop`'s loops: +27 br and a
different loop. Packers, string-encoded data: out by rule.

**Refused as unsound, or changing behaviour.** A bare `document` instead of
`globalThis.document` (the build refuses it: `foreign_unbound_reference`,
`boundary.md` §4 check 3). `root.$$root` truthiness for `!== undefined` (−3):
a node holding a falsy `$$root` would stop counting as taken. Shorter error
messages: observable. One function for `$$root` and `flush`: identity changes.
`queueMicrotask(() => L && N())` (+3 anyway): the callback's result changes.

**Priced and not worth it** (`results/source-trials.md`, `results/trials.md`):
renaming the `parent` and `document` locals (+1, +4 to +8 — both are brotli
dictionary words, and the copies are already cheap), `cx` renamed (+3 to +9),
`s.u?.length` (+2), `!=`/`==` for `!==`/`===` null (+9, +11), `!0`/`!1` (+15),
joined `let`s (+8), `mount` written in `run` (+1), the emitted `(a)=>` → `a=>`
(−2), shorthand `e:e` → `e` (+5), `export{flush}` named at the declaration
(+9). A statement-order hill-climb (`tools/order.mjs`) finds −10 on
`steps/06` and −17 to −20 on the baseline, an order no rule predicts that
overfits one brotli version and one page's set of kept units. terser's local
`compress` alone (`tools/terser-local.mjs`, no inlining) buys −9 on `steps/06`.

## What beni would need

**The compiler, ranked by bytes over effort:**

1. **The runtime compiled with the program, so `Spec.zig`'s built facts reach
   it** — the port of the runtime into beni now under way: template folding
   (−77), the hosted mount (−21), the slot's fields (−23), unread keys (−11),
   and record-field renaming across it (−10, `backend.md` §9 item 4): ≈ −140.
2. **`A function called once is written where it is called`, extended to the
   runtime's functions once `Spec` has cut the callers** (−112 here): built for
   beni code; needs the runtime in beni, and the closure-returning case
   (`template`: its locals become the caller's).
3. **Three more `Spec` facts**, each a small extension of fact 3's points-to:
   a field whose every write is one literal (−43), a field never `null` (−70),
   must-alias on a singleton allocation site (−75): ≈ −190.
4. **The `dom` lowering: a template that is one empty comment is
   `createComment("")`** (−21 here, every page's fragment and empty-hole
   markers, 11–20 % faster in Chrome) — small, and a rule for every page.
   **Measured and refused 2026-10-02** (`backend.md` §15.3, *Markup with no
   nodes*): faster alone, but a comment made in the page's document is
   adopted into the inert document of the cloned row it is placed in, so on
   the table with an empty fragment per row it is 3–4 % slower to create;
   and beside other templates it costs bytes. It pays only on this page.
5. **Printer and compactor passes for every page**: the emitted half's
   newlines (−13), `const` → `let` decided over the kept tokens rather than the
   whole file (−10 br, −16 gz; `Minify.constToLet` reads `assignedNames` over
   every token, so a cut unit's `i = …` keeps the kept units' `const`), a
   kind's unread trailing parameters (−2), no newline after a block's `}` (−2),
   `insertBefore(x, null)` → `appendChild(x)` where the reference is a literal
   (−6 at the limit).
6. **Escape analysis and scalar replacement, constant propagation through
   non-escaping literals, loop peeling, an identity `update` inlined** (−69,
   −74, −28): what a Closure-class optimiser does; large.
7. **The last 92 bytes** (steps 23–24) need a proof that the render loop is
   unobservable: the limit, not a plan.

**Source rules for `runtime.js` (and `Rt.beni`) authors:**

- At a call site that knows which arm of a helper it needs, take that arm
  rather than calling the general helper (step 01: −17 on a page without
  `Show`; the helper's other callers keep it).
- Write a selector that is a chain of `if (…) return …; return …` as one
  conditional expression, a concise arrow, like its neighbours (step 02).
- Never give a `const` a name some `let` elsewhere in the file assigns: A3 is
  all-or-none by name (`patch`'s `const n` against `put`'s `let n`).
- Do not rename locals that are brotli dictionary words to get them renamed
  (`parent`, `document`): it costs bytes.
- Keep `!== null ? :` for hot null tests; `??` is slower in V8.

## Files and commands

`src/Page.beni` (the page, as `bench/size.mjs` writes it), `src/runtime.js`
(the runtime at `1f1deab4`), `src/runtime.final.js` (after steps 01–02),
`built/_main.mjs` (`master`'s page), `steps/` (every step), `steps.mjs` (the
steps as edits, each with its reason), `results/` (every number above),
`tools/` (trials, source trials, timing, mutants, order search, the bench/ui
batch). With `zig-out/bin/beni` built from this commit:

```sh
node measure.mjs build          # built/_main.mjs from master's platform
node measure.mjs steps          # regenerate steps/ and src/runtime.final.js
node measure.mjs ledger         # the ledger
node measure.mjs verify         # the page test per step; the corpus per source/generic step
node measure.mjs units FILE     # the file's top-level units, leave-one-out
node tools/trials.mjs           # single edits priced alone
node tools/source-trials.mjs    # single runtime source edits, through Minify.zig
node tools/mutants.mjs --corpus # the checks catch wrong steps
node tools/timing.mjs           # hot paths (Node); Chrome: measure.mjs chrome --timing
```
