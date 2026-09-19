# The JavaScript boundary — platforms, ports and `foreign`

**Status:** normative for M3, and the input M4's cache key needs. [`fast-compiler.md`](fast-compiler.md)
§3.1 settles that the language is pure with effects as values interpreted by a platform, and its
header states the stance this document implements: *Elm's walled garden, better equipped.*
[`research/13-the-javascript-boundary.md`](research/13-the-javascript-boundary.md) is the evidence
base; where this document asserts something without argument, that report has the citation.

The wall is not negotiable and nothing here relaxes it. **User code cannot call JavaScript.** What
this document does is make the interior richer, and give the privileged code that furnishes it the
mechanical checks Elm never had.

## 1. What the evidence settled before this document starts

Across fourteen compilers targeting JavaScript, **not one reads the JavaScript it binds to**, and no
shipped design lets user code call JavaScript while keeping the no-crash guarantee. Every mechanism
that is a *call* gives the guarantee up. Ports keep it structurally, and they are the efficient
frontier of what ships. Elm was right about the boundary.

What the evidence does *not* support is the three restrictions Elm stacked on top of ports, and each
one is why a capability you would expect to exist does not:

| Restriction | What it actually is | What it costs |
|---|---|---|
| Only the core team may write privileged code | `isKernel` compares the package author against two GitHub organisation names | Also gates `effect module`, so nobody else can ship a new *kind* of effect even in pure Elm — which is why `localStorage` has no package |
| Ports carry a fixed list of types | `checkPayload` is a hardcoded whitelist; the codec is *generated from the declared type* | An ADT is trivially codec-able and is excluded only because the generator was never generalised |
| Ports are the only route | — | The recommended payload, an opaque JSON value, compiles to `identity` with no validation at all |

None of Evan's four stated reasons for the author restriction — reliability, portability, security,
code size — is a property of *who wrote the code*. Each is a property of what the code does, how it
is distributed, or what it compiles to. That is the opening this document walks through.

## 2. Three privilege levels

| Level | Who | May write |
|---|---|---|
| **Ordinary module** | anyone | no `foreign`, no port declarations, no platform entry point |
| **Platform package** | anyone, by declaring itself one in its manifest | `foreign` values, hosted effects, the `Program` type and `main`'s shape |
| **Core** | this repository | the same as a platform package; core is simply the platform-independent one |

**Privilege is a role with a checked contract, not an author list.** A platform package is an
ordinary package that anyone may publish; what makes it privileged is a manifest key, and what makes
it *safe* is §4's checks, which Elm does not perform. The security argument moves from the compiler
to distribution — which is where it already rests in every other language in the survey, Elm
included, since a whitelisted author is a distribution fact wearing a compiler's clothes.

`foreign` in an ordinary module stays `foreign_outside_core`, renamed to `foreign_outside_platform`
now that core is not the only privileged package.

## 3. Two routes out, and neither is a call

User code reaches the outside world two ways, and the distinction is worth stating because Elm has
only the second and Roc only the first:

- **Calling an effect a platform provides.** `Http.get : Request -> Task Error Response` is an
  ordinary function the platform declared `foreign` at effect type (§4, shape (b)). This is Roc's
  shape and it is the ergonomic path: no message plumbing, no correlation, just a `Task`. It is
  bounded by what the platform author thought to offer.
- **Declaring a port.** When no platform offers what you need, you declare the port yourself and
  the compiler generates the codec from the type you wrote. This is Elm's shape and it is the
  escape hatch — the thing Roc has no equivalent of, where an app whose platform lacks a capability
  is simply stuck.

Neither is a call into JavaScript. Both produce values, which is what keeps §7.2's purity argument
intact. The first is bounded by the platform's imagination, the second by the codec generator, and
having both is why the garden can be richly furnished *and* still have a way out.

### 3.1 Ports

Ports stay, and stay asynchronous.

**The payload widens to any type the compiler can generate a codec for.** This is the change that
removes the most-cited friction without touching the safety argument, because the safety comes from
*generating* the codec, not from the list. Admitted: everything Elm admits, plus **ADTs and records
of admitted types**, which are a closed set of constructors with known argument types and therefore
trivially encodable. Still refused, for reasons that really are about safety: functions, type
variables, extended records, and anything containing a foreign type.

**The generated decoder carries a depth bound.** Machine-generated deserializers are themselves a
crash site — the report cites stack-exhaustion advisories against generated decoders in two other
ecosystems — so a decoder that recurses past the bound fails as a value rather than as a stack
overflow. This is the same discipline as the checker's guards: report, never poison silently.

**Ports stay asynchronous and no synchronous variant is added.** A synchronous call means a foreign
frame on the beni stack, a throw landing in the middle of `update`, and host callbacks into user
code, which is the one failure class nothing can catch. The ergonomic complaint is real and the
answer is not synchrony but **correlation**: core ships the request/response layer that three Elm
community packages each had to rebuild, as a `Task`-shaped API over one port pair. The cost is one
frame of latency, permanently, and it is worth stating plainly rather than discovering.

### 3.2 What we take from Roc, and what does not transfer

The vocabulary is Roc's and so is the governance idea, but Roc's platform is a *separate program* —
usually written in Rust, Zig or C — that owns the entry point, the memory allocator and the host
process, with the Roc code embedded inside it. beni owns none of those; V8 does. So a beni platform
is a package of beni plus its sibling JavaScript, not a host, and the boundary is far thinner
because both sides run in one runtime: Roc's platform boundary is a foreign-function interface to
native code, ours is a module import.

| Roc concept | Here |
|---|---|
| Anyone may write a platform | **taken** — §2, and it is the fix for Elm's sparseness |
| The platform declares `main`'s type | **taken** — §5 |
| `hosted` declarations legal only in a platform | **taken** as `foreign`, §4 |
| The app calls platform-provided typed effects | **taken** — §3, the ergonomic path |
| The platform is a host program in another language | **not applicable** — V8 is the host |
| The platform owns allocation and the entry point | **not applicable** — same reason |
| No user-declarable escape hatch | **rejected** — ports are exactly that, §3.1 |

## 4. `foreign` in a platform package, and the checks Elm lacks

A `foreign` declaration binds to a sibling JavaScript file, one export per foreign value, under the
same name — already specified in `language.md` §5.4 and load-bearing for §7 below.

Four checks run at build time, and all four are things Elm does not do:

1. **The type must be one of exactly two shapes.** Either (a) a total pure function over
   already-admitted types, or (b) an effect value — `Task e a`, `Cmd msg`, `Sub msg`. The dangerous
   shape is a `foreign` that is neither: `foreign now : Float` would break dead-code elimination,
   common-subexpression reasoning, `lazy` chunk assignment and M4's split between a declaration's
   type and its value.

   **Corrected in M3a, twice.** An earlier draft said "all 65 of core's foreign values are shape
   (a)", which is false: `Basics.pi` and `Basics.e` are constants, not functions, and the rule as
   written rejected core itself. Worse, the rule is **unenforceable as stated** — `pi : Float` is
   indistinguishable by type from the `now : Float` it exists to refuse, and the type is all the
   compiler has. What the compiler actually checks is the property it *can*: a function, or a value
   of a variable-free type. That still refuses `foreign anything : a` and `foreign xs : List a`,
   and it is weaker than this section originally advertised. The rest is the recipe in §4.1 and
   review, not a check. `Debug.log` is the one deliberate violation, as it is in Elm.
2. **The sibling file must export exactly the declared names** — no more, no fewer.
3. **The sibling file's references must be covered by its own imports.** §7.1 explains why this is
   what keeps elimination declaration-granular. **This check is lexical and deliberately
   approximate**: doing it exactly needs a JavaScript parser, which is the dependency the wall
   exists to avoid. It catches what it exists for — a sibling reaching for a host global — and
   nothing finer. The free set is ECMAScript's intrinsics plus the web-standard common set of
   §5.1, derived from that section rather than from taste.

4. **The sibling export takes evidence count + declared arity parameters.** Since static dispatch
   (2026-09-18) a `pub foreign` may carry a `where` clause, and the evidence parameters of
   [`static-dispatch-spike.md`](static-dispatch-spike.md) §8.1 come FIRST:
   `core/List.beni`'s `eq : List a, List a -> Bool where a.eq : a, a -> Bool` is 2-ary in beni and
   is written `(m0, xs, ys)` in `core/List.js`. A `foreign` whose type is **not** a function binds
   to a value and not to a `() => …`, which is the other half of the same rule — `core/Basics.js`
   writes `pi` as `Math.PI`. The diagnostic is `foreign_arity_mismatch`, and it points at the beni
   DECLARATION, because that is where the expected count is written down.

   **Which export forms are accepted, and why the list is closed.** The parameter list must be
   written AT the export, so that a reader can count it against the declaration by eye and so that
   the compiler can count it without a JavaScript parser:

   | Form | Arity |
   |---|---|
   | `export const f = (a, b) => …` | 2 |
   | `export const f = a => …` | 1 |
   | `export const f = function (a, b) { … }` | 2 |
   | `export function f(a, b) { … }` | 2 |
   | `export { g as f }`, with `const g = (a, b) => …` in the same file | 2 |
   | `export const f = <anything else>` | a value, for a `foreign` that is not a function |

   A destructuring or defaulted parameter is one position like any other, because the emitted call
   fills positions. **Two forms are refused rather than guessed at**: an export that is a bare name
   (`export const f = g;`, or a re-exported import), which says nothing about how many parameters
   `g` has, and a **rest parameter** (`export const f = (...args) => …`), which has no fixed count.
   Both are legal JavaScript and neither appears in `core/` or `platforms/node`. Refusing them is
   the choice CLAUDE.md rule 6 asks for: a sibling is privileged first-party code, so a restriction
   on how it spells an export costs a platform author one line and buys a check that cannot be
   fooled. The fix is always the same — write the parameter list out:
   `export const f = (a, b) => g(a, b);`.

**A diagnostic points at the file whose text is wrong** (2026-09-19, queue slice 45). The four
checks compare two files, so each one has to say WHICH of them the author must edit, and the caret
is that answer. The scanner already knows the byte offset of every export, reference and specifier
it reads, so a fault in the JavaScript is reported IN the JavaScript — path, line, column and an
excerpt of that line — exactly as a fault in a module is reported in the module. It does not matter
that a sibling is not beni source, nor that its bytes came from the compiler's own assets rather
than from disk: `core/List.js` names `core/List.js`.

| Fault | Region | The other file |
|---|---|---|
| check 1, `foreign_bad_shape` | the `foreign` declaration | — |
| `foreign_sibling_missing` | the module's first `foreign` | named in the message |
| check 2, declared and not exported | the `foreign` declaration | named in the message |
| check 2, exported and not declared | the `export` name, in the `.js` | named in the message |
| check 3, `foreign_unbound_reference` | the reference, in the `.js` | — |
| check 4, `foreign_arity_mismatch` | the `foreign` declaration | named `path:line:col` |
| a relative `import` (`backend.md` §2) | the specifier, in the `.js` | — |

The split is not stylistic. **Where a fault concerns both files, the region is the beni
declaration, because that is where the promise is written**: a declaration with no export, and an
arity that disagrees, are both the module saying something the sibling does not honour, and the
edit that resolves them may be on either side. Where the fault is the `.js` file's alone — an
export nothing declares, a name from nowhere, a specifier that cannot be relocated — the module
is innocent and the caret must not be on it. All three of those used to land on the module's FIRST
`foreign` declaration, an arbitrary line chosen only because it was the one the check had a token
for.

**This rule was documented and unenforced for one day and is now check 4** (2026-09-18, queue slice
4). While it was unenforced a sibling that forgot its leading evidence parameter built cleanly and
failed at run time — the `List.eq` shape above, with the evidence function arriving where the first
list belonged, compares nothing and answers `false`. That was a real widening of the `foreign`
surface against CLAUDE.md rule 6, taken knowingly and now closed. The alternative the adoption
recorded — refusing `where` on `foreign` and giving `List` an uncons primitive to write `eq` and
`compare` in beni over — is not taken, and the third possibility it feared, a JavaScript parser, is
not needed: the check reads the parameter list lexically, exactly as check 3 reads imports, and
refuses the forms that reading cannot settle.
[`research/19-static-dispatch-spike-results.md`](research/19-static-dispatch-spike-results.md) §14
item 2 is discharged.
→ [`static-dispatch-spike.md`](static-dispatch-spike.md) §5.2, A.7, A.84.

### 4.1 The recipe for privileged code, written down and tested

The guarantee lives or dies in privileged code, and Elm's own has holes: a core package declares a
result type whose quantified error variable claims infallibility while its implementation listens for
an event that fires on failure too, so `null` arrives typed as a string and the next operation
throws. Well-typed code crashes. The organisation Elm's own front page cites for "no runtime
exceptions" was shipping thousands a day and fixed it by forking three core packages. **Trust is not
a mechanism.**

So the recipe is a written contract, not a convention:

- Address foreign objects by value; never hold a reference across an effect boundary.
- Marshal every result to plain data before it crosses back.
- Every failure the specification defines is a constructor in the result type, not an exception.
- Every privileged entry point is wrapped in `try`/`catch`.

The last one is not optional and the reason is typed: an uncaught foreign throw can alter a value in
a way its type forbids, which is unsoundness rather than a crash. Gleam's core package documents
exactly this when declining to make its promise type generic over its error.

**Testable form: one corpus scenario per capability that forces the failure path and asserts a value
comes back.** A capability without that scenario is not finished. This is the discipline whose
absence produced the bug above, in the codebase that invented the wall.

## 5. `main`, and what a platform provides

**`main` is a platform-owned opaque `Program`.** Its type is a platform fact, so M3 resolves it per
platform rather than hardcoding one, and a platform may offer more than one entry point.

**`main` must carry an annotation** — a language rule M3a had to introduce. Without one the checker
infers something and the build cannot tell whether it is this platform's `Program`; with one, the
checker has already proved the body matches, so comparing the annotation is a complete check that
costs no inference.

**An absence has no token, so `missing_main` underlines nothing** (2026-09-19, queue slice 45). It
is reported against a FILE at `1:1` with no excerpt, the form
`Session.reportInvalidModulePath` already uses for a fault about a file rather than a place in
one, and the message says which file it named and why. The file is the first module of the root
package by module index — the sorted path, never argument or completion order (`fast-compiler.md`
§10) — so the diagnostic is the same however the build was invoked, and the message says so when
the project has more than one module. It used to be reported on file 0, token 0: whatever source
the run enumerated first, at its first token, which in the corpus fixture is an `import` and reads
as if the import were the mistake.

**`main_not_program` names both types as the author could write them** — the prelude bare
(`language.md` Appendix A), the entry module's own types bare, a name an import exposes bare, and
`Alias.Name` otherwise. `Render.zig` prints every type name bare because it prints from a type
store, where a name carries no module (`checker.md` §8.2); this message reads a BIR annotation
instead and used to print the resolver's internal spelling, so a user who wrote `main : Int` was
told about `Basics.Int` — a name no beni source may contain.

**A platform declares its output shape with two manifest keys**: `program`, the module-qualified
opaque type `main` must have, and `runtime`, the JavaScript file whose `run` export receives
`main`'s value. That is the smallest thing that is a real declaration rather than a hardcoded
special case, and it is why a Bun or Deno platform needs no compiler change. Pin any addition here
before B4 invents a second mechanism.

Anything the platform manages is handed to `init` as a value **no other code can construct** — the
unforgeable-capability trick. A user cannot fabricate a database handle or a socket; they can only
use the one they were given, which is what makes a capability grantable and revocable rather than
ambient.

### 5.1 Many runtimes, few platforms

**The compiler knows nothing about runtimes.** It knows about platform packages, so supporting Bun,
Deno, Cloudflare Workers or Electron is a package someone publishes, not a compiler change. That
falls out of §2's governance decision rather than needing anything new, and it is the main practical
dividend of making privilege a role.

Where the runtimes have converged, the capability is **platform-independent and lives in core**:
`fetch`, `URL`, `TextEncoder`, `crypto.getRandomValues`, timers, streams and structured clone are
common to browsers, Node, Bun, Deno and the edge runtimes, and there is a standards body whose
purpose is keeping that set common. A module using only those compiles anywhere.

Where they genuinely differ — filesystem, process arguments and environment, servers, the DOM —
that difference *is* what a platform is for.

**Each runtime gets its own platform.** An earlier draft of this section said Node, Bun and Deno
could be one platform because all three implement Node's API surface through `node:` specifiers.
That is true and it is the wrong conclusion: **Node is the lowest common denominator**, so targeting
it universally would cap a Bun user at Node's capabilities and hide everything Bun adds — its
server, its file API, its shell, its bundled SQLite, its foreign-function interface. That is the
sparse-garden mistake of §1 repeated one level up, and this document exists to avoid it.

So a Bun platform exposes what Bun offers, a Deno platform what Deno offers, and neither pretends to
be Node. Code written against the Bun platform does not run on Node — which is honest, and which
§5.3's per-platform compilation already reports as a resolution failure rather than a runtime
surprise.

The duplication this implies is smaller than it looks, and needs no compiler feature: **platforms
are packages and packages depend on packages**, so runtime platforms share their beni code through
an ordinary dependency and differ only in their foreigns.

That gives two portability tiers, and saying which one you are in is a design decision a library
author should make deliberately:

| Tier | Written against | Runs on |
|---|---|---|
| **Portable** | core and the web-standard capabilities of §5.1 | every runtime |
| **Runtime-specific** | a platform's own capabilities | that runtime |

Portability comes from writing against the genuinely common set, not from pretending the runtimes
are the same.

### 5.2 A platform declares its output shape

`main`'s type is a platform fact, and so is the shape of the artifact. A browser platform wants a
module a `<script type="module">` can load; a Node platform wants an entry file; a Workers runtime
wants a specific export. The platform declares this, the same way it declares `main`, so §9.5's
emitter is parameterised by it rather than hardcoding one.

**A `"runtime"` naming a file that is not there is `foreign_sibling_missing`, reported against the
MANIFEST.** Every other manifest failure is an exit-2 line naming the path (§5.3, `src/platform.zig`),
because a manifest is JSON and has no beni tokens; this one is a diagnostic because it is found
during emit, alongside §4's sibling checks. It therefore points at `<platform root>/beni.json` at the
whole-file position `1:1`, with no excerpt — the same shape `invalid_module_path` uses for a fault
that is about a file rather than a place inside one. *Corrected 2026-09-19: it used to be reported on
file 0, token 0, which is the first token of the USER'S source, so a fault in the platform package
put a caret under an `import` the reader wrote.*

### 5.3 One project, several platforms

The full-stack case is a first-class requirement, not an afterthought: a browser client and a server
in one repository, sharing modules. **A build is per entry point and per platform**, so shared code
is compiled twice under different platforms and each compilation sees only the capabilities its
platform offers. A module that uses a browser-only capability simply fails to resolve when compiled
for the server, which is the diagnostic you want rather than a runtime surprise.

**A project with two `main`s is therefore refused, under `duplicate_main`** (`language.md` §10, added
2026-09-19; it used to share `missing_main`, whose title says the opposite). The message names both
modules and both locations, and calls "the first" the one with the lower module index — the sorted
path, never argument or completion order. `--library` turns the rule off with the rest of the
entry-point search, because a library has no entry point to be ambiguous about.

This is also why `--platform` cannot be a global flag with one value per invocation forever; the
build contract needs to express "this entry point, that platform" as a pair. M3 may ship one pair
per invocation, but the manifest concept M4 introduces should carry the set.

**How a platform is located, and which subcommands may say so.** `--platform=<name>` is either the
name of a platform that ships in the binary — embedded like `core/`, modules, siblings, runtime and
manifest all — or a path to a directory holding a package whose `beni.json` says `"platform": true`
(§2). Nothing else is a platform, and a name that is neither exits `2` naming the ones that ship,
because a build that quietly fell back to "no platform" would report `main`'s type as a missing
module. Either way the package is enumerated alongside the app and core, its modules get
`SourceStore.Package.platform`, and that is what puts them in the import search path and makes
`foreign` legal inside them.

**`beni check` and `beni dump` take the same flag, resolved the same way** (`frontend.md` §1).
`--platform` was added with the backend and stayed a `build` flag for as long as `build` was the
only thing that needed a platform package on disk; that was never a decision, and the cost of it was
that `check` — the command an editor, a hook, CI, M4's daemon and M5's LSP all run — could not be
pointed at any program that imports its platform for `Program`, which is every program. `check` is
not *required* to name one: a library and a platform-free module must stay checkable, so the flag is
optional and a program that omits it gets `unknown_module` plus, for a platform in the box, a hint
naming the flag. With a platform named, `check` runs §4's four sibling checks as well, since they
need no output directory; it does not look for an entry point, because the entry point is half of a
BUILD pair and `check` is handed paths.

Two platforms ship with the compiler:

- **Browser**: The Elm Architecture. `init`, `update`, `view`, `subscriptions`, ports.
- **Node**: worker-shaped, plus an exit code. Node rather than Bun or Deno because it is what the
  toolchain already pins and what CI runs; Bun and Deno platforms are natural early additions, and
  per §5.1 they are packages rather than compiler work. This is the platform the test suite's second boundary runs against — compile a program,
  run the emitted JavaScript, assert what it printed — so it is not a nicety, it is what makes
  codegen testable at all.

### 5.4 The Elm Architecture's command type, and cancelling one

`transparent-effects-proposal.md` settles the language side: `update` and `view` are `sync`, so
neither may perform, and everything a program performs lives in a thunk handed to the runtime. What
that thunk is wrapped in is this package's business, and none of it needs a language feature.

```elm
type Policy = Restart | Ignore | Queue | Concurrent

Cmd.run    : (() -> a), (a -> msg) -> Cmd msg               -- fire and forget
Cmd.keyed  : k, Policy, (() -> a), (a -> msg) -> Cmd msg    -- k equatable
Cmd.cancel : k -> Cmd msg
```

**Commands must be cancellable or the runtime's justification stops at this boundary.** The fiber
runtime can interrupt a parked fiber in a microsecond (`research/16` §2.4); a `Cmd` API that hands
over a thunk and forgets it would leave every user-facing effect in the architecture uncancellable,
which is Elm's present behaviour and one of its few widely-voiced complaints — a debounced search
box or a request abandoned on navigation is handled today by ignoring a stale `Msg` when it
arrives, leaking the work.

The runtime holds a map from key to fiber. `Restart` cancels a running fiber under the same key and
starts the new one; `Ignore` drops the new one while the old is in flight; `Queue` runs them in
order; `Concurrent` runs them side by side. Those four are what RxJS separates as `switchMap`,
`exhaustMap`, `concatMap` and `mergeMap`; naming all four now costs nothing and is awkward to add
later. Cancelling runs the fiber's finalisers, so a cancelled command releases what it held.

```elm
update msg model =
    case msg of
        Typed q       -> ( { model | q = q }, Cmd.keyed "search" Restart (\() -> search q) GotHits )
        NavigatedAway -> ( model, Cmd.cancel "search" )
```

**Why a key and not a handle.** `update` is `sync` and pure, and between the update that starts the
work and the one that cancels it there is no beni frame alive to hold anything — the program is
parked in the event loop. Elm's alternative is the round trip `research/16` §1.4 records as a
defect: *"`kill` needs an `Id`, `spawn` yields one only as a `Task`… By the time you can cancel, a
frame has passed."* A key is data, so it survives the gap and keeps `update` pure.

The split is not arbitrary. Handle-based cancellation is what imperative runtimes use — Kotlin's
`Job`, Go's `context.Context`, Effect's `Fiber.interrupt`, Swift's `Task`. Keyed cancellation is
what *declarative* ones use: React Query cancels by query key, SwiftUI's `.task(id:)` restarts when
the id changes, Redux-Saga's `takeLatest` keys by action type. The stricter an architecture is about
pure state updates, the more it identifies work by value rather than by object, and TEA is the
strictest of them.

**This improves the testing story rather than leaving it flat.** A `Cmd` stays opaque, as in Elm, so
what a thunk *would do* is still not inspectable. But the key is ordinary data in the returned
value, so "navigating away cancels the search" becomes assertable, which it is not in Elm today.

**Open.** Whether keys are global with callers namespacing their own strings, as port names are, or
whether TEA needs a notion of component identity it does not currently have; whether `k` is a
polymorphic equatable or simply `String`; whether `Cmd.cancel` on a key with nothing running is
silent or warns. And **subscriptions are not designed here** — `Sub msg` is named in §4 as an
admitted `foreign` shape and nothing more, and a good deal of real cancellation lives in them.

---

## 6. The capability roadmap

What "better equipped" concretely means. Each entry is a capability Elm walls off, brought inside the
wall as a typed platform or core capability, with the typing that keeps well-typed code from
crashing.

**First: `Intl` and time.** Every failure defined by the internationalisation specification is
argument validation, so it moves into smart constructors at **zero runtime cost** — the validation
happens once, at construction, and the constructed value is then total. It is the capability Elm most
conspicuously lacks, and its sanctioned workaround demonstrably reintroduces crashes into the
virtual-DOM patch. It also establishes the validated-newtype pattern that every later capability
reuses.

Then, in rough order of how well the typing is understood: typed arrays and binary data; `fetch` and
streaming; `localStorage` and structured storage; Web Workers; direct DOM access beyond the virtual
DOM. Each needs its own analysis of what its failure modes are and whether they are all constructors;
none is admitted on the grounds that it would be convenient.

## 7. What this costs the rest of the design

### 7.1 Dead-code elimination stays declaration-granular

Elm solved the hard half of this and then lost it to granularity. A kernel JavaScript file is not
opaque to Elm's compiler: it is a template parsed into chunks, and every variable reference becomes a
real edge in the same whole-program graph the traversal from `main` walks. **A whole-program compiler
can see through its own foreign code precisely because that code is written in a dialect the compiler
reads, which is why no bundler can.** But every kernel file is keyed to *one* graph node, so reaching
one function pulls in the whole file. Module-granular tree shaking reappears exactly where §9.1
exists to beat it, and the byte attribution shows the cost from the other side: roughly 45% of Elm's
TodoMVC bundle is hand-written runtime.

**One export per foreign value is one graph node per foreign value**, which is why §5.4 already
specifies it. What must be added is the dependency half: Elm recovers it by parsing markers in its
template dialect; beni recovers it from the sibling file's own `import` statements, because we emit
ES modules and can simply read them. Hence check 3 in §4 — **a sibling file whose exports reference
anything not reachable from its own imports is a build error.**

### 7.2 Purity, and therefore elimination's correctness

§9.1's exactness rests on purity, and a `foreign` declaration is where that proof is assumed rather
than derived. The exposure is smaller than it looks, because §3.1 already decided effects are values:
a `foreign` of effect type is pure to *evaluate* by construction, and its interpretation happens in
the platform, which is the one place impurity is expected. §4's two-shape rule is what keeps the
assumption to that. Elm reached the same reasoning independently — its port error text refuses
functions because *Elm optimizations assume there are no side-effects*.

### 7.3 The M4 interface firewall is unaffected, but the cache key grows

Foreignness is already one bit in the interface record, derived from source text, and nothing about
the JavaScript appears there — so the interface stays a pure function of the `.beni` source, which is
the firewall's requirement.

What changes is the cache key: **it must include the content hash of the sibling JavaScript file**, an
input hash exactly like the source bytes. Editing a sibling file then invalidates that module's own
emit unit and nothing else, not a single dependent's declaration type. That is strictly better than
Elm, where kernel code lives inside the package and any change re-runs the package build. One
requirement to state now rather than debug later: **M4's `stat` fast-path must cover sibling files**,
not only `.beni` files.

*Amended 2026-09-19, as M4-1 built the key (`fast-compiler.md` §8, `plans/m4-1.md`). The sibling
hash is in the key, as a 16-byte term that is 16 zero bytes for a module declaring no `foreign`.
Two corrections to the paragraph above, both from where the checks actually live. **(i) §4's four
checks are a whole-program pass, not part of a module's check**: they run in `Emit.checkContract`
(`src/js/Emit.zig:172`, `:229`, `:424`), which `beni build` runs and `beni check --platform` runs
too (`src/check/Command.zig:89`), outside and after the per-module check whose result an entry
holds. So in M4-1 no cached artifact depends on a sibling's bytes, and the term is conservative —
taken anyway, because check 4 reads the sibling to count a declared `foreign`'s parameters and the
day that answer is cached the key has to have been right all along, and because one hash per module
declaring a `foreign` is a cost nobody can measure. **(ii) "and nothing else" is M4-3's, not
M4-1's**: an M4-1 key carries its imports' keys, so a sibling edit does reach a dependent. It stops
there the moment the key is weakened to the interface hash, which a sibling cannot move — foreignness
is one bit derived from the `.beni` source and no byte of the JavaScript is in the record, which is
this section's own point. The `stat` fast-path over siblings arrives with the one over sources, in
M4-2.*

## 8. Milestones

- **B1 — the platform contract in the compiler.** *Shipped with M3a.* The manifest key
  (`beni.json`, `"platform": true`) that marks a platform package; `foreign_outside_platform`; the
  first three build-time checks of §4 (check 4 arrived with static dispatch and landed on
  2026-09-18); `Program` as a platform-owned opaque type; `main` resolved per
  platform. Two corrections the implementation forced:
  - **§4's shape rule as written rejects core.** It says "all 65 of core's current foreign values
    are shape (a)", a total pure function. `Basics.e` and `Basics.pi` are not functions and never
    were. What the compiler can actually check about a `foreign` is its TYPE, and `pi : Float` is
    indistinguishable by type from the `now : Float` the rule exists to refuse. The enforced rule is
    therefore weaker and honest: a function, or a value of a type with no variables in it. That
    still refuses `foreign anything : a` and `foreign xs : List a`, which are the shapes that would
    let a `foreign` fabricate a value of a type the caller chose.
  - **Check 3 is lexical, not a scope analysis.** The scanner skips comments, strings, templates and
    regular expressions and then classifies identifiers; a name bound anywhere in the file counts as
    bound everywhere, and a reference inside a template substitution is not seen. Both
    approximations are permissive, deliberately: the failure the check exists for is a sibling
    reaching a HOST global it never imported (`process`, `require`, `window`), and no local scoping
    hides one of those. A precise answer needs a JavaScript parser, which is the dependency the wall
    exists to avoid.

  And one thing §4 does not say that B1 had to decide: **which globals a sibling may reach without
  importing anything.** The answer follows from §5.1 rather than from taste — the ECMAScript
  intrinsics, plus the web-standard capabilities §5.1 says every runtime has (`fetch`, `URL`,
  `TextEncoder`, `crypto`, the timers, `console`). A HOST global is deliberately not on that list,
  which is what makes `import process from "node:process"` the fix rather than an allowlist entry.
- **B2 — the Node platform and core's JavaScript.** *Shipped with M3a.* All 65 of core's foreign
  values, the Node platform, and with them the test suite's second boundary: compile, run under
  Node, assert what it printed (`tests/corpus/run/`). **This is the milestone that makes M3
  testable**, and it landed before the optimiser rather than after. What §4.1's recipe still owes:
  the "one corpus scenario per capability that forces the failure path" clause is satisfied for the
  capabilities that HAVE a failure path (`String.toInt` on `"1.3"`, `Char.fromCode` out of range) and
  is vacuous for the rest, because a `foreign` over `Int` and `String` has no specification-defined
  failure to force. It becomes load-bearing at B3 and B5, where the capabilities do.
- **B3 — ports.** The codec generator widened to ADTs and records, the depth bound, the
  request/response correlation layer, and a corpus scenario per port shape.
- **B4 — the browser platform**, The Elm Architecture over B3's ports.
- **B5 — `Intl` and time**, the first capability brought inside the wall, and the validated-newtype
  pattern every later one reuses.

## Appendix — what is deliberately not done

- **User-writable `foreign`.** It has never been made safe in any of the fourteen languages surveyed,
  and the wall is the product.
- **A synchronous port variant.** Three independent mechanisms in Elm exist to prevent it, and the
  failure class it admits is the one nothing can catch.
- **A synchronous escape hatch "just for core".** Core is where the bugs in §4.1 were.
- **Settling for opaque-JSON-only ports.** That is the status quo, and it is the *unchecked* path.
