# A browser capability base for `browser-inline`

*Architecture approved by the owner, 2026-11-09, through the manager.
Guarded-entry and fixture contracts (§4.1, §4.3) approved by the manager,
2026-11-09. The owner approved §4.2’s staged init proof the same day.
Implementation follows in local slices; no GitHub publication is authorized.*

This specifies the approved renderer-free browser base required by
[`direct-rewrite.md`](../../plans/direct-rewrite.md) §5, §9, under the work
tracked by #302 and #966. It includes WebGPU's later capability modules.
The owner approved the architecture and sequencing in §8. The phase-aware init check in §4.2 is approved and amends
`prerender.md` §3.1; every host read remains refused.
Work is committed locally on `browser-base`, slice by slice. No push, PR,
issue or GitHub comment is authorized.

## 1. Outcome and constraints

One `browser-inline` program can prerender its initial HTML and then use
HTTP, timers, animation frames, DOM operations and WebGPU after hydration.
The initial model, view, routes and data conversions retain
[`prerender.md`](prerender.md) §3's purity guarantee. Host access there is
`prerender_impure` at the effectful call, before Node is started.

`browser` and `browser-tea` continue to build their existing programs. Their
renderers receive correctness work only. Their deletion and the eventual
rename of `browser-inline` remain subject to the retirement gate in the
existing plan; moving capabilities does not satisfy that gate.

A capability-free inline program must not grow. Synchronous commands keep
their synchronous write pass and dispatch ordering. The task kernel is
reachable only when the program needs it. A shared base must not import a
renderer or cause it to be emitted.

## 2. Package and manifests

Approved package: `platforms/browser-base/`, embedded like `html` and the
other shipped platforms. Its minimal manifest is:

```json
{
  "platform": true,
  "name": "browser-base",
  "platforms": ["html"],
  "reexports": ["Html", "Html.Markdown"]
}
```

There is no `program`, entry runtime, HTML shell, markup lowering or Zig
lowering registry in the base. This already fits `boundary.md` §9.1: a
platform can be a dependency or a library target without being runnable.
No new manifest key or compiler privilege is proposed.

Both `browser` and `browser-inline` depend on `browser-base`, replacing
their direct `html` dependency. Each keeps its own `Browser`, `Program`,
HTML shell, lowering and runtime module (`Rt` or `Inline`). `browser-tea`
continues to depend on `browser`. Public capability modules are explicitly
re-exported by each renderer platform and by `browser-tea`; private engine
modules remain accessible only to platform code. There is no wildcard
re-export and no renderer dependency hidden in the base.

Module names are unique across a chain. A module moved to the base must be
removed from its old package in the same slice. Shared modules cannot
import the selected renderer's `Browser`: dependency visibility runs down
the chain, never back up it. The generated core `Browser.Host.*` namespace
is already occupied and must not be repurposed for new runtime glue.

## 3. Module ownership

| Owner | Modules and responsibilities |
|---|---|
| Base, public capabilities | `Time`, `Dom`, `Http`, `Storage`, `WebSocket`, `Random`, `Browser.Events`, `Browser.Image`, `Browser.Canvas`, `Browser.Video`, `Browser.Source`, public `Gpu` / `Gpu.*` |
| Base, shared effect descriptions | One `Cmd` and one `Sub` type, with the existing full browser API; shared `Hosted` work/key/relay types and `Listen` primitives |
| Base, private implementation | `Gpu.Engine`, generated GPU support and other non-public GPU helpers; renderer-independent navigation operations and listener machinery |
| Renderer platform | `Browser`, its `Program` and constructors, `Tea` where applicable, `Browser.Navigation` facade, mount/hydration, dispatch guard, render phase, command runner and subscription runner |
| Existing packages, unchanged placement | `html` vocabulary and parser table; core `Binary`, `Clock`, `Date`, `Duration`, `Task`, generated `Browser.Host.*` types |
| Outside this extraction | Worker entry/runtime/wire/stream modules and new worker capability work |

`Hosted` moves only after removing its `import Browser exposing (Host)`.
It owns a renderer-independent opaque host and `Send` alias; the renderer
may expose compatible aliases under its existing names. Host operations
are supplied by the renderer as values. `Time`, `Cmd` and `Sub` use the
shared sender type rather than importing `Browser`.

`Dom.rendered` and HTTP's after-render wait currently call
`Browser.onRendered`. Those calls must become calls through the base's
render-phase boundary. The renderer owns the phase and supplies its wait
and cancellation behavior. The base owns neither a render queue nor a
second dispatcher. A page which does not use these operations reaches no
phase adapter.

Navigation needs a split rather than moving its current module unchanged.
Both navigation modules import their own `Browser`; inline also imports
`Inline`. Shared host operations, URL validation, errors and listener
installation move to a private base module (proposed name
`Browser.Address`). Each renderer keeps a small `Browser.Navigation`
facade and its `Browser.UrlRequest` constructors. The facades translate
shared link descriptions to their existing `Browser.Internal` /
`Browser.External` values. A type alias alone cannot preserve constructor
patterns, so moving `UrlRequest` and assuming aliases re-export its
constructors is not a valid migration.

WebGPU modules move as a family, including private dependencies, rather
than just the public re-export list. Generator output destinations,
staleness checks, API reference generation and fixture platform manifests
must follow the new owner. The typed host bindings stay in core.

## 4. Commands, subscriptions and execution

**Approved: common effect descriptions, separate renderer execution.** Platform layering cannot let base `Http.send` return
the inline platform's current nominal `Cmd`: the base cannot import that
module, and two modules named `Cmd` in the chain are a duplicate. Exposing
only direct operations would leave `Time.every`, `Http.send`, event
subscriptions and other existing APIs unusable together.

There is one public `Cmd` and `Sub` in the base. The existing browser
renderer preserves its full command policy and subscription semantics
(`boundary.md` §9.8). Inline gains these in sequence: early slices retain
today’s subscription limits and explicitly diagnose them as compiler
limits. Full keyed policies and model-dependent subscription sets follow
in the next slice, before the site depends on them. The capability APIs
are incomplete until that slice lands.
Inline's separate `Cmd`, `Sub` and `Listen` are removed only when their
consumers understand the shared descriptions. The inline analysis follows
capability helpers and reads these descriptions; it still compiles known
commands/listeners directly, and does not ship a generic TEA renderer.

- `Cmd.none` emits nothing; known synchronous work runs after the write
  pass through the existing dispatch queue, with no fiber.
- Suspended work uses core's task runtime in a per-program root scope.
  Stop and defects close the scope. A cancelled command closes its outlet
  before interruption, so stale HTTP/GPU replies cannot update the model.
- Keyed work preserves Restart / Queue / Ignore / Concurrent, key
  identity, mapped component keys, cleanup and cancellation ordering.
- `Sub.on` keeps direct listeners; `Sub.listen` runs scoped work. Timer
  subscriptions need the latter. Duplicate keys share a resource and
  retain every current tagger in declaration order.
- Model-dependent sets require a real subscription diff. Until implemented,
  they remain an explicit compiler limit; this proposal does not silently
  weaken the existing analysis rule or restart all subscriptions per event.
- Hydration completes its first write pass before subscriptions and init
  commands start. Command creation does not run the command body. The
  prerender tree executes neither subscriptions nor deferred commands.

### 4.1 Guarded entry: scoped registration, captured event entry

*Approved by the manager, 2026-11-09.*

The base owns `Listen` and a private synchronous registration context. A
renderer supplies an `Entry = sync ((⊤ → ⊤) → ⊤)` function. The operation
`Listen.withEntry entry install` runs the synchronous `install` callback
with that entry selected and restores the previous selection in
`Js.finally`, even if installation throws. It cannot span a suspension.
Nested installation restores the enclosing entry, not a default value.
This is runtime registration state, not a compiler-global singleton.

`Listen.on` and `Listen.on2` capture the selected entry **at installation**.
Their native event handler calls that captured entry with a thunk that
reads the event and sends its decoded value. Event decoding is synchronous
inside the native dispatch; the thunk is never queued for later. The
entry's reference belongs to that listener, so a later installation under
another program cannot change it. Removal drops the handler and its entry.

All base native event adapters, including frame callbacks, must enter
through the same private guarded-callback helper before they read an event
or call a tagger. Wrapping only `Listen.on` is insufficient. A third-party
subscription that executes arbitrary code before calling the platform's
listener helper remains responsible for that code, as today.

The inline renderer supplies this entry behavior:

1. If stopped, return without running the thunk.
2. If a dispatch is already running, run the thunk immediately inside that
   dispatch's guard. A send it makes joins the existing message queue.
3. Otherwise enter the normal dispatch guard, run the thunk, then drain
   queued work with the existing write-pass order. A reader that throws
   before any send still stops and cleans up the program. Re-throw the
   unknown failure; do not translate it or swallow it.

The old renderer supplies its own guarded entry; the base imports neither
`Browser` nor `Inline`. Each renderer runs synchronous subscription
installation under `withEntry`. There is no renderer switch on each model
write and no imported listener code on a page without listeners.

An unbound entry runs its thunk directly. That mode is for direct forms
in the calling fiber, whose failure follows the task's defect rule;
architecture-installed listeners must always bind an entry. A suspending
subscription body does not retain a registration cell across a wait: its
listener direct forms are protected by its root scope and task boundary.
No new task slot or Task dependency is required for a synchronous listener.

### 4.2 Log context: retain effectful capture; stage init command metadata

*Approved by the owner, 2026-11-09. The staged init proof amends
`prerender.md` §3.1. Do not implement this as a purity exemption.*

Keep browser's existing command creation semantics: `Hosted.job` captures
`Task.keepLogContext` **where the command is made**, within the dynamic
`Log.annotate` / `span` / `minimum` / sink scope. Moving the capture to
command execution loses that scope after the update returns. Capture stays
impure: `Task.keepLogContext` reads `Js.Ref` state with `Js.read`. Neither
it nor `Cmd.perform` is declared pure to bypass a check.

Client commands, synchronous and suspended, run with their captured
context. Each message update is bracketed by `Task.beginUpdate` and
`Task.endUpdate` using `Js.finally`, so its context is the program's rather
than the command caller's. A reported nested DOM defect must restore the
command's context when the browser returns to the body. Known synchronous
bodies keep the current same-dispatch order and use no fiber. Code with no
log slots and no task work must eliminate context capture and restoration,
as the old runtime already allows; this requires size evidence.

**Why an amendment is needed.** Today `directPure` checks the whole init
body in `src/js/Lower.zig`; the shared browser constructor makes it impure
through its context capture. The original assertion that a shared browser
constructor is inert and pure is false. This cannot be solved by merely
moving files or ignoring the inferred effect.

Approved amendment: a prerendered `Tea.element` / `document` /
`application` init has a pure initial-model computation and a staged
command result. The compiler proves the split before emitting either tree:

- Every app expression evaluated to compute either result, all eager
  command arguments and all values captured by deferred bodies retain the
  ordinary purity check. `stamp = Time.now ⊤; Cmd.perform (...)` is refused
  at `Time.now`, even if only the command uses `stamp`.
- Only a recognized platform-owned command construction has a client-only
  metadata step: the existing `Hosted.job` log-context capture. Recognition
  uses resolved declaration identity, not a textual `Cmd` module name.
  Its input body is constructed from checked pure captures; its body is
  deferred. Arbitrary impure functions returning `Cmd` are not exempt.
- In the prerender tree, emit the checked initial-model computation and
  eliminate the command construction and its client-only metadata step.
  Do not run the shared constructor and discard its result afterward.
- In the client tree, construct the command once at its source position,
  including the normal context capture, then run it only after hydration's
  first write pass. The metadata result cannot influence the initial
  model, view, route list or data conversion.
- If the analysis cannot prove that separation (a command is inspected to
  choose the initial model, an opaque helper hides construction, or shared
  flow could expose metadata), refuse it as a compiler limit. Never slice
  away an arbitrary effect because its value appears unused.
- View, routes and data conversions retain the existing full purity rule.
  No host operation, such as clock/DOM/random/HTTP/GPU access, receives a
  staging exception. Merely returning an effect's result as a command
  field does not make it client-only.

This introduces an explicit phase-aware init proof, not a change to the
checker's effect bits. It is reflected in `prerender.md` §3.1. Extend the lowering interface
where the staged proof needs to cross it, before dependent lowering code.
Do not invent a pure capture annotation.

### 4.3 Focused fixture contracts for the two boundaries

These are exact acceptance scenarios to review before implementation.
Source drafts for the init and command-context cases are local under
`zig-out/scratch/contract-fixtures/`; the guarded-reader regression already
exists in the corpus. These are not recorded test results. Reuse current corpus cases where they
already express the assertion; add missing variants alongside them.
Goldens come from real runs, never handwritten predicted transcripts.

| Fixture | Source/driver contract | Required observation |
|---|---|---|
| `inline/ThrowingRead` (existing) | `Sub.on Push Broken.pushes Pushed`; private platform `Broken.pushes` calls `Listen.on` with a reader that logs and calls a missing host method; two events | First reader throw stops the program; second event neither reads nor sends; dev crash screen/release stop unchanged |
| `inline/BaseEntryNested` (new) | Reader logs `read:1`, synchronously fires a second event, then sends; second reader logs `read:2`; update logs its payload | Both reads happen during native dispatch; nested sends drain in their actual send order, after the reader returns; no reentrant update |
| `inline/BaseEntryRestore` (new) | Test platform installs listener A under entry A; inside A's registration installs B under entry B, then listener C; fire A/B/C after registration | A and C use entry A, B uses entry B; all decode inside their entry; registration failure restores the prior entry via finally |
| `inline/BaseEntryReaderStop` (new) | Reader stops its program, dispatches another event and throws before sending | Later event does not run another reader; all removers run once; original defect is propagated |
| `inline/CommandInLogScope` (enable existing refusal as a page) | An update arm uses `Log.annotate "request" "r1"` to return `Cmd.perform`; body logs then sends `Reply`; Reply update logs | Body line carries request=r1; Reply update does not; synchronous body runs after the model write, without a fiber |
| `prerender/BaseInitCommand` (new) | Pure init returns `(0, Cmd.perform (λsend → send (Loaded (Time.now ⊤))))`; view renders the integer | Build succeeds without executing clock/body; generated initial HTML has 0; client runs the body after takeover; CSR and hydration transcripts agree |
| `prerender/BaseInitEagerClock` (new refusal) | Init binds `stamp = Time.now ⊤` and captures stamp in that command, returning a constant model | `prerender_impure` at the eager clock call, no Node start and no output |
| `prerender/BaseInitOpaqueCommand` (new refusal) | Init obtains its command by an app helper with a host read before it returns `Cmd.perform` | Refuse the host call, or a documented compiler limit if construction cannot be separated; never accept by return type alone |
| `tea/LogContextAfterReportedThrow` and synchronous `Soon` twin (existing compatibility) | A captured command focuses an element whose update annotates and throws; body then logs | Body's request context survives the reported nested defect; update has program context |

Use local fixture platform probes for entry registration and cleanup, not
new public APIs or broad host catches. `BaseInitCommand` must also build
under a test PATH that detects an accidental browser capability access in
Node. Inspect the prerender tree's roots and the client emit shape so a
passing final DOM cannot conceal build-time body execution. Deferred
sleep/HTTP/GPU variants join their enabling slices, not this contract step.


## 5. Purity and realms

All operations that access browser state are impure (or suspending).
Moving their module changes no effect rung and grants no build-time
browser. `Time.now`, `Dom.box`, event state, random sampling, HTTP and GPU
acquisition are refused from prerender `init`, `view`, route computation
and data conversions, including through helpers, constants and dispatch.
The refusal must name the call, with no output written and no Node run.

Pure helpers stay pure: `Time.millis`, deterministic random generators,
descriptor construction and inert command/subscription descriptions do
not read the host. Declaring every value of a capability module impure
would reject legitimate pure programs and deferred init commands.

The client and prerender trees have independent reachability. Merely
importing GPU or declaring an init command must not evaluate `document`,
`navigator.gpu`, a timer or a subscription during prerender module loading.
Keep host reads inside operations, never newly introduced module constants.

`webgpu.md` §2.3's realm rule survives the move: GPU engine code remains
headless; Window-only element intake stays separate and independently
eliminated. This work does not broaden worker availability or move worker
entry descriptors into the base. GPU absence is its existing typed outcome;
a GPU acceptance test must also exercise actual device success on a real
adapter, rather than pass solely on absence.

## 6. Evidence required before and after implementation

No measurements or new test results are claimed by this document. The
architecture and §4 contracts are approved for local slices. The previously recorded zorg build prerequisite is being repaired locally
so these slices can be validated. Baseline and
after measurements are required before an implementation slice is complete.

Use the same compiler mode, Node version and compression procedure for
both trees. Save commands, source identities, output hashes, raw bytes,
brotli quality 11 and gzip level 9 sizes under `zig-out/scratch/`; put the
comparison in the approved design and eventual PR. Measure:

- An empty inline `Tea.sandbox` page and an empty `Tea.element` page with
  `Cmd.none` / `Sub.none`, including their prerendered variants.
- A routing TodoMVC built with inline, from a fixed source that already
  builds before the extraction. `bench/size.mjs`'s current TodoMVC entry
  targets `browser-tea`; it is not an inline baseline. If the real inline
  TodoMVC cannot build on the baseline, report the exact limit first.
- A direct synchronous command page, timer/HTTP page and GPU page to show
  which capability and task code becomes reachable.

Acceptance: no raw, brotli or gzip growth on capability-free inline pages;
no Task or GPU runtime retained there; no new per-write runtime branch.
Existing inline emit goldens should remain unchanged except justified
module ownership/path changes in development output. Inspect all changes.

Black-box fixtures must fail before the enabling slice and pass after it:

| Fixture group | Observable assertion |
|---|---|
| Prerender plus `Time` | Initial HTML is deterministic; init sleep/timer work starts only after hydration; tick updates page; stop clears work |
| Prerender plus `Dom` | Deferred focus/measure sees the hydrated nodes; after-render work sees the updated page |
| Prerender plus `Http` | Browser sends to a local fixture server after takeover; success and typed failure render; cancellation blocks stale replies |
| Prerender plus `Browser.Events` | Resize/key events and animation frames update the page; one frame clock; listener removal and reader defects stop correctly |
| Prerender plus `Gpu` | Hydrated canvas obtains a real device, configures/presents and cleans up; absence remains separately tested |
| Deferred work and logging | No host work runs under Node; nested update log context reaches its command, reply update has program context |
| Purity refusals | Init/view/routes/conversions call each host family directly and through helpers; full `prerender_impure` diagnostic at the call; no partial output |
| Shared effects | Shared nominal types compose across modules; keyed policies, duplicated keys/taggers, cancellation, stale callbacks and model-dependent subscription changes retain their contracts |
| Compatibility and determinism | Existing `tea/`, `dom/`, inline and prerender transcripts; one/eight-job byte equality including pages |

Run page fixtures in happy-dom where supported and in headless Chrome;
GPU success uses the real-adapter GPU harness. Compare prerendered and
`--no-prerender` transcripts. Do not emulate GPU to claim real device
coverage. Full zorg gates and `test-browser` are required per approved
code slice; GPU integration also runs `test-webgpu`. Keep exact failures
in logs, not a rerun to discover the failure text.

## 7. Approved sequencing and local review boundaries

1. Record the approved architecture and guarded-entry/log-context
   contracts, including focused fixtures. This review completed on
   2026-11-09; dependent implementation is authorized locally.
2. Extract the renderer-free base and capabilities, retaining today's
   inline subscription limits as explicit compiler limits. Compile shared
   synchronous commands/listeners and scoped suspended command work where
   needed for Time/Http/GPU. Preserve existing browser behavior. Move
   navigation host operations and GPU/media families with their generator
   destinations and public re-exports. Split these changes into locally
   green commits with measurements and focused acceptance fixtures.
3. The next functional slice supplies full keyed policies and
   model-dependent subscription sets before the site depends on them.
   Until it lands, describe the capability APIs as incomplete.

Each implementation slice needs the appropriate generated API/skill
updates, size evidence, tests and diary entry. Work remains on
`browser-base`, with local commits only. No issue, PR, comment or push
is authorized until the manager says so.

## 8. Owner approvals — 2026-11-09

The manager relayed the owner's answers on 2026-11-09:

1. **Yes:** `browser-base`, renderer-free, with the chain in §2.
2. **Yes:** one shared `Cmd`/`Sub`. Settle guarded-entry and log-context
   contracts in this document with focused fixtures, and show the manager
   before building on those contracts. §4.1–§4.3 are that review submission;
   the owner subsequently approved the init phase proof, and the manager
   approved the entry and fixture contracts, on 2026-11-09.
3. **Sequence it:** first move capabilities with today's subscription
   limits stated as compiler limits. Model-dependent subscription sets and
   full keyed policies are the next slice, before the site depends on
   them. Do not claim the capability APIs complete until then.
4. **Yes:** navigation facades over a shared private base module.
5. **Yes:** workers stay outside this extraction.

The manager authorized local implementation slice by slice and local
commits on `browser-base`, reporting each slice. Nothing goes to GitHub
until separately authorized.

Binary HTTP responses, new scroll/wheel/touch/pointermove events,
`animationend`/`focusin`, observers, media queries, device pixel ratio,
SVG geometry and a monotonic clock remain outside this work.
