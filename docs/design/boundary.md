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

*Amended 2026-09-29:* a platform package may also depend on other platforms, declare a markup
vocabulary (`vocabulary_outside_platform` in an ordinary module) and select a markup lowering, and a
platform that brings a lowering of its own is Zig compiled into beni — all of it §9.

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

   **Corrected while building the backend, twice.** An earlier draft said "all 65 of core's foreign values are shape
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

   *Amended 2026-09-24.* **"Declared arity" is the arity of the declared TYPE,
   looking through aliases**, and both counts are `check/Convention.zig`'s (`checker-v2.md` §12.5),
   the same answer every call of the `foreign` is lowered by. So `pub foreign isPos : IntPred`, with
   `type alias IntPred = Int -> Bool`, is a function of one parameter and is written `(x) => …`;
   counting the annotation's spelling (no arrow) called it a value and refused exactly that sibling.
   Check 1 still reads the spelling, so a POLYMORPHIC alias (`isSelf : Pred a where a.eq …`) is
   refused there as `foreign_bad_shape` before check 4 runs — conservative, and a safe refusal; if
   check 1 learns aliases, check 4 already counts `(eq, x)` for it.

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

**A diagnostic points at the file whose text is wrong** (2026-09-19). The four
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

**This rule was documented and unenforced for one day and is now check 4** (2026-09-18). While it was unenforced a sibling that forgot its leading evidence parameter built cleanly and
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

**Schema format adapters** obey this privilege wall and the failure recipe
above. [`schema.md`](schema.md) §5 owns bounded JSON adaptation, fallible encode
as well as decode, and engine-owned context; §7 records the still-open H4
obligation at synchronous host boundaries. Schemas neither grant user packages
`foreign` nor replace this section's platform/main contract or ports automatically.

## 5. `main`, and what a platform provides

**`main` is a platform-owned opaque `Program`.** Its type is a platform fact, so M3 resolves it per
platform rather than hardcoding one, and a platform may offer more than one entry point.

**`main` must carry an annotation** — a language rule the backend had to introduce. Without one the checker
infers something and the build cannot tell whether it is this platform's `Program`; with one, the
checker has already proved the body matches, so comparing the annotation is a complete check that
costs no inference.

**An absence has no token, so `missing_main` underlines nothing** (2026-09-19). It
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

**A platform declares its output shape with three manifest keys**: `program`, the module-qualified
opaque type `main` must have; `runtime`, the JavaScript file whose `run` export receives `main`'s
value; and `entry`, the name of the entry file itself, which is optional and defaults to
`_main.mjs`. That is the smallest thing that is a real declaration rather than a hardcoded special
case, and it is why a Bun or Deno platform needs no compiler change. Pin any addition here before B4
invents a second mechanism. *`entry` was added on 2026-09-21; until then the entry file's name was
the one part of the output shape this section claimed to declare and the emitter hardcoded
(`backend.md` §2, rule 1).*

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

**The entry file's NAME is part of that shape, and it is `"entry"`** (added 2026-09-21). It is
optional; a platform that omits it gets `_main.mjs`. A declared name is subject to `backend.md` §2's
rule 1 and is checked when the platform is loaded, before anything is built: **one path segment,
beginning with `_`, ending in `.mjs`, ASCII letters, digits, `_` or `-` between**. Anything else is
`invalid_entry_file`, reported against `<platform root>/beni.json` at `1:1` with no excerpt — the
shape the `"runtime"` failure below uses, and for the same reason.

The leading `_` is not decoration and the check is not pedantry. A module is named by its path and
every segment is an upper identifier (`language.md` §5), so `_` is the one region of the output name
space no module can occupy — on a case-insensitive file system included, where `main.mjs` and the
module `Main`'s `Main.mjs` are one file. Moving the name into this manifest without the rule would
have been a worse outcome than leaving it hardcoded: it would let a platform author reintroduce, in
data, a defect the compiler had just been taught to make impossible.

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

*Amended 2026-09-29: this list is superseded by §9.1*, where the browser is two platforms — a base
`browser` and The Elm Architecture as `browser-tea` layered on it — beside a vocabulary platform
`html` that `browser` and `node` both depend on. The list is kept as written.

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

*Amended 2026-09-19, as the persistent cache built the key (`fast-compiler.md` §8, `plans/m4-1.md`). The sibling
hash is in the key, as a 16-byte term that is 16 zero bytes for a module declaring no `foreign`.
Two corrections to the paragraph above, both from where the checks actually live. **(i) §4's four
checks are a whole-program pass, not part of a module's check**: they run in `Emit.checkContract`
(`src/js/Emit.zig:172`, `:229`, `:424`), which `beni build` runs and `beni check --platform` runs
too (`src/check/Command.zig:89`), outside and after the per-module check whose result an entry
holds. So no cached artifact depends on a sibling's bytes, and the term is conservative —
taken anyway, because check 4 reads the sibling to count a declared `foreign`'s parameters and the
day that answer is cached the key has to have been right all along, and because one hash per module
declaring a `foreign` is a cost nobody can measure. **(ii) "and nothing else" is the firewall cutoff's, not
the first cache key's**: that key carried its imports' keys, so a sibling edit does reach a dependent. It stops
there the moment the key is weakened to the interface hash, which a sibling cannot move — foreignness
is one bit derived from the `.beni` source and no byte of the JavaScript is in the record, which is
this section's own point. The `stat` fast-path over siblings arrives with the one over sources.*

## 8. Milestones

- **B1 — the platform contract in the compiler.** *Shipped with the backend.* The manifest key
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
- **B2 — the Node platform and core's JavaScript.** *Shipped with the backend.* All 65 of core's foreign
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

## 9. Layered platforms, markup vocabularies and the markup lowering

*Specified 2026-09-29; not built.* Three of the owner's answers of that day
([`plans/browser-decisions.md`](../../plans/browser-decisions.md), *JSX targets*, *Layers* and
research 36's question 1) change what a platform is. **A platform may depend on another platform**;
**a platform declares its markup vocabulary in beni**; and **a platform owns the lowering of markup
to JavaScript**, as Zig compiled into the beni binary behind one interface. The language owns the
syntax, the typing and the guarantees ([`language.md`](language.md) §11,
[`checker-v2.md`](checker-v2.md) §25); every rendering strategy — templates, strings, a virtual DOM,
plain calls — is platform code. Nothing in this section moves §4's wall or its four checks
(§9.7).

### 9.1 Layers, and a platform that depends on a platform

| Layer | Is | Knows |
|---|---|---|
| **the language** | the compiler: syntax, types, guarantees, the markup tree | no architecture, no HTML, no host |
| **core** | the platform-independent package, embedded | no host beyond §5.1's common set |
| **platforms** | privileged packages: `foreign`, vocabularies, a markup lowering, `Program` | one host |
| **frameworks** | ordinary beni, or a platform layered on another | an architecture |

**The Elm Architecture is not part of the language** (W25 is the default a new project gets, not a
rule). It is a platform, `browser-tea`, layered on a base `browser` platform that supplies the DOM
capabilities, the `dom` lowering and its runtime, and a low-level `Program`; another architecture is
another platform on the same base. The four platforms that ship with the compiler, replacing §5.3's
two:

| Platform | Depends on | Declares |
|---|---|---|
| `html` | — | the HTML vocabulary: elements, attributes, events, the markup type `Html msg` (§9.3). No `program`; it is only depended on |
| `browser` | `html` | DOM capabilities, a low-level `Program` and its `runtime`, the `markup` key selecting `dom` |
| `browser-tea` | `browser` | The Elm Architecture in beni over `browser`'s `Program`; re-exports `Html` and `browser`'s modules |
| `node` | `html` | today's Node platform, plus the `markup` key selecting `ssr`, so a `view` renders to a string under Node and `tests/corpus/run/` can test it (research 36 §5.5) |

**The manifest gains two keys.**

```json
{ "platform": true, "name": "browser-tea",
  "platforms": ["browser"],
  "reexports": ["Html", "Browser", "Browser.Dom"] }
```

- **`"platforms"`** lists the platforms this one depends on, each the name of a platform in the
  binary or a path relative to this package's root, as `--platform` takes them (§5.3). The chain is
  read depth-first in list order; a package reached twice is one package; a cycle is an exit-2
  manifest failure naming the cycle, like every other manifest failure.
- **Every package of the chain is enumerated** as a platform package — `foreign` and vocabulary
  declarations are legal in its own modules — and module names are unique across the whole build,
  so a clash is the existing `duplicate_module`.
- **Visibility.** A platform's own modules may import every module of the platforms it depends on,
  transitively. The **program** — the root package — may import the modules of the selected (top)
  platform, and a dependency's module only when some platform on its path to the top lists it in
  **`"reexports"`**, which may name any module the listing platform can import. Anything else is
  `unknown_module`, whose message names the platform that has it and the key that would expose it.
  That is the whole of "re-export": beni has no re-export declaration, and does not gain one; the
  module is the same module, reached by its own name.
- **The output keys** — `program`, `runtime`, `entry` and `markup` (§9.2) — are each taken from the
  top platform when it declares them, otherwise from its dependencies in the chain's order, first
  found. `program` may name a type of any module of the chain. So `browser-tea` declares none of them:
  its `Tea.element : { init, update, view, subscriptions } -> Browser.Program` is beni over
  `browser`'s capabilities, and the build's `Program` and `runtime` are `browser`'s.
- **Output.** The top platform's modules, siblings and runtime go to `_platform/` as today; a
  dependency platform's go to `_platform/_<name>/`, a path no module can reach (`backend.md` §2,
  rule 1), so the existing output of a one-platform build does not move by a byte.
- **A sibling still may not import another file** (`backend.md` §2), across packages as within one.
  So a layered platform shares code with its base through beni, never through JavaScript — which is
  why TEA is a beni library over `browser`'s `foreign`s rather than a runtime of its own.

### 9.2 The `markup` manifest key

```json
"markup": { "lowering": "dom", "vocabulary": "Html", "type": "Html.Html", "runtime": "markup.js" }
```

| Field | Is | Checked |
|---|---|---|
| `lowering` | the name of a markup lowering compiled into this beni binary (§9.5) | when the platform is loaded: an unknown name is **`unknown_markup_lowering`**, reported against `<platform root>/beni.json` at `1:1` with no excerpt, the shape `invalid_entry_file` uses, and the message lists the lowerings this binary has |
| `vocabulary` | the module of the chain that holds the `pub element`, `pub attribute` and `pub event` declarations | when a module uses markup: a name that is no module of the chain is `no_markup_vocabulary`, whose message names this key |
| `type` | the markup type: a `pub foreign type` of one parameter, in any module of the chain | likewise |
| `runtime` | the **markup runtime**, a JavaScript file of the declaring package whose exports are the lowering's well-known entry points (§9.4.5) | by §4's checks 2, 3 and 4, exactly as a sibling (§9.7) |

A chain with no `markup` key has no markup: a program that writes some is `no_markup_vocabulary`.
Two platforms of a chain may both declare the key — `node` and `browser` do, over one `html` — and the
first found wins (§9.1), which is how one vocabulary is lowered two ways.

### 9.3 The vocabulary, and why it is not `foreign`

A platform package declares its markup vocabulary with `language.md` §11.14's three forms. They
**carry no JavaScript**: an element, an attribute and an event have no run-time existence of their
own, so as `foreign` values §4's check 2 would demand an export for each and there is none to write
(research 36 §5.4). So they are a declaration form of their own, privileged like `foreign` — legal
only in a platform package (`vocabulary_outside_platform`) — and they leave check 2 exact
(research 36 question 1, accepted).

**The facts are the lowering's data.** The language fixes the set of fact words and what the
checker reads (`void`, `on`, the value and payload types, `via`); what `property`, `stateful`,
`url`, `raw`, `delegated`, `preventDefault`, `stopPropagation`, `name`, `svg` and `mathml` do is each
lowering's to define, and a lowering that has no use for one (`ssr` and `delegated`) defines it as
nothing. **Every lowering must write the five value classes** — `String`, `Int`, `Float`, `Bool`,
`Maybe String` — since those are what the checker admits (`checker-v2.md` §25.2). Growing the fact
set is a change to this section and to the lowering interface's version (§9.4.6).

**A payload extractor is an ordinary `foreign`.** `pub event "onInput" delegated via targetValue :
String` names `foreign targetValue : Event -> String` of the same module, which is bound to an
export of the module's sibling and held to all four of §4's checks like any other. So the one piece
of a vocabulary that runs JavaScript is exactly as walled as everything else that does.

**Where HTML's parser rules live.** Void elements as the parser sees them, implied end tags, table
foster-parenting, `<a>` inside `<a>` — facts about `innerHTML`, not about a vocabulary — are a fixed
table in the `dom` lowering — kept in `html`'s Zig so `ssr` uses the same one (§9.5) — and never
the language's or the vocabulary's (research 36 question 2,
accepted; `backend.md` §15.3). Typed content categories, which would make misnesting a type error,
are later (research 27 §6.12).

### 9.4 The markup lowering interface

A **markup lowering** is a Zig module, compiled into the beni binary (§9.5), that turns the typed
markup tree of one module into JavaScript through the same `JsIr` builder the emitter uses. It is the
only place a rendering strategy lives. The compiler parses and types markup; the lowering decides
what a template, a hole, a list and an event become.

#### 9.4.1 Where it runs

- **In `build` only**, after the whole program checked clean and reachability chose what survives
  (`backend.md` §9), once per module that has a surviving markup root, on the worker that lowers that
  module's JavaScript, interleaved with that lowering (§9.4.3). Modules are lowered in parallel, so a
  lowering is re-entrant by construction (§9.6).
- **Never in `check`.** Whether a program checks, and every diagnostic `check` prints, is independent
  of the lowering — which is what lets one module check once and compile under two platforms. The
  one exception is §9.4.7's `markup_restructured`, a `build` diagnostic.

#### 9.4.2 The typed markup tree

The compiler hands a lowering one `Tree` per module. Its shape, as the interface module declares it
(`src/markup/Interface.zig`, imported by a lowering as `beni_markup`; the names are the contract of
interface version 1):

```zig
pub const Tree = struct {
    roots: []const Root,          // in instruction order: the module's markup sites
    nodes: []const Node,          // every Node.Index points in here
    attrs: []const Attr,
    events: []const Event,
    props: []const Prop,
    children: []const Node.Index, // ranges of children, in source order
    strings: Strings,             // markup names, trimmed text, constant attribute text: UTF-8
    vocabulary: Vocabulary,       // the element, attribute and event rows the nodes name, with their facts
};

pub const Root = struct {
    site: Site,                   // { module: u32, inst: u32 }: module index and instruction index
    node: Node.Index,
    values: Value.Range,          // the root's values, in evaluation order (language.md §11.11)
    shape: enum { expression, for_row },
    row: ?Row,                    // for_row: the row function's parameters and captured environment
};

pub const Node = union(enum) {
    element: struct { row: ElementRow, attrs: Range, events: Range, children: Range },
    fragment: struct { children: Range },
    text: struct { text: Strings.Index },                         // already trimmed, literal
    hole: struct { value: Value.Index, kind: HoleKind },          // text(string|number|char|bool), html, maybe_html, list_html
    component: struct { props: Range, spread: ?Value.Index, children: ?Value.Index },
    for_: struct {
        each: Value.Index, fallback: ?Value.Index,
        keyed: union(enum) { key: Value.Index, position, reference },
        item_is_primitive: bool,
        row: union(enum) { root: Root.Index, function: Value.Index }, // markup body, or an opaque function
    },
};

pub const Attr = struct {
    name: Strings.Index,
    row: ?AttributeRow,                                            // null: the quoted-name escape
    class: enum { string, int, float, bool, maybe_string },
    value: union(enum) { constant: Constant, dynamic: Value.Index },
};

pub const Event = struct { row: EventRow, form: enum { message, payload }, handler: Value.Index };
pub const Prop = struct { field: Strings.Index, value: Value.Index };
```

What the tree **is**: every fact about markup the checker decided (`checker-v2.md` §25.7), in the
shape a lowering walks, and nothing about beni it does not need. What it **is not**: a place to find
types, `Bir`, other modules or the program's expressions. **A value is an index, never an
expression**: the lowering never sees the beni code that computes an attribute or a hole — it asks
the compiler to evaluate a root's values (§9.4.3) and then reads them by name. That is what makes
evaluation order and "exactly once" the compiler's obligation rather than every lowering's, and it
is why a hole's expression can hold anything the language allows, markup included, with the
lowering none the wiser: markup inside a value is its own root, lowered first, and arrives as a
value.

#### 9.4.3 The builder surface

A lowering is a value of this type:

```zig
pub const Lowering = struct {
    name: []const u8,                           // what a manifest's "lowering" names
    interface_version: u32,                     // == beni_markup.interface_version, checked at comptime
    runtime: []const RuntimeExport,             // §9.4.5
    module: *const fn (cx: *Context, tree: *const Tree) Error!void,
    root: *const fn (cx: *Context, tree: *const Tree, root: Root.Index, values: []const Name) Error!Expr,
};
```

- **`module`** runs once per module before any of its roots, and **hoists** what the module needs —
  a template constant, a template kind with its mount and patch functions, a row's pair — with
  `cx.hoist(hint, init) Name`. A hoisted declaration is a module-level `const` with a **pure**
  initialiser, emitted in the order it was hoisted, because `backend.md` §9 drops and keeps
  declarations on the premise that loading a module does nothing (§9.7).
- **`root`** runs where the program evaluates a root of shape `expression`: the compiler has already
  emitted the statements that evaluate the root's values in order and bound each to a `const`, and
  passes their names; the lowering returns the expression the root evaluates to — a block, a string,
  a tree node, whatever its representation of the markup type is.
- **Rows.** A `for_` node whose row is a `root` is the one place a lowering places beni code itself:
  inside a function it builds, `cx.rowValues(block, row_root, item, index, env) []Name` emits the
  row's values into `block`, with the item, the position and each captured value bound to names the
  lowering chose. It may call it at most once per call of the function it placed it in. The captured
  environment is listed on the `Row` (the row lambda's free locals), and the enclosing root binds
  them as values, so a lowering can compare them to decide a skip.
- **Components.** `cx.componentCall(node, prop_names, spread_name, children_name) Expr` builds the
  record exactly as `backend.md` §4 builds a record literal (or a record update over the spread) and
  the call with its evidence (`checker-v2.md` §25.5); the lowering decides when to call it.
- **Extractors.** `cx.extractor(event) ?Expr` is the payload extractor's reference, imported as any
  `foreign` is.
- **Building JavaScript.** `cx.js` is the `JsIr` builder restricted to: literals (string, number,
  boolean, `null`, template literals), names the lowering was given or made (`cx.fresh(hint)`,
  `cx.hoist`, `cx.runtime`, the values, a function's own parameters), property reads and writes by a
  constant name or an index, calls, arrow and function expressions, object and array literals,
  `const`/`let`, assignment, `if`, conditional expressions, `return`, and the operators `===`,
  `!==`, `!`, `&&`, `||`, `+` and `typeof`. Every node is built at a markup node's position
  (`cx.at(node)`), so a source map can point a hole's update at its hole (`backend.md` §11).

#### 9.4.4 What a lowering may not do

- **Name a host global.** `document`, `window`, `Node`, `globalThis` — none is reachable through the
  builder: there is no way to spell an identifier the lowering was not given. **Every host access goes
  through the markup runtime**, whose imports §4's check 3 reads, so the wall is where it was: the only
  JavaScript that touches the host is a sibling.
- **Import anything but its own runtime.** `cx.runtime(name)` imports one of the lowering's declared
  well-known exports from the platform's markup runtime, and nothing else can be imported.
- **Emit text.** There is no raw-JavaScript node; a string literal is data.
- **Evaluate a value twice, or out of order, or run code at load.** Values are evaluated by the
  compiler; a row's at most once per call (§9.4.3); a hoisted initialiser is pure.
- **Read anything but its arguments**: no file, no environment, no clock, no randomness, no other
  module's tree, no global or `threadlocal` state — the determinism rule (§9.6).
- **Change what a program means.** A lowering chooses representation and never semantics: it renders
  every node, every value and every event the tree describes, and skips only what `language.md`
  §11.11 allows (a component whose props are all identical, a row whose inputs are). It reports no
  diagnostic but §9.4.7's.

#### 9.4.5 The runtime's well-known exports

A lowering declares the exports its emitted code imports, each with its parameter count:
`RuntimeExport{ .name = "template", .arity = 1 }`. The compiler checks the platform's markup
runtime against that list with §4's check 2 (exactly these exports, no more, no fewer), check 3 (its
references are covered by its own imports) and check 4 (each export takes the declared count, written
in one of §4's accepted forms). Those names are the compiler's contract with the platform in the same
way `eq` and `compare` are with a type (`static-dispatch-spike.md` §3.2), except that here the
contract belongs to the lowering: `backend.md` §15 lists `dom`'s and `ssr`'s. `check --platform`
runs these checks too, as it runs §4's.

**Program start.** A lowering may contribute **start data** — `cx.start(key, value)`, both strings,
such as the names of the events it delegates. The compiler unions every surviving module's
contributions, sorts them, and the entry file calls the runtime's well-known `start` export with them
before it calls `run` (§5.2). That is how a platform does once, at program start, what Solid does
with a module-level `delegateEvents` call — which beni cannot do, because loading a module must do
nothing (research 36 §0 item 9c; `backend.md` §9). A `--library` build writes no entry file and calls
no `start`, so a lowering must stay correct without it (`backend.md` §15.3 says how `dom` does).

#### 9.4.6 Versioning

`beni_markup.interface_version` is one number. A lowering states the version it was written against,
and a lowering whose version is not the compiler's is a **compile error of beni itself**, at
`comptime` — an external platform learns it when it rebuilds beni, never from a user's build. The
version changes with any change to the tree, the builder, the fact set or the rules of this section;
additions that an old lowering cannot misread still change it, because the check is the only warning
a platform author gets. Each version's contract is recorded here, dated, as the section is amended.

#### 9.4.7 Diagnostics

`cx.report(node, message)` reports **`markup_restructured`**, an error, at the markup node's source
region: the one code a lowering may raise, for markup the lowering cannot represent faithfully — the
`dom` lowering's use is markup the HTML parser would rebuild differently from the tree (`backend.md`
§15.3), as Solid's compiler refuses the same (research 36 §3.4). It is reported during `build` like
any emit diagnostic: after everything is produced and before a byte is written, so a refused build
writes nothing (`backend.md` §2).

### 9.5 How a lowering is compiled into beni

**No dynamic loading, ever**: a lowering is Zig linked into the binary, and a platform is trusted
code by design (the owner's decision), so the security argument is §2's — a distribution fact — and
not a sandbox.

- **Built in.** A platform in `platforms/<name>/` that has a lowering keeps its Zig beside its beni:
  `platforms/browser/lowering/dom.zig`, `platforms/node/lowering/ssr.zig`. `build.zig` embeds each
  built-in platform's assets as today and, for each that has one, adds its lowering as a Zig module
  whose **only** imports are `beni_markup`, `std`, and the Zig of the platforms its platform depends
  on (§9.1) — so `html` can ship the HTML parser's table once, as a Zig module with no lowering of its
  own, and `browser`'s `dom` and `node`'s `ssr` both import it (`backend.md` §15.6). It then
  generates the registry the compiler reads — every lowering, sorted by name, a duplicate name a
  build error. The compiler's own modules are never importable from a platform's Zig.
- **External.** Anyone may add a platform to their own beni without editing its source, in two
  equivalent ways: `zig build -Dplatform=<dir>` (repeatable), where `<dir>` holds the platform's
  `beni.json`, its modules and siblings, and a lowering's Zig root named by the manifest's optional
  `"lowering_source"` key; or, from a build that depends on beni, `beni.addPlatform(b, .{ .dir =
  … })`, which does the same. The platform then ships in that binary exactly as a built-in one does:
  `--platform=<name>` finds it, its assets are embedded, its lowering is in the registry.
- **A platform directory without Zig** — `--platform=<dir>` at run time, §5.3 — may still select any
  lowering the binary has by name. Only a platform that brings a *new* lowering needs a rebuilt beni.

### 9.6 Determinism, and what the cache must know

- **A lowering is a pure function of the tree, the builder state and the build's options.** It keeps
  no state between calls, iterates no hash map, compares no pointers, reads no clock, and makes every
  name through `cx.fresh` and `cx.hoist`, which derive names from the site and a counter local to the
  module's lowering — never from a counter shared across workers, which is the one way a lowering
  could break rule 5 (research 28 §9.3). The determinism test (`--jobs=1` against `--jobs=8`, twice
  each, byte-compared) covers it with no new machinery once a platform with markup is in the corpus.
- **Identity is by site.** A template's identity — what decides whether one markup value patches
  another — is `Root.site`, never the markup's text: two branches with equal markup are two kinds
  (research 36 §4.5). A lowering may share one template *string* between sites; it may not share a
  kind.
- **Cache keys.** The compiler build id (`fast-compiler.md` §8) covers every compiled-in lowering's
  Zig source, built-in or external, beside `src/`: a lowering is part of the compiler. **No check
  result depends on a lowering** (§9.4.1), so the persistent cache's entries are unaffected by which
  one a platform selects. No emitted byte is cached today; when one is, an emit unit's key includes
  the lowering's name, its interface version and the build id.

### 9.7 What does not move

- **The four checks of §4, exactly.** The markup runtime is a sibling and meets checks 2, 3 and 4
  (§9.4.5); a payload extractor is a `foreign` and meets all four (§9.3). Vocabulary declarations carry
  no JavaScript and are checked as beni. No new route from user code to JavaScript exists: a program
  writes markup; a platform lowers it through the runtime it ships.
- **Purity at load.** A lowering's hoisted declarations are pure, its emitted code runs only when the
  program calls it, and program-start work goes through `start` in the entry file (§9.4.5). So
  `backend.md` §9's rule — an unreachable declaration is dropped whole, and loading a module does
  nothing — holds for markup with no exception.
- **Privilege is a role.** Writing a vocabulary, like writing `foreign`, is what a platform package
  may do and an ordinary module may not (§2). Writing a lowering is what a platform author who builds
  their own beni may do; it adds a way to emit markup, never a rule of the language.

## Appendix — what is deliberately not done

- **User-writable `foreign`.** It has never been made safe in any of the fourteen languages surveyed,
  and the wall is the product.
- **A synchronous port variant.** Three independent mechanisms in Elm exist to prevent it, and the
  failure class it admits is the one nothing can catch.
- **A synchronous escape hatch "just for core".** Core is where the bugs in §4.1 were.
- **Settling for opaque-JSON-only ports.** That is the status quo, and it is the *unchecked* path.
