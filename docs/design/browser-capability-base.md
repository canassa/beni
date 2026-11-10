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


## 9. Implementation ledger

### Renderer-free package and listener-entry foundation

The first local implementation provides the `browser-base` manifest and
its `Listen` module. Existing renderer chains still use their original
listener modules; the base becomes their dependency when those duplicate
modules are removed together. No shared Cmd/Sub or capability-family move
is claimed by this foundation.

`Listen.withEntry` selects a synchronous registration entry and restores
it with `Js.finally`. `Listen.callback` captures that entry once and runs
both reader and send inside it. `on` and `on2` use that helper. Registration
stores the checked function as `Js.Value`: `sync` is an argument marker in
a top-level annotation, not a property permitted inside a type alias or
on a returned function type. `withEntry` spells the checked function type
out; the callback applies the stored entry synchronously over `Js`.

The `run/BrowserBaseEntry` fixture uses the host's real EventTarget. It
checks nested entry selection, restoration after an exact recognized
registration exception, captured entry identity after scopes return, the
unbound direct mode, and listener removal. It failed before the package
existed, then passed in development and release. The fixture also checks
restoration after a specifically recognized registration exception.

Release JavaScript for four capability-free pages is byte-identical before
and after this foundation (Node 24.19.0; brotli quality 11; gzip level 9):

| Page | Raw | Brotli | Gzip |
|---|---:|---:|---:|
| Empty sandbox | 498 | 271 | 331 |
| Empty element, no command/subscription | 498 | 271 | 331 |
| Prerendered empty sandbox | 1882 | 881 | 981 |
| Prerendered empty element | 1882 | 881 | 981 |

Sources, hashes, command script and results are under
`zig-out/scratch/size/` and `zig-out/scratch/measure-base.mjs`. These figures
are JavaScript only; they do not include HTML or source maps. The existing
TodoMVC source fails its inline baseline because `Dom` and `Storage` are
not present. No browser-tea number is substituted. The extraction still
owes a real inline TodoMVC comparison after its compiler limits are known.

Full validation on 2026-11-09 used zorg 0.17.1+zorg.3, without the
temporary equality patch in either worktree, against clean master
620c322a45 with the same default build mode and Node 24.19.0. Gates have
identical failure identities: six ownership golden mismatches, two
ownership CPU budgets and two APFS case-folding tests. Chrome passes
744 of 745 cases on both; only the existing `tea/DomCapabilities` golden
mismatch remains. The separate driver settle repair makes HttpDefect
pass. No golden or timing budget changed. Exact comparisons and logs are
under `zig-out/scratch/foundation-final-*-comparison.json` and
`foundation-{repair,master}-{gates,browser}.log`.


### Shared listener selection and inline guarded registration

Both renderer manifests now depend on `browser-base`; their duplicate
`Listen` modules are removed in the same slice. Legacy browser listeners
retain the base's direct entry and their existing fiber/relay queue rules.
Inline's mount installs each subscription inside `Inline.subscribe`, which
selects the entry through `Listen.withEntry`. Each listener retains that
entry after installation. Stopped callbacks do nothing; nested callbacks
run their readers synchronously inside the active guard. An outer event
enters the guard and drains queued sends after its reader returns.

`browser/inline/NestedBaseEntry` dispatches a second native event while
reading the first. Its unchanged expected transcript requires both readers
to return before updates, retaining the sends' actual order (2, then 1).
It first failed against the old inline listener, then failed behaviorally
with shared listeners but no entry binding: updates preceded reader returns.
With the binding it passes development and release. Existing inline
throwing-reader and stop fixtures pass, as do the targeted inline and TEA
Node corpora. Ownership helper bodies are pinned, and generated interfaces
point readers to the shared package. Final full validation and accepted
byte measurements are recorded below.

No command, capability family, navigation or GPU module moves in this
slice. The shared Cmd/Sub and full subscription-policy work remain ahead;
the capability APIs are incomplete.


The manager required the timer-only builds to pay no unused registration
context before the owner reviews listener growth (2026-11-09). The lowering
names its platform's capture helper in `Lowering.Effects.entry_capture`;
source reachability supplies `Program.Subscription.entry`. When the helper
is unreachable in the build, subscription starts are emitted without the
registration wrapper, and its context is eliminated. This proof is
build-wide and conservative: mixed or uncertain starts keep the guard.
It does not special-case timer names, fixture paths or host APIs. The
existing MainOwnedKeys and RootClosures emit goldens are the red-before
fixtures and must match unchanged after this refinement.


The owner accepted the listener growth on 2026-11-09, relayed by the
manager: guarded pages add 36–52 Brotli bytes; empty and timer-only pages
must remain byte-identical to master. Fresh post-refinement captures of all
16 fixtures confirm the 14 guarded outputs are unchanged from the reviewed
build and the two timer-only outputs exactly match their original goldens.
Only those 14 accepted emit goldens were regenerated from the fresh real
runs. The manager authorized final same-toolchain gates/Chrome comparison
and a local commit if no new failures remain. Captures, commands, hashes
and the exact regenerated-file manifest are in
`zig-out/scratch/listener-approved-review/`.


Final validation on zorg 0.17.1+zorg.3 and Node 24.19.0 used the same
default mode against clean master 620c322a45. Gates have exactly the same
known failure identities, with no new failures. Chrome has no new lane
failure: lane passes 745/746 (only `tea/DomCapabilities`); master passes
742/745 (that case plus baseline-only `dom/ScriptedFetch` and
`managed/Network`). Neither final gate run hit the earlier runner timeout.
All four empty-page variants and both timer-only fixtures remain
byte-identical to master. The 14 guarded fixtures retain their reviewed
outputs (+39–52 Brotli bytes after timer-only costs are removed).
`zig-out/scratch/listener-accepted-report.md` holds the complete size table,
commands, original logs and exact comparisons. Only the 14 accepted emit
goldens were regenerated from real runs; no other golden or budget changed.


### Time and page events — built 2026-11-10

The manager accepted listener commit `7cbf44842` and ordered capability
families in site order: Time/events, Dom, GPU/image/canvas, Http, navigation
host operations, then Storage/WebSocket/Random. The Time/event family
includes the shared Cmd/Sub/Hosted prerequisites and scoped inline tasks;
Time.every retains its existing Sub.listen clock/fiber semantics. Native
frame callbacks enter the shared captured boundary. Static subscription
sets remain the compiler's current limit. Only unkeyed perform/none/batch
commands are initially analyzed; full policies/model-dependent sets still
follow before site use.

Before implementation, BaseTimeEvents and BaseInitCommand failed missing
Time/event capabilities; CommandInLogScope failed the existing compiler
limit. Exact commands and outputs: `zig-out/scratch/time-fixtures-before.json`
and `time-before-*.log`. Init command staging and log-context boundaries
remain subject to §4.2–4.3's already approved contracts, with no host-read
purity exemption. No release field-order issue has been encountered; any
such case must be reported, not rewritten around.


Time implementation now includes the staged-init structural proof: inline
and local named init functions may return a pure model paired with canonical
none/perform/literal batch construction. The prerender tree omits only that
metadata and preserves eager argument evaluation. A diagnostic-only walk
finds eager host reads through app helpers; it cannot authorize any split.
Metadata inspected to choose the model remains a compiler limit. Real
fixtures cover named init, nested batches, eager clocks, opaque helpers and
model inspection. A Node preload refuses Date.now and browser globals during
the prerender build in both development and release.

Scoped cancellation must still let a cancelled fiber run its finalizers
after the page closes. Dropping its scheduler turn stranded Task.onExit;
TimeCleanup first showed the missing release and now records it exactly
once, with no timer or late message after stop. Shared Hosted's asserted
ownership send rows move with its defining package: TaskWords mutation
checks exposed the missing selection before that repair. Validation and
measurements for the family remain in progress; no completion is claimed.


### Unused update context — reachability proof

The first Time comparison found extra update IIFEs after the context state
was eliminated. The existing timer and empty-page fixtures are red-before
evidence; their bytes must return to master. Interface 1.28 adds a lowering
description of the functions that can write its update-context or finalizer
state (`Effects.update_writers`) and a conservative `Program.update_context`
fact. A dependency names its defining core/platform module and declaration,
including a private helper; reexports do not change that identity.

Inline names Task's five writers: withClock, withLogContext, withScheduler,
addFinalizer and cleanupFiber. These are every write of Task.slotted and
Task.finalising. If source reachability reaches none of them, updates need
no context bracket and the lowering writes the handler directly, without a
wrapper. Missing declarations or an absent description keep the bracket.
Mixed builds keep it for every update, including a synchronous reply to a
command. This is a build-wide proof of absence of writes, not a test of the
current state before an update: an update may itself add slots/finalizers.
Retain the log-context, async reply and defect fixtures when exercising it.


The task scope's defect cleanup is installed lazily as a callback when the
first task root is created. A task-free page's generic defect boundary calls
no callback while its cleanup slot is null, so it never reaches the Task scope machinery
through cleanup. This preserves cancellation on a defect while avoiding
unneeded task code and its effects on whole-program specialization. The
empty-prerender +5 raw/-1 Brotli snapshot is the failing size evidence; the
stop and reader-defect finalizer fixtures must remain correct.


### Log-scope command acceptance — 2026-11-10

The owner accepted LogScopeInUpdate's +205 Brotli release bytes for the
shared Cmd creation-context contract. The #1003 refusal is removed:
CommandInLogScope is a page, including synchronous and waiting bodies,
record and swapped result forms. A body retains its creator's context;
reply updates use program context. Record the accepted emit from a real
build exactly matching the reviewed output. SubListen remains pending
the owner's decision and is not changed by this approval.


SubListen owner decision, 2026-11-10: lift the zero-field tagger limit. A
constant constructor calls its handler without arguments; preserve the 2+
field refusal and give remaining field-count mismatches their own accurate
counts. Validate CSR/prerender, development/release in happy-dom and Chrome;
keep empty and timer controls byte-identical.


Time/events final validation (2026-11-10): all four empty variants and both
native timer controls are byte-identical to clean master. Log-scope command
creation and zero-field subscription taggers are owner-approved and built.
SubListen's true red-before source uses an ignored message; all four
CSR/prerender × dev/release variants pass happy-dom and Chrome after the fix.
Time.every retains constant intervals and shares equivalent timer keys.
Chrome has only the same known DomCapabilities failure on lane and master.
The final full gate's chat transcript mismatch was followed by the manager's
required uncached repetitions: 10/10 lane and 10/10 clean master, identical
rates, with the original failure preserved. Known baseline gate failures
remain; no budget/guard or chat golden changed. Exactly approved existing
emit/ownership goldens were recorded from actual outputs. Full scoped-policy
and model-dependent subscription APIs remain incomplete; next capability
family is Dom. Evidence: zig-out/scratch/time-final-report.md.


### Dom — built 2026-11-10

`Dom` moves to `browser-base` whole, removed from `browser` in the same
slice and re-exported by `browser`, `browser-inline` and (through `browser`)
`browser-tea`. It imports no renderer. §3's render-phase boundary is the
base's private `Phase` module. It owns the state `Browser` held for the
hosted loop — the loop's flush, the after-render phase, its queued work,
its waiting fibers and the busy latch — behind functions, so every cell
stays module-local and a release build keeps it a `let` (`backend.md`,
*A `Js.Ref` that does not escape is a `let`*). `Browser.hosted` hands its
loop to `Phase.mount` and queues work through `Phase.after`; `Dom.rendered`
and HTTP's after-render wait call `Phase.rendered` / `Phase.onRendered`.

Inline installs nothing. It writes the page inside the dispatch, so its
after-render point is the end of that dispatch. A fiber's turn runs in the
scheduler's drain, which `Task.onTurn` wraps in one dispatch, so
`yieldNow` would resume it before the page is written. With no hosted loop
mounted, `Phase.rendered` therefore resumes from a microtask, after the
drain has returned. This is the default when no renderer supplies a loop.
A page that does not wait for a render reaches none of this code.

Interface 1.29 adds `Lowering.Effects.after_render`: the write-set pass
reads `Cmd.afterRender` as a body that cannot suspend. The inline runtime
queues it after the write pass as such a `perform` is queued, through
`Hosted.callLater`. A prerendered `init` may return it, staged as
`perform` is (§4.2). Its body runs only on the client. Keyed commands
remain a compiler limit.

Before: `browser/prerender/BaseDom` and the refusals
`build/bad/prerender/BaseDomInView` and `BaseDomInInit` failed with an
unknown module `Dom` (`zig-out/scratch/dom-before/`). After: BaseDom passes
in all four builds (development and release, prerendered and not) under
happy-dom. Its load step focuses and measures the hydrated input from
`init`'s `Cmd.afterRender`. "edit" focuses an input its update showed.
"open" waits with `Dom.rendered` in a fiber, then focuses. "missing" is
`Err (NotFound id)`. The first `Dom.rendered` attempt, a scheduler yield,
failed "open" with `NotFound second`; that failure fixed the microtask
wait. Both refusals are `prerender_impure` at the host read inside `Dom`,
with no output written.

Sizes (release JavaScript, Node 24.19.0, brotli 11, gzip 9): the four
empty-page variants are SHA-identical to master 620c322a45 (498/271/331 and
1882/881/981), and so are both timer controls (MainOwnedKeys, RootClosures).
The seven inline command and time pages — CommandInLogScope(+Async),
SuspendingCommand, BaseInitCommand, BaseInitBatchCommand, TimeCleanup,
BaseTimeEvents — are byte-identical to the Time commit e9996a71ca. Inline
emit goldens are unchanged. Four `browser-tea` release goldens move by
module order and short-name assignment only, pending manager review:

| Golden | Before raw/brotli/gzip | After |
|---|---:|---:|
| WindowSize | 3688/1551/1785 | 3694/1551/1784 |
| DomCapabilities | 5064/2166/2440 | 5070/2169/2439 |
| HttpSendTracked | 19098/7136/7886 | 19094/7141/7889 |
| HttpSendUntracked | 12547/4868/5399 | 12553/4894/5410 |

The inline TodoMVC still needs `Storage`, so it is not measured yet.
Evidence: `zig-out/scratch/dom-*`.

Final validation (2026-11-10, zorg 0.17.1+zorg.3, default mode, Node
24.19.0, against clean master 620c322a45, run one after another). Chrome:
the lane and master fail the same single case, `tea/DomCapabilities`. Gates:
the same known failures on both (six ownership golden mismatches, the two
APFS case-folding tests, the list-column CPU budget and two own2 tests).
Two more CPU-budget overruns appeared only in the lane run:
`obligations: equatable, interpolatable and tuple_index` (1135 ms) and
`the arity rule of §8.3 …` (1048 ms), against a budget of 1000 ms. This
slice changes no checker code, and both tests pass alone afterwards. The
manager accepted the four `browser-tea` release goldens above, and they
were recorded from a real build. Comparisons:
`zig-out/scratch/dom-final-{gates,browser}-comparison.json`.


### Gpu and media — built 2026-11-10

The whole WebGPU family moves to `browser-base`, with its private
dependencies: `Gpu`, every `Gpu.*` module (`Gpu.Engine`, `Native`, `Memory`,
`Make`, `Session`, `Commands` and `Formats` included), and `Browser.Canvas`,
`Browser.Image`, `Browser.Video` and `Browser.Source`. They are removed from
`browser` in the same slice. None of them imported a renderer, so no source
changed. The base, `browser` and `browser-inline` re-export the public list
that `browser-tea` already published. `src/native/Gpu.zig` writes the
generated modules to `platforms/browser-base/Gpu`. The binding staleness
check, the public-signature check, the coverage gate, `fmt-exempt.txt`, the
P-sync list and the word-body pins follow the files. The typed host bindings
stay in core.

Private engine modules are now private to every renderer. A direct `browser`
program could import `Gpu.Engine` before, as the debt of #2256 recorded
(`browser/dom/GpuEngineReachable`). That page is replaced by the refusals
`build/bad/managed/GpuEngineHidden` and `build/bad/inline/GpuEngineHidden`,
beside the existing `tea` one.

Fixtures. `browser/prerender/BaseGpu` is a prerendered inline page. Its
`init` returns a command that finds the hydrated canvas, configures it,
presents one frame, reads the pixel back, unconfigures the canvas and
destroys the device, then reports the loss. "again" repeats it on the same
canvas node. With no adapter (happy-dom, Chrome under `--disable-gpu`) it
says "unavailable": this is the gates' transcript, `_expected.expected`, in
all four builds. The precise absence stays covered by `browser/gpu/Availability`.
`build/bad/prerender/BaseGpuInView` (`Gpu.available` in `view`) and
`BaseGpuInInit` (an eager `Gpu.preferredCanvasFormat` in `init`) are
`prerender_impure` at the host read in `Gpu.Engine`. All three failed before
the slice with an unknown module `Gpu` (`zig-out/scratch/gpu-before/`).

`_expected.webgpu`, the marker added for this page, puts a `browser/prerender/`
project into the `test-webgpu` walk. There all four builds compare against
`_expected.webgpu-expected`, which a blessing `test-webgpu` run writes from
the first build. `test-webgpu` cannot run on this Mac. *Done 2026-11-10 on
dagon:* a blessing `test-webgpu` run there recorded the golden, and a
second run verified it in all four builds on Chrome 153's SwiftShader
adapter. `browser/gpu/` gives 133 of 134 on the branch and on master, with
the same `CancelledRequests` timing flake on both; it passes alone on both.
The `_expected.webgpu` marker works. An exploratory run outside the
harness in Chrome 157 with `--enable-unsafe-webgpu` on Apple's Metal adapter
gave, in development and release: configure Ok, one receipt, the pixel
4294901760 (blue, as `browser/gpu/CanvasPage`), loss `Destroyed`, twice. It is
evidence, not a golden.

`Gpu.Device.onEvent` keeps inline's existing limit: the device is part of the
model, so the subscription set depends on the model (`not_implemented`, class
1). `eachEvent` in a command works.

Sizes (release JavaScript): the four empty-page variants and both timer
controls are SHA-identical to master. The eight inline pages of the earlier
families (BaseDom included) are byte-identical to the Dom commit 2cabfd1426.
No emit golden changed. BaseGpu's release page is 58258 raw / 16815 brotli /
18958 gzip.

Final validation (2026-11-10, zorg 0.17.1+zorg.3, default mode, run one
after another against clean master 620c322a45). The gates fail the same set
on both sides. Chrome: the lane failed `managed/Network` once, with an
`ECONNRESET` in the Node test server. Master failed `tea/HttpResults`, and
it failed `managed/Network` in an earlier slot. Run alone with no run-hash
cache, `managed/Network` passes three times in three on the lane. Otherwise
both sides fail only `tea/DomCapabilities`. Comparisons:
`zig-out/scratch/gpu-final-{gates,browser}-comparison.json`.
Still owed on dagon (`test-webgpu`): the first real run of BaseGpu, which
writes `_expected.webgpu-expected` and checks all four builds against it;
the `_expected.webgpu` walk and golden path itself; and the 134
`browser/gpu/` pages on a real adapter after the move.


### Http — built 2026-11-10

`Http` moves to `browser-base` whole and is removed from `browser` in the
same slice. It has imported no renderer since the Dom slice: its
after-render wait calls `Phase.onRendered`. The base, `browser` and
`browser-inline` re-export it, and `browser-tea` does through `browser`.
The binary response (#1887) is not part of this family.

Fixtures. `browser/prerender/BaseHttp` is a prerendered inline page. Its
`init` command asks for `/api/greeting`. The build sends nothing; the page
sends it after the takeover. The driver's scripted `fetch` answers it.
"missing" is `Err (BadStatus 404)`, "offline" is `Err NetworkError`, and
"save" is `Http.send`, the command form, posting a text body. Each
outcome renders as a value, and all four builds share one transcript.
`build/bad/prerender/BaseHttpInView` and `BaseHttpInInit` call `Http.get` in
`view` and eagerly in `init`. Both are refused at the call as
`suspending_callback`: a request suspends, and `view` and `init` are
synchronous callbacks. The checker refuses this before the prerender
check, so the code is not `prerender_impure`. All three failed before the
slice with an unknown module `Http` (`zig-out/scratch/http-before/`).

Not covered yet, and owed to the next functional slice (§7 step 3):
cancellation that blocks a stale reply. It needs `Cmd.keyed` `Restart` or
`Cmd.cancel`, which remain inline compiler limits. `Http.track` on inline
is a static `Sub.on` and has no inline fixture yet.

Sizes (release JavaScript): the four empty-page variants and both timer
controls are SHA-identical to master. The nine inline pages of the earlier
families (BaseDom and BaseGpu included) are byte-identical to the Gpu commit
fdbdfb5005. One emit golden moves and is not regenerated pending manager
review: `emit/release/tea/HttpSendTracked`, 19094/7141/7889 → 19100/7145/7891
raw/brotli/gzip. One helper is inlined at its call site and two declarations
are reordered; the key identity string `platform:Http.Key` is unchanged.
BaseHttp's release page is 13751/5153/5720.

Final validation (2026-11-10, zorg 0.17.1+zorg.3, default mode, run one
after another against clean master 620c322a45). The gates fail the same set
on both sides. Chrome fails only `tea/DomCapabilities` on both. The manager
accepted the `HttpSendTracked` golden, and it was recorded from a real build.
Comparisons: `zig-out/scratch/http-final-{gates,browser}-comparison.json`.
