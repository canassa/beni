# 65 — The direct platform, slice S0: the program hook, the floor and a static mount

*2026-10-09. What `browser-direct.md` §14's slice S0 built of the platform and the harness — the
program hook (`boundary.md` §9.4.6, version 1.6), `platforms/browser-direct/` with its `direct`
lowering, `Tea.sandbox` of a static `view`, `run`, the guard, the defect at mount, the
mounted-twice refusal, the differential page corpus and the bench subjects — and what it measured
against kill criterion 2 (§13). The stats gate, S0's other half, is a separate piece of work and
is not reported here. Every figure is **[measured]** by the commands in §5.*

---

## 0. The answer in five sentences

1. **Kill criterion 2 passes**: the empty mounted page on `browser-direct` is **399 B** brotli 11
   minified (the release build), under the 500 B tripwire, and its program imports **nothing of
   the runtime module but `run`** — not even `send` or `unset`, which the criterion allows.
2. **The 300 B target is missed by 99 B.** 70 B of the 399 are the four refusal messages a page
   needs (a program mounted twice, a missing element, a body or an element that already holds a
   program) — the last three the same strings `browser`'s runtime throws — and the rest is the
   guard with its queue, `run`'s two passes over the mounts and the constructor; no dispatcher,
   cloner, slot, reconciler or render loop is in it (`emit/release/direct/EmptyPage` pins the file).
3. **The 1 234 B §3 and §13 quote for today's empty page is stale**: today's `browser` and
   `browser-tea` empty pages are **446 B** each, since the release optimiser specialises the
   runtime module to the page (`backend.md` §9); `browser-direct`'s is 47 B (11 %) smaller, and its
   development build 1 515 B against 5 805.
4. **A static page mounts 1.12× vanilla at 1 000 elements and 1.51× at "hello"**, from a real
   click, untraced, in Chrome; `browser-tea` is 1.41× and 1.62× (release). The hello gap is
   0.115 ms of cold code — the guard, `run` and the mount compiled on their first call — on a
   0.225 ms vanilla mount.
5. The two platforms show the same page for every `browser/direct/` fixture but one, `InitThrows`,
   where they differ **by design** (§3): on `browser-direct` `init` runs inside the mount, so a
   throw there is a defect with a crash screen; on `browser-tea` it runs where `main` is evaluated,
   while the module loads, before any guard.

## 1. What was built

**The program hook** (`src/markup/Interface.zig`, `src/js/Lower.zig`'s *The program hook*). A
lowering names its program constructors (`Lowering.programs`, each a `foreign`); the compiler
finds every call of one in a surviving declaration before lowering, and at the call hands the
lowering a `Program` — the record's shapes, `view`'s markup root — instead of evaluating the
record. The lowering returns the program's mount, and the call is compiled as the constructor
applied to it, so `Tea.sandbox`'s sibling makes the `[{ a, n }]` that `Browser.mountAt` and
`Browser.programs` already rewrite. `cx.programInit(block)` evaluates `init` where the lowering
places it, bound to a name `--release` keeps when `init` may have an effect. The `view` and
`update` only a record names are not emitted. `Lowering.no_markup_values` refuses markup as a
value (S4's value path) and primitives; `Lowering.placements` is what `program_mounted_twice`
reads; `Named.refused` turns away `Browser.program` and `Browser.hosted`, whose runtime the
platform does not have.

**The platform** (`platforms/browser-direct/`): the manifest of §12.1; `Tea` with the API of
`browser-tea`'s (`sandbox`, `element`, `document`, `application`, `Program`, `Document`), each
constructor a `foreign`; the runtime module **`Direct`** — not `Rt`, because a module name is
unique across the chain and `browser`'s `Rt` is in it — holding `send` (§4.3's guard: dead,
running, a queue of pairs drained in order, `try … finally` with no `catch`), `unset` (§5.3) and
`run`; and `zig/direct.zig`, the `direct` lowering, targeting 1.6. A mount is
`(root, t) => { const init = …; t.innerHTML = "…"; root.append(t.content); }`: `run` hands it the
mount node and a `template` element, inside the guard, after refusing a program value mounted
twice (a `$mounted` mark) and before any program renders. The template text is `dom`'s own
(`dom.staticTemplate`, the `dom` plan of markup that writes nothing), so both platforms parse the
same characters.

**What S0 refuses, naming the slice**, all at build time (`build/bad/direct/`): a hole, an event,
a computed attribute (S1); `For` (S2); a component (S3); `Show`, a controlled attribute, markup as
a value, `Html.text` and `Html.map` (S4); `Tea.element`, `document`, `application` (S5); a `view`
of another module, a computed `update`, a record not written at the call (S1); a `view` computed at
run time or a constructor used as a value (`view_not_compiled`); `Browser.program` and
`Browser.hosted`; one top-level program value placed twice (`program_mounted_twice`).

## 2. The floor, kill criterion 2

`node bench/size.mjs --pages-only`, minified (`--release`) and brotli 11 over the whole bundle:

| page | dev brotli | release raw | release brotli | imports of the runtime module |
|---|--:|--:|--:|---|
| `browser` empty | 5 757 | 891 | 446 | `run`, `template` |
| `browser-tea` empty | 5 805 | 891 | 446 | `run`, `template` |
| **`browser-direct` empty** | **1 515** | **838** | **399** | **`run`** |
| `browser-tea` hello | 5 817 | 937 | 466 | `run`, `template` |
| `browser-direct` hello | 1 550 | 924 | 447 | `run` |

Of the 399 B, removing the `$mounted` message saves 43 B and the three element messages 27 B
more (329 B without any). The criterion is the 500 B tripwire and the import list, and both pass;
the 300 B target is an estimate (§13) and is missed. Reaching it would mean dropping or shortening
refusal messages a developer reads when a page will not start, which this slice did not do.

## 3. The two platforms, each other's oracle

`tests/corpus/browser/direct/` builds every page for `browser-direct` and `browser-tea`, dev and
release, against one golden:

- `Hello`: a static page — elements, attributes, a decoded entity, a void element; a click
  changes nothing. Equal.
- `DefectAtMount`: `programs [ a, mountAt b "nowhere", c ]`: `a` renders, `b`'s missing element is
  thrown inside `run`'s guard, the crash screen shows it in development, `c` never mounts. Equal.
- `InitThrows`: `init = Debug.todo …`. **Not equal, by design**: `browser-direct` evaluates `init`
  inside the mount (§8.2: "a throw in `init` … is a defect like any other") and shows the crash
  screen; `browser-tea` builds the record where `main` is evaluated, so the throw happens while the
  module loads, before `run` installs anything, and its page shows only the host's report. The
  harness takes a `<name>.tea-expected` for such a specified difference; this is the only one.
  It is observable only through a throw or a `Debug` call in `init`, and it is in the direct
  platform's favour (the page is stopped as a defect, not left half loaded). A finding for the
  owner, not a defect: §12.3's "one golden" holds for every page except one whose `init` has an
  effect.

`emit/direct/Hello` pins the development mount; `emit/release/direct/EmptyPage` the whole floor.

## 4. A static page's mount, from a real click

`bench/ui/mount.mjs` (new): a fresh page per sample, the program's modules loaded first, then a
real click on `#go` whose listener calls `run(main)` — for a release build, the file's last
statement turned into the function the click calls — timed in the page from a capture-phase click
listener to a microtask queued after the bubble phase (`scaling.mjs`'s `--untraced`); style,
layout and paint excluded. Vanilla is the same HTML through a `template` and one `append`.
Chrome 153, headless, `--taskset=8-15`, 15 pages per subject and size, subjects rotated; load
average up to 5.4 on the other cores.

| page | subject | mount ms, median [q1–q3] | × vanilla |
|---|---|--:|--:|
| hello | `browser-tea` dev | 0.505 [0.493–0.522] | 2.24 |
| hello | `browser-tea` release | 0.365 [0.355–0.380] | 1.62 |
| hello | `browser-direct` dev | 0.355 [0.343–0.365] | 1.58 |
| hello | `browser-direct` release | 0.340 [0.325–0.347] | 1.51 |
| hello | vanilla | 0.225 [0.215–0.228] | 1.00 |
| 1 000 `<li>` | `browser-tea` dev | 2.020 [1.940–2.065] | 1.44 |
| 1 000 `<li>` | `browser-tea` release | 1.975 [1.950–2.015] | 1.41 |
| 1 000 `<li>` | `browser-direct` dev | 1.575 [1.502–1.635] | 1.12 |
| 1 000 `<li>` | `browser-direct` release | 1.580 [1.507–1.630] | 1.12 |
| 1 000 `<li>` | vanilla | 1.405 [1.330–1.430] | 1.00 |

At 1 000 elements the direct mount is within 0.17 ms of vanilla and 0.4 ms faster than today's
(`browser-tea` parses a template and then clones it; direct adopts the parsed content once, §5.1).
At hello the remaining 0.115 ms is fixed cost: four functions (`run`'s, the guard's, the two mount
passes) compiled on their first call where vanilla compiles one listener. No criterion of §13
names a mount ratio for S0; `create 1k`/`create 10k` are S2's.

**The harness**: `beni-direct` and `beni-direct-release` are subjects of `bench/ui/bench.mjs`
(built by `build.mjs` from `apps/beni`) and of `scaling.mjs` (from each sweep's source). Every
page they are given today has a hole or an event, so each is **skipped with the compiler's
reason** (`.skipped` beside the build; `skipped` in `scaling.mjs`'s result), never measured or
faked; they start measuring as S1 and S2 make those pages build.

## 5. Commands

```sh
node bench/size.mjs --pages-only                       # §2, the page lines
zig build test-blackbox-corpus -Dcorpus=/direct/       # §3, the differential pages and refusals
cd bench/ui && flock …/bench.lock env -u LD_LIBRARY_PATH nix develop ../..#browser \
  -c bash -c 'unset LD_LIBRARY_PATH; node mount.mjs --taskset=8-15 --pages=15'    # §4
node scaling.mjs --sweeps=holes --subjects=beni-direct --build-only              # the skips
```

The mount results are `bench/ui/results/2026-10-09-mount.json`.
