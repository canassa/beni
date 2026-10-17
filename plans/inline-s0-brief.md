# S0 brief — `browser-inline`: the host boundary without the task kernel, and the empty page

*2026-10-17. Slice S0 of #295 (`plans/direct-rewrite.md` §5), issue #296. The implementer's brief;
the manager reviews against it. The plan is the parent; where this brief and the plan differ, this
brief records the owner's decision that changed the plan.*

## 0. Rules of this slice

- **The spec is tea-inline's output** (`../reactivity-research/frameworks/tea-inline/`: README,
  `template/runtime.js`, and `./rr generate unique-components tea-inline --size 1 --seed 1` under
  `generated/`). A golden is in its shape: names and numbering may differ; a message object, a
  `case`, a scope record, a block recompute, a subscription list never removed may not.
- **Start from nothing.** The platform is a new directory, `platforms/browser-inline/`. It imports
  nothing of `browser-tea`'s or `browser`'s `Rt`, `Hosted`, driver or kernel, and depends only on
  `html`. `platforms/browser-direct/` stays untouched as the reference (it must stay green).
- **Strict, not coarse.** What the lowering cannot do exactly is a build error that names the
  cause and what to write instead. Never a fallback.
- **Stop and report, never work around** (CLAUDE.md rule 10, and the owner for this work): if the
  intended design hits a compiler limitation or a conceptual gap — an analysis that does not give
  a fact you need, an interface that cannot express it, a bar that cannot be met — **stop, write
  down the wall with evidence, and report it** in your final message. Do not change the design,
  weaken a test, raise a budget, add a runtime fallback or move code behind `foreign` to get
  past it. Any deviation from this brief, however small, is reported, not taken.
- Read first: `CLAUDE.md` (binding), `plans/direct-rewrite.md`, `docs/design/boundary.md` §9.4
  and §9.8, `docs/design/write-sets.md`, `src/markup/Interface.zig`, `docs/design/schema.md` §6.
  Use the `zig-developer` skill for any Zig API question and `write-tests` for the fixtures.
- Commits: house style (`commit` skill), no plan codes in subjects, ≤ 72 chars. Commit on the
  branch `inline-s0` in the worktree `/home/canassa/src/github.com/canassa/beni-inline-s0`
  (its own Zig cache; never build in the main checkout). Do not push, do not open the PR: the
  manager does.

## 1. The owner's decisions for this slice (2026-10-17)

1. **Mount fault: dropped from release, bar kept.** Release ships no `$$root` mark and no
   "cannot mount" message; development keeps both. **Condition:** a missing root in release still
   goes through the defect guard — "a defect stops the page" without prose — never an unguarded
   `TypeError` escaping the entry. The defect guard and the mid-dispatch send queue stay (plan §8).
2. **`schema.md` §6 amended:** a parse whose `Err` payload is never read compiles to a validator
   (no `Issue`, no prose); a program that reads the error pays for the prose, and only that
   program — the inferred-from-use rule applied one step further. Write the amendment as a dated
   amendment (never renumber, CLAUDE.md rule 2) before the code.
3. **S0 carries exactly one text binding:** one text node, one compare, one write, one module.
   Nothing else of S1 (static markup per module beyond the page, groups, cross-module readers).
4. **D3 decided — synchronous, precisely:** one write pass at the end of the dispatch, inside the
   handler's guard. The arm writes the model; then the bindings the key's write set names run once,
   deduplicated statically. Not a DOM write at each field assignment, not a microtask.
   Consequences carried into the goldens: `settled()` resolves immediately; two events in one task
   are two full passes (no coalescing, accepted); S3's rank-ordered flush will be "drain at the end
   of the dispatch". (S1 measures it against tea-inline's microtask; not your concern here.)
5. **Commands that cannot suspend run after the handler's writes, in the same dispatch, through the
   guard's queue**, with a `boundary.md` §9.8.4 dated amendment. A command that completes
   synchronously and sends re-enters through the same queue.
6. **Decoding happens in the arm** through `Schema.read`, as the research generators already do. No
   decode-at-the-boundary API.
7. Engineering choices the owner accepted:
   - a model-dependent subscription set is a build error in S0 naming S4;
   - a suspending command or subscription is refused by the lowering with the text
     "needs the task kernel: not on this platform yet";
   - the unmount export is `stop`, one per program (tea-inline's name), with the `boundary.md`
     §9.4.5 amendment;
   - `browser-inline` writes its own HTML serializer. **Correctness only**: optional-end-tag
     omission is worth 0.8 % on tea-inline; do not spend time on it in S0;
   - fixtures in `tests/corpus/emit/release/inline/`, `emit/inline/`, `build/bad/inline/`,
     `browser/inline/`; the page driver gains a `CustomEvent`-with-`detail` step and a `stop` step.

## 2. What lands

- `platforms/browser-inline/`: `beni.json` (`"platforms": ["html"]`, `"program": "Browser.Program"`,
  `"html": "index.html"`, `"lists": "in-place"`, `"markup": { "lowering": "inline", "module":
  "Inline" }`, `"zig": "zig/root.zig"`, `"reexports": ["Html", "Browser", "Cmd", "Sub", "Tea"]`);
  `Browser.beni` (`foreign type Program`, `mountAt`); `Tea.beni` (`sandbox`, `element` with exactly
  `browser-tea`'s signature, so one source builds on both); `Cmd.beni` (`none`, `batch`, a
  non-suspending `perform`); `Sub.beni` (`none`, `batch`, `map`, `on` with `browser/Sub.beni`'s
  signature, no `listen`); `Listen.beni` (`on` only, no `Task` import); `Inline.beni` (the runtime,
  in beni over `Js`: guard, queue, `run`, `stop`, disposers); `index.html`; `zig/`.
- `Sub.on` over a host event → `addEventListener` and the key's handler; the research layer's
  `Interval.every` → `setInterval`/`clearInterval` with its remover. Two declarations with the same
  constant key merge at compile time.
- A non-suspending `Cmd` is a direct call per decision 5; `Cmd.none` emits nothing.
- `stop` (W51): the program's root removed, its listeners and timers removed, the dead flag set.
- The analyses consumed, not re-derived: `programKeys`/`programArm`/`programCalls`/`programHole`
  (write sets, read sets), `subscription_reads`, the ownership checker through `"lists": "in-place"`.
  New interface facts the planner identified (version bump of `Interface.zig`): `programSubscriptions`
  (per `Sub.on`: constant key, `start`, tagger resolved to a key with its arguments), and a per-key
  "command is `none` / does not suspend" fact. If an existing analysis does not give one of these
  exactly, that is a wall: report it.
- Design text first (rule 1): `boundary.md` §9.4.5 (`stop`) and §9.8.4 (command order) amendments,
  `schema.md` §6 amendment, and a short `browser-inline` section — the analysis rules and the error
  taxonomy only, no lowering prose a golden already pins (plan §3).

## 3. Goldens (fixtures first, red before the code)

Sources in the research generators' API (`../reactivity-research/scenarios/*/shared/beni.js`,
`frameworks/beni/template/Push.beni`, routed-app's `Interval` layer).

1. `emit/release/inline/EmptyElement.beni` — `Tea.element`, `Model = {}`, `Msg = Noop`, `Cmd.none`,
   `Sub.none`, `view _ = <div data-role="dashboard"></div>`, `Browser.mountAt … "root"`. Plus
   `EmptySandbox.beni`. Whole `_main.mjs` golden.
2. `emit/release/inline/PushAndTimer/` — a project with the generators' `platform/` layer
   (`Push.beni`, `Interval.beni`, unchanged but for the platform name), `Msg = Pushed Value | Tick`,
   `Model = { count, ticks }`, `Sub.batch [ Push.onPush Pushed, Interval.every 1000 Tick ]`, the push
   decoded in the arm with a tagged schema (`set { value : Int }` / `reset`) and `Err _ → model`,
   and a view with one text binding (decision 3; the second number may be static or the same
   binding — exactly one dynamic text in total).
3. `build/bad/inline/`: a suspending command body; `Sub.listen`/`Time.every`-style kernel use; a
   model-dependent subscription set; a tagger that resolves to no key. Exact diagnostics.
4. `browser/inline/PushAndTimer` (page driver, happy-dom): push with detail, advance the clock,
   count listeners and timers, `stop`, count again (0), body empty. Built for `browser-inline`;
   if the existing differential pairing can also build it for `browser-tea` against one golden,
   do so, else report why not.
5. Each release golden: no `core/Task`, no `core/Dict` in the output (assert via the source map or
   the output tree).

The target shape, hand-written by the planner (brotli 11; `scratchpad` copies were measured):
empty 283 B, push+timer without mount check 437 B. Release must contain no message objects, no
`switch`, no `Issue` prose.

```js
// empty (shape)
let a=false,b=false,c=null;const d=(e,f)=>{if(!a)if(b)(c||=[]).push(e,f);else{b=true;let g=false;try{e(f);while(c){let h=c;c=null;for(let i=0;i<h.length;i+=2)h[i](h[i+1])}g=true}finally{b=false;if(!g){a=true;c=null}}}};let e;
d(()=>{const f=document.getElementById("root");f.insertAdjacentHTML("beforeend","<div data-role=dashboard>");const g=f.lastChild;e=()=>{a=true;g.remove()}});export{e as stop};
// push + timer: the arm inside its listener, the decoder a validator with no prose, the model
// written in place, then the one text binding: P=v=>{…if(k=="set"){…s.g=x}…;t(h,s.g)},
// l=m=>d(P,m.detail), n=setInterval(()=>d(()=>{s.j++…}),1000), addEventListener("rr-push",l),
// stop removes the listener, clears the interval, removes the root.
```

## 4. Bars (S0)

- Empty mounted program ≤ 300 B brotli; with subscription + timer ≤ 450 B (`bench/size.mjs` or the
  same brotli-11 measure; report the exact numbers and a per-source attribution).
- Nothing of `core/Task` or `core/Dict` in either bundle.
- `zig build gates` green (run it yourself; never two suites at once; read failures from a log).
  Run hashes recorded (`zig build test-run-hashes`) where the emitter's output changed.
- Compile time: report the S0 programs' build time; not a bar here.
- Every fixture proven red before the change (stash the fix, say so).

## 5. The research project — not in this task

The `../reactivity-research` measurements (a `frameworks/beni-inline/` entry sharing
`frameworks/beni/`'s one pin and `install.sh`, scratch `--out` only, nothing in `runs.json` until
the owner's hand check through `./rr serve`) run after the manager's review, as a separate step.
Do not touch that repository. If a design choice here would make that adapter impossible
(`stop`, `settled` resolving immediately, `rr-push` through `Push.onPush`), report it.

## 6. Your final report

What landed (files, commits), each golden's bytes against the bar, red-before proof per fixture,
gates result (log excerpt), every deviation from this brief and every wall you stopped on, with
evidence (file:line, the diagnostic, the number). Short, factual; no "should work".
