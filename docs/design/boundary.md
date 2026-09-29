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

*Added 2026-09-29.* **The four checks read the file on disk; what a `--release` build writes is
compacted and cut** to the exports the build imports (`backend.md` §9, *Hand-written JavaScript
under `--release`*), by a third lexical reading of the same kind as checks 3 and 4 — still no
parser. A development build writes the file as it is. What that pass needs of a sibling is what a
sibling already is: top-level `import`s, declarations, functions and `export` lists, each ended by
its `;` or its brace. A file it cannot read exactly is written whole, never refused, so no sibling
that passes these checks fails a release build.

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

**The annotation may name an alias of the `Program`** (2026-09-29, taken by the project's manager on
the owner's delegation; reversible, `plans/browser-decisions.md`). An alias is the same type, so
refusing `main : Tea.Program` where `type alias Program = Browser.Program` protected no guarantee
(CLAUDE.md rule 7). The comparison looks through every alias at the annotation's root, parameters
included — `type alias Same a = a` with `main : Same Node.Program` is a program — and compares the
nominal type it arrives at with the manifest's `program`; `main_not_program` still names the type
as it was written. Until then the annotation was compared by name, as written.

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

*Revised 2026-09-29, after the specification review.* The `markup` key is inherited field by field,
so `html` declares the vocabulary and `browser` and `node` the lowering (§9.1–§9.2); the program
runtime and the markup runtime may be one file, which is how a browser program's `send` reaches its
delegated listeners (§9.2); a vocabulary declares **markup primitives**, bound to the markup runtime,
which is how one vocabulary serves every lowering, and a `foreign` may not carry one lowering's
markup into another (§9.3); the tree and the context are defined in full, with rows of every shape,
interleaved items and the `Show` node (§9.4.2–§9.4.3); host access is restated as what emitted code
really does (§9.4.4); start data has one shape (§9.4.5); and the interface is versioned so that an
addition breaks no lowering (§9.4.6, the owner's answer).

### 9.1 Layers, and a platform that depends on a platform

| Layer | Is | Knows |
|---|---|---|
| **the language** | the compiler: syntax, types, guarantees, the markup tree, JSX's character references | no architecture, no HTML vocabulary, no host |
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
| `html` | — | the HTML vocabulary: elements, attributes, events, the markup primitives `text` and `map`, the markup type `Html msg` (§9.3), and in its Zig the HTML parser's table (§9.5). No `program` and no lowering; it is only depended on |
| `browser` | `html` | DOM capabilities, a low-level `Program` and its runtime, the `dom` lowering; re-exports `Html` |
| `browser-tea` | `browser` | The Elm Architecture in beni over `browser`'s `Program`; re-exports `Html` and `browser`'s modules |
| `node` | `html` | today's Node platform, plus the `ssr` lowering, so a `view` renders to a string under Node and `tests/corpus/run/` can test it (research 36 §5.5); re-exports `Html` |

**Why `html` is a platform of its own**, and not part of `browser` and `node` each: a view module
must check once and build under both (§5.3's full-stack case, research 36 §5.5), and it can only if
both builds type it against **one** vocabulary module and **one** `Html` type — two copies would be
two unrelated types, and a view written for one would not check against the other. The layer holds
exactly what the two lowerings share, which is also where the HTML parser's table lives (§9.5). It
costs one more manifest and nothing at run time. It is recorded as a decision for the owner in
`plans/browser-platform.md`.

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
  module is the same module, reached by its own name. **So `node` and `browser` list `Html`**: a
  program under either writes `view : Model -> Html Msg` and calls `Html.map`, and the markup it
  writes needs no import (`frontend.md` §9.8) but its annotations and calls do.
- **The output keys** — `program`, `runtime`, `entry` and each field of `markup` (§9.2) — are each
  taken from the top platform when it declares them, otherwise from its dependencies in the chain's
  order, first found, **field by field**. `program` may name a type of any module of the chain. So
  `browser-tea` declares none of them: its `Tea.element : { init, update, view, subscriptions } ->
  Browser.Program` is beni over `browser`'s capabilities, and the build's `Program`, `runtime` and
  lowering are `browser`'s, its vocabulary `html`'s.
- **A chain with no `program`** — `html` alone — is a platform to check against and to build a
  library with, not to build a program with: `check --platform=html` types markup, `build
  --library --platform=html` builds a library (and refuses one whose markup survives, since `html`
  names no lowering: `unknown_markup_lowering`, §9.2), and `build --platform=html` without
  `--library` is an exit-2 manifest failure naming the platform and saying it has no `program` and
  is only depended on, before anything is read.
- **Output.** The top platform's modules, siblings and runtime go to `_platform/` as today; a
  dependency platform's go to `_platform/_<name>/`, a path no module can reach (`backend.md` §2,
  rule 1), so the existing output of a one-platform build does not move by a byte.
- **A sibling still may not import another file** (`backend.md` §2), across packages as within one.
  So a layered platform shares code with its base through beni, never through JavaScript — which is
  why TEA is a beni library over `browser`'s `foreign`s rather than a runtime of its own.

*As built, 2026-09-29* (`src/platform.zig`, `src/resolve/Graph.zig`). Where the list above left a
choice, the smallest reading, and these are they:

- **The chain is read before any source**, by every command that takes `--platform` (`build`,
  `check`, the resolving `dump` stages), so every manifest failure — an unknown dependency, a cycle,
  a lowering and a runtime from two packages (§9.2) — is the exit-2 line before a byte of source is
  read. A chain holds at most 64 packages.
- **A dependency's path** is joined to the naming package's root and resolved lexically
  (`top/../base` is `base`), since the compiler composed it; its identity, for "reached twice is one
  package" and for the cycle, is its real path. An embedded platform's dependencies are embedded
  platforms, named by name.
- **`_<name>`** is the dependency's manifest `"name"`, else the spelling that reached it.
  *Amended 2026-09-29:* else the last segment of the directory that holds it, and in either
  case one plain directory name — ASCII letters, digits, `-`, `_` and `.`, beginning with a
  letter or a digit — unique within the chain, ASCII case folded. A name that is not one
  (`"x/../../../esc"`, which wrote outside `--out`) and two dependencies that would share a
  directory (two packages both named `lib`, which merged into `_platform/_lib/`) are each an
  exit-2 manifest failure before a source is read. The spelling was a path, `_../base`, for a
  dependency named by one and carrying no `"name"`.
- **A platform module that imports a module of a platform it does not depend on**, and a program
  that imports a dependency's module no platform re-exports, get `unknown_module` naming the
  platform that has it and the key (`"platforms"` or `"reexports"`); the name falls through to core
  as if the platform had not declared it.
- **A `"reexports"` entry that names no module the listing platform can import** exposes nothing
  and is not reported: a program that imports the module meets the message above, which names the
  key.
- **`check --platform` needs no `program`** from any chain; a program build needs both `program` and
  `runtime` (the old "does not declare what `main` is" line), and a chain with no `program` at all
  gets the "only depended on" line of the list above.

*As built, 2026-09-29, for `browser-tea`* (`platforms/browser-tea/`). It ships as the table says —
depends on `browser`, declares no output key and no `"zig"`, and writes no JavaScript — with three
readings of the example above:

- **`"reexports"` is `["Html", "Browser"]`.** There is no `Browser.Dom`: `browser` ships one module,
  and the example named one that had not been written. A program imports `Browser` for its
  annotation, `main : Browser.Program`.
- **The program is `Tea.sandbox { init, update, view }`**, not `Tea.element { init, update, view,
  subscriptions }`: `subscriptions` and the commands of `init` and `update` are effects (W6, W7) and
  arrive with them, when `Tea.element` is written over the same `Program`. Until then `sandbox` is
  `Browser.program` under The Elm Architecture's name, one function of beni, and the empty mounted
  page costs one module more than `browser`'s (`bench/size.mjs`'s `page` lines).
- **`Tea` declares no alias of `Browser.Program`.** `main`'s annotation is compared with the
  manifest's `program` as written (§5), not through aliases, so `main : Tea.Program` would be
  `main_not_program`. Whether that comparison should see through an alias is not settled here.
  *Settled 2026-09-29*: §5 now compares through aliases, and `Tea` declares `type alias Program =
  Browser.Program`, so a TEA program writes `main : Tea.Program` without importing `Browser`
  (`tests/corpus/browser/tea/TwoPrograms`, which imports it for `Browser.mountAt`).

### 9.2 The `markup` manifest key

```json
"markup": { "vocabulary": "Html", "type": "Html.Html" }          -- html
"markup": { "lowering": "dom", "runtime": "runtime.js" }          -- browser: the same file as its "runtime"
"markup": { "lowering": "ssr", "runtime": "markup.js" }           -- node
```

| Field | Is | Checked |
|---|---|---|
| `lowering` | the name of a markup lowering compiled into this beni binary (§9.5) | when the platform is loaded: an unknown name is **`unknown_markup_lowering`**, reported against `<platform root>/beni.json` at `1:1` with no excerpt, the shape `invalid_entry_file` uses, and the message lists the lowerings this binary has. A `build` in which a markup root or a markup primitive survives and whose chain names **no** lowering is the same code, against the top platform's manifest, saying none is named |
| `vocabulary` | the module of the chain that holds the `pub element`, `pub attribute`, `pub event` and `pub markup` declarations | when a module uses markup: a name that is no module of the chain is `no_markup_vocabulary`, whose message names this key |
| `type` | the markup type: a `pub foreign type` of one parameter, in any module of the chain | likewise |
| `runtime` | the **markup runtime**, a JavaScript file of the package that declares this field, whose exports are the lowering's well-known entry points and the vocabulary's primitives (§9.4.5) | by §4's checks 2, 3 and 4, exactly as a sibling (§9.7), whenever `lowering` is checked |

Each field is inherited on its own (§9.1): `browser`'s build has `html`'s `vocabulary` and `type` and
its own `lowering` and `runtime`. A chain with no `vocabulary` has no markup: a program that writes
some is `no_markup_vocabulary`. Two platforms of a chain may both declare `lowering` — `node` and
`browser` do, over one `html` — and the first found wins, which is how one vocabulary is lowered two
ways. A `lowering` and its `runtime` must come from one package, since the runtime is written for the
lowering; a chain in which the first `lowering` found and the first `runtime` found are declared by
different packages is an exit-2 manifest failure naming both.

**The markup runtime may be the program runtime.** When the package's `"runtime"` (§5.2) and
`"markup".runtime` name the same file, it is one sibling: copied once, checked once, and its exports
must be exactly the union of `run` and the markup runtime's list (§9.4.5). **`browser` does this, and
must**: a delegated listener, which the markup runtime installs, has to deliver a message to the
program's `send`, which the program runtime owns, and a sibling may not import another file
(`backend.md` §2). So the one file owns the program loop, the render loop and the DOM patching, and
nothing crosses between two files at run time (`backend.md` §15.11). `node` needs no such sharing — a
string renderer sends nothing — and keeps `markup.js` beside `runtime.js`.

### 9.3 The vocabulary, and why it is not `foreign`

A platform package declares its markup vocabulary with `language.md` §11.14's four forms. The first
three **carry no JavaScript**: an element, an attribute and an event have no run-time existence of
their own, so as `foreign` values §4's check 2 would demand an export for each and there is none to
write (research 36 §5.4). So they are a declaration form of their own, privileged like `foreign` —
legal only in a platform package (`vocabulary_outside_platform`) — and they leave check 2 exact
(research 36 question 1, accepted).

**The facts are the lowering's data.** The language fixes the set of fact words and what the
checker reads (`void`, `on`, the value and payload types, `via`, `classes`, `styles` for typing, and
`raw` for its warning, `checker-v2.md` §25.2); what `property`, `stateful`, `url`, `raw`, `classes`,
`styles`, `delegated`, `preventDefault`, `stopPropagation`, `name`, `svg` and `mathml` do to a page is
each lowering's to define, and a lowering that has no use for one (`ssr` and `delegated`) defines it
as nothing. **Every lowering must write the seven value classes** — `String`, `Int`, `Float`, `Bool`,
`Maybe String`, and the class and style lists of `language.md` §11.19 — since those are what the
checker admits, and must give the two lists the meaning §11.19 states, so that a page says the same
thing whichever lowering built it. Growing the fact set is a change to this section and a minor
version of the lowering interface (§9.4.6).

**A payload extractor is an ordinary `foreign`.** `pub event "onInput" delegated via targetValue :
String` names `foreign targetValue : Event -> String` of the same module, which is bound to an
export of the module's sibling and held to all four of §4's checks like any other. So the one piece
of a vocabulary that runs JavaScript at an event is exactly as walled as everything else that does.

**A markup primitive binds to the markup runtime, not to a sibling.** `pub markup map : Html a,
(a -> b) -> Html b` in the vocabulary module is a value whose implementation is the export `map` of
**the build's markup runtime** — whichever lowering's runtime that is. It is held to the four checks
as a `foreign` is, against that file: check 1 on its type (a function, so shape (a)), check 2 by
being part of the runtime's export list (§9.4.5), check 3 on the file, and check 4 on the export's
parameter count. That is how **one vocabulary serves every lowering**: a `foreign` of `html` would
bind to `html`'s one sibling, which cannot know whether the build wants a `dom` block or an `ssr`
string, while a primitive is implemented once per lowering, in the runtime written for it. `html`
declares `text` and `map` (`language.md` §11.13); every lowering that serves `html` implements both
(`backend.md` §15.3, §15.6). The wall does not move: a primitive is platform code bound to a
platform file under the same checks, and no program can write one.

**A `foreign` may not carry markup across lowerings.** A `foreign` whose type mentions the markup
type builds or reads the markup representation of one lowering, so it is legal only in a platform
package whose own manifest names a `lowering`, and only in a build whose lowering is that one
(`markup_type_in_foreign`, `checker-v2.md` §25.2). `browser`'s `Program` constructor, which receives
`view`, and `node`'s `render : Html msg -> String`, which reads an `ssr` string, are legal; the same
declarations in `html`, or `browser`'s under a platform that layered another lowering on top of it,
are refused. This is the guarantee that a program checks against `html` and then builds, under any
lowering, into a page whose every markup value was made by that lowering.

**Where HTML's parser rules live.** Void elements as the parser sees them, implied end tags, table
foster-parenting, `<a>` inside `<a>` — facts about `innerHTML`, not about a vocabulary — are a fixed
table used by the lowerings and kept in `html`'s Zig, so `dom` and `ssr` share one copy (§9.5); never
the language's or the vocabulary's (research 36 question 2, accepted; `backend.md` §15.3). Typed
content categories, which would make misnesting a type error, are later (research 27 §6.12). **HTML's
character references are not here**: they are JSX's text syntax, decoded by the compiler before any
lowering sees the text (`language.md` §11.4, `frontend.md` §9.7).

*As built, 2026-09-29, for §9.2–§9.3* (`platforms/html/`, `src/js/Emit.zig`, `src/platform.zig`).
The smallest readings, and what waits for the lowering interface:

- **`html` ships**, with the HTML vocabulary, `Html msg`, the `Event` object type, the primitives
  `text` and `map`, and the extractors `targetValue` and `targetChecked` in its sibling. **`node`
  depends on it and re-exports `Html`, and names no `lowering` yet**: its `ssr` lowering, its markup
  runtime and `html`'s `"zig"` key with the parser table arrive with the interface (§9.4–§9.5). Until
  then a manifest's `"zig"` key is ignored like any unknown key, and no `browser` platform ships.
- **This binary has no lowering**, so any `"lowering"` a chain names is `unknown_markup_lowering`,
  checked by `check --platform` and `build` alike, and the message says the binary has none.
- **A surviving primitive in a chain that names no lowering** is `unknown_markup_lowering` against
  the selected platform's manifest, one diagnostic naming the first surviving primitive in module
  order. A surviving markup ROOT cannot occur yet: a module that writes markup does not check
  (`frontend.md` §9.7's stop, amended there).
- **The vocabulary module and the markup type** are looked up among the chain's modules when the
  graph is built: `"vocabulary"` names a module, `"type"` a `pub foreign type` of one parameter as
  `Module.Name`. Either failing leaves the build without a vocabulary, and a module that writes
  markup gets `no_markup_vocabulary` naming the key; its message says "this build's platform", not
  the platform's name, which the checker is not given.
- **The markup runtime's checks** (§9.4.5), and the primitives' binding to it, arrive with the first
  lowering.

*As built, 2026-09-29, once markup is typed* (`checker-v2.md` §25, *As built* for §25.3–§25.9):
the "cannot occur yet" above no longer holds. **A surviving markup root in a chain that names no
lowering** is `unknown_markup_lowering` against the selected platform's manifest, like a surviving
primitive and in the same walk: one diagnostic, naming the first declaration in module order that
writes surviving markup or is a surviving primitive. **`markup_type_in_foreign`** (§9.3) compares
the build's lowering — the first `"lowering"` a package of the chain names — with the one the
`foreign`'s own package names, which the graph carries per package.

*As built, 2026-09-29, with the first lowering* (§9.4–§9.5): the first bullets above are
superseded. **`node` names the `ssr` lowering** and its markup runtime, `markup.js`, beside its
program runtime; **`html`'s `"zig"` key** names its parser table; and the binary has `ssr`, which
`unknown_markup_lowering` now lists. **`node`'s `render` is `Ssr.render`**, a `foreign` of a module
of its own, `Ssr`, rather than of `Node` as `backend.md` §15.6 wrote it: a module that imports
`Html` has the vocabulary checked in every build that imports it, and every program built for
`node` imports `Node` — measured, that was about 350 million instructions per compiler run, for
programs that write no markup. A program that renders a view imports `Ssr`.

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
  exceptions are §9.4.7's `markup_restructured` and §9.4.6's `markup_feature_unsupported`, both
  `build` diagnostics, and §9.4.5's runtime checks, which `check --platform` runs as it runs §4's.

#### 9.4.2 The typed markup tree

The compiler hands a lowering one `Tree` per module. Its shape, as the interface module declares it
(`src/markup/Interface.zig`, imported by a lowering as `beni_markup`; the names are the contract of
interface version 1.0, §9.4.6). **Every enumeration is non-exhaustive** (`enum(u8) { …, _ }`), so a
lowering's `switch` over one needs an `else` prong and compiles unchanged when a later minor version
adds a member (§9.4.6); nodes, rows and items are read through accessors, never as a Zig
`union(enum)`, for the same reason.

```zig
pub const version: Version = .{ .major = 1, .minor = 0 };
pub const Version = struct { major: u16, minor: u16 };

pub const Tree = struct {
    roots: []const Root,          // in instruction order: the module's markup sites
    rows: []const Row,            // For rows and Show bodies
    nodes: []const Node,          // every Node.Index points in here
    items: []const Item,          // attributes, escapes and events, in source order per element
    entries: []const Entry,       // class and style lists written in place (language.md §11.19)
    props: []const Prop,
    children: []const Node.Index, // ranges of children, in source order
    strings: Strings,             // markup names, text, constants: UTF-8, text already trimmed and decoded
    vocabulary: Vocabulary,       // the rows the nodes name, with their facts
    requires: Version,            // the newest interface feature this tree uses (§9.4.6)
    // accessors: tree.element(n), tree.fragment(n), tree.text(n), tree.hole(n), tree.component(n),
    // tree.for_(n), tree.show(n), tree.item(i), tree.entry(i), tree.string(s) []const u8, …
};

pub const Site = struct { module: u32, inst: u32 }; // module index, instruction index (backend.md §15.2)

pub const Root = struct {
    site: Site,
    kind: enum(u8) { expression, row_markup, row_lambda, _ },
    node: Node.Index,             // the markup; `.none` for row_lambda, whose last value is its result
    values: Value.Range,          // the values this root evaluates, in evaluation order (language.md §6)
};

pub const Row = struct {          // a For row or a Show body: the function applied per item
    site: Site,                   // the row function's instruction
    kind: enum(u8) { markup, lambda, function, _ },   // frontend.md §9.7's shapes
    body: Root.Index,             // markup: a row_markup root; lambda: a row_lambda root; function: unused
    function: Value.Index,        // function: the row function, a value of the enclosing root
    arity: u8,                    // 1 (item) or 2 (item, position; For only)
    reads_index: bool,            // the body uses the position
    captures: Value.Range,        // values of the enclosing root: the locals the body uses, whole
    inputs: Value.Range,          // values of the enclosing root: what a skip compares besides the item
};                                //   and the position (language.md §11.9); function: [function]

pub const Node = struct {
    kind: Kind, payload: u32,
    pub const Kind = enum(u8) { element, fragment, text, hole, component, for_, show, _ };
};
pub const Element   = struct { row: ElementRow, items: Range, children: Range };
pub const Fragment  = struct { children: Range };
pub const Text      = struct { text: Strings.Index };            // trimmed and decoded: the page's text
pub const Hole      = struct { value: Value.Index, kind: HoleKind, call: ?Call = null };  // call: 1.1
pub const Call      = struct { callee: Value.Index, args: Value.Range };               // 1.1
pub const HoleKind  = enum(u8) { text_string, text_number, text_char, text_bool, html, maybe_html, list_html, _ };
pub const Component = struct { props: Range, spread: ?Value.Index, children: ?Value.Index };
pub const For = struct {
    each: Value.Index, fallback: ?Value.Index,
    mode: enum(u8) { key, position, reference, _ }, key: ?Value.Index,
    item_is_primitive: bool, row: Row.Index,
};
pub const Show = struct {
    when: Value.Index, fallback: ?Value.Index,
    mode: enum(u8) { key, identity, _ }, key: ?Value.Index,
    value_is_primitive: bool, body: Row.Index,
};

pub const Item = struct {         // one attribute, escape or event, in source order
    kind: enum(u8) { attribute, escape, event, _ },
    name: Strings.Index,
    attribute: AttributeRow,      // attribute: its row; escape, event: unused
    event: EventRow,              // event: its row
    class: Class,                 // attribute, escape: the value class checker-v2.md §25.7 recorded
    form: enum(u8) { message, payload, _ }, // event
    value: ItemValue,
};
pub const Class = enum(u8) { string, int, float, bool, maybe_string, class_list, style_list, _ };
pub const ItemValue = struct {
    kind: enum(u8) { constant, dynamic, entries, _ },
    constant: Constant,           // constant: known at compile time (language.md §11.5)
    dynamic: Value.Index,         // dynamic: the value (for an event, the handler)
    entries: Range,               // entries: into Tree.entries
};
pub const Constant = struct {
    kind: enum(u8) { string, number, bool, _ },
    text: Strings.Index,          // string: its text; number: its JavaScript spelling
    bool: bool,
};
pub const Entry = struct { name: Strings.Index, value: ItemValue }; // value: constant or dynamic
pub const Prop  = struct { field: Strings.Index, value: Value.Index };

pub const Value = struct {        // an opaque handle: the compiler maps it to the instruction computing it
    pub const Index = enum(u32) { _ };
    pub const Range = struct { start: u32, len: u32 };
};
pub const Range = struct { start: u32, len: u32 };
pub const Strings = struct {
    bytes: []const u8, spans: []const Span,
    pub const Index = enum(u32) { _ };
    pub fn get(s: *const Strings, i: Index) []const u8;
};
pub const Vocabulary = struct {   // only the rows this module's nodes name, re-indexed densely
    elements: []const ElementFacts, attributes: []const AttributeFacts, events: []const EventFacts,
};
pub const ElementRow = enum(u32) { _ };   // into Vocabulary.elements; likewise AttributeRow, EventRow
pub const ElementFacts = struct {
    name: Strings.Index, void: bool, namespace: enum(u8) { html, svg, mathml, _ },
};
pub const AttributeFacts = struct {
    name: Strings.Index,
    property: ?Strings.Index,     // `property`: the JavaScript name (the attribute's own name when unnamed)
    stateful: bool, url: bool, raw: bool, classes: bool, styles: bool,
};
pub const EventFacts = struct {
    name: Strings.Index, dom_name: Strings.Index,
    delegated: bool, prevent_default: bool, stop_propagation: bool, has_extractor: bool,
};
```

What the tree **is**: every fact about markup the checker decided (`checker-v2.md` §25.7) and every
fact of the file's markup lowering read (`frontend.md` §9.7), in the shape a lowering walks, and
nothing about beni it does not need. What it **is not**: a place to find types, `Bir`, other modules
or the program's expressions. **A value is a handle, never an expression**: the lowering never sees
the beni code that computes an attribute or a hole — the compiler evaluates a root's values where the
program evaluates the root, binds each to a name, and the lowering refers to one by
`cx.value(v)` (§9.4.3). That is what makes evaluation order and "exactly once" the compiler's
obligation rather than every lowering's, and it is why a hole's expression can hold anything the
language allows, markup included, with the lowering none the wiser: markup inside a value is its own
root, lowered first, and arrives as a value. **A `Show` has no special representation of `Maybe`**:
`when` is a value, and the lowering asks the compiler to test and unwrap it (`cx.maybe`), because
`Maybe`'s representation is the backend's (`backend.md` §4) and not the lowering's.

#### 9.4.3 The builder surface

A lowering is a value of this type:

```zig
pub const Lowering = struct {
    name: []const u8,                       // what a manifest's "lowering" names
    targets: Version,                       // the interface version written against (§9.4.6)
    runtime: []const RuntimeExport,         // §9.4.5
    module: *const fn (cx: *Context, tree: *const Tree) Error!void,
    root: *const fn (cx: *Context, tree: *const Tree, root: Root.Index) Error!Expr,
};
pub const Error = error{ OutOfMemory, Reported };
```

- **`module`** runs once per module before any of its roots, and **hoists** what the module needs —
  a template constant, a template kind with its mount and patch functions, a row's pair.
- **`root`** runs where the program evaluates a root of kind `expression`: the compiler has already
  emitted the statements that evaluate the root's values in order and bound each to a `const`; the
  lowering returns the expression the root evaluates to — a block, a string, a tree node, whatever
  its representation of the markup type is.
- **Rows** are the one place a lowering places beni code itself, inside a function it builds.

**The context** — everything a lowering may do, and there is nothing else:

| Call | Does |
|---|---|
| `cx.build` | the build's options, read-only: `.release` (`--release`) and `.library` (`--library`, which has no program start, §9.4.5) |
| `cx.js` | the restricted `JsIr` builder, below |
| `cx.at(node)` | the markup node every following JavaScript node is positioned at, so a source map can point a hole's update at its hole (`backend.md` §11) |
| `cx.fresh(hint) Name` | a local name, unique in the module |
| `cx.hoist(hint, init: Expr) Name` | a module-level `const` whose initialiser must be **pure** (literals, object and array literals, arrows, calls of the runtime's `template`, which is pure to create, `backend.md` §15.3), emitted in hoist order after the module's imports — because `backend.md` §9 drops and keeps declarations on the premise that loading a module does nothing (§9.7) |
| `cx.hoistFunction(hint, params, body: Block) Name` | a module-level function declaration, hoisted likewise |
| `cx.runtime(name) Name` | the import of one of the lowering's declared runtime exports (§9.4.5); nothing else can be imported |
| `cx.value(v) Expr` | the name value `v` is bound to — in `root`, a value of that root; inside a function a row was placed in, a value of that row's root, or a capture |
| `cx.rowValues(block: *Block, row, item: Name, index: ?Name, captures: []const Name) Error!?Expr` | emits the row's root's values into `block`, with the item, the position and each capture bound to the names the lowering chose, so that `cx.value` answers inside `block`; returns the result of a `lambda` row, `null` for a `markup` row. At most once per call of the function it is placed in |
| `cx.call(callee: Expr, args: []const Expr) Expr` | a call of a beni function value — a `function` row, a key function, an `Html.map` function — with the arity the tree records; beni functions take their arguments directly (`backend.md` §6) |
| `cx.componentCall(node) Expr` | the component's call: the props record built exactly as `backend.md` §4 builds a record literal (or a record update over the spread), and the call with its evidence (`checker-v2.md` §25.5); the lowering decides when to evaluate it |
| `cx.extractor(item) ?Expr` | the event's payload extractor, imported as any `foreign` is |
| `cx.maybe(e: Expr) Expr` | the payload of a `Just`, or `null` for `Nothing`: the one representation fact a lowering needs, kept the backend's |
| `cx.start(key, value)` | contributes one pair of start data (§9.4.5) |
| `cx.report(node, message) error{Reported}` | reports `markup_restructured` (§9.4.7); the lowering then returns the error, and the build writes nothing |

`Name` is a `JsIr` name index, `Expr` a `JsIr` expression node, `Block` an appendable list of
`JsIr` statements (`cx.js.block()`).

**`cx.js` is `JsIr` restricted** to what a template needs. Expressions: a name the lowering was given
or made (`cx.fresh`, `cx.hoist`, `cx.hoistFunction`, `cx.runtime`, `cx.value`, a function's own
parameters); number, string and template literals, `true`, `false`, `null`, `undefined`; a call; a
property read by a constant name (`member`) or by an index expression (`index_get`); object and array
literals; an arrow; a conditional; the binary operators `===`, `!==`, `&&`, `||` and `+`; the unary `!`
and `typeof`. Statements: `const`, `let`, **assignment** (to a local, a member or an index), `if`,
`return`, an expression statement, a block, and function declarations only through
`cx.hoistFunction`. Not: `import`/`export` (the compiler writes those), loops, `switch`, `break`,
`throw`, generators, spread. **Assignment is a statement, never an expression**: `JsIr` has
`assign_stmt` and no assignment expression (`src/js/JsIr.zig`, `Tag`), and the builder adds none,
because `Opt`'s rewrites and `Print`'s precedence table would both have to learn one. So Solid's
`v !== h && (n.data = h = v)` is written `if (v !== i.h) { i.h = v; n.data = v; }`, which prints to
the same work (`backend.md` §15.3). **A loop is the runtime's**: iterating a list — a `For`, a
`List (Html msg)` hole, a class list that is not a literal — is a runtime export's job, because the
runtime is where the cons-list representation is read (`backend.md` §15.6), and it keeps a lowering
from needing the representation.

#### 9.4.4 What a lowering may not do

- **Name a host global, or reach the host any way but through what the runtime hands it.**
  `document`, `window`, `Node`, `globalThis` — none is reachable through the builder: there is no way
  to spell an identifier the lowering was not given. **Emitted code touches only objects the runtime
  returned to it** — the nodes `template`'s cloner and a slot hand back — and on those it walks
  (`.firstChild`, `.nextSibling`), writes (`.data`, `.$$click`, a declared `property`, `setAttribute`,
  `classList.toggle`, `style.setProperty`) and nothing else: the operations `backend.md` §15.3's table
  names. A node is a capability the runtime granted, in §5's sense — the program cannot forge one — so
  **the rule is that all host *authority* comes from a sibling**: the only JavaScript that names the
  host, reads a global or imports a host module is a sibling, whose imports §4's check 3 reads. The
  node-level writes stay in emitted code on purpose, since routing each through a runtime call is the
  cost Solid's compiler exists to remove (research 36 §4.1). This is a discipline for trusted code,
  not a sandbox (§9.5): a node leads to its document, and a lowering that walked there would be
  reaching the host behind the runtime's back; such a walk is a review failure, and the differential
  oracle's walks (`backend.md` §15.10) are where it would show.
- **Import anything but its own runtime.** `cx.runtime(name)` imports one of the lowering's declared
  well-known exports from the platform's markup runtime, and nothing else can be imported.
- **Emit text.** There is no raw-JavaScript node; a string literal is data.
- **Evaluate a value twice, or out of order, or run code at load.** Values are evaluated by the
  compiler; a row's at most once per call (§9.4.3); a hoisted initialiser is pure.
- **Read anything but its arguments**: no file, no environment, no clock, no randomness, no other
  module's tree, no global or `threadlocal` state — the determinism rule (§9.6).
- **Change what a program means.** A lowering chooses representation and never semantics: it renders
  every node, every value and every event the tree describes, gives the two lists and the
  character-decoded text the meaning `language.md` §11 states, and skips only what `language.md`
  §11.11 allows (a component whose props are all identical, a helper call in a hole whose arguments
  are — *amended 2026-09-29*, `language.md` §11.6 — a row or `Show` body whose inputs are). It
  reports no diagnostic but §9.4.7's.

#### 9.4.5 The runtime's well-known exports

A lowering declares the exports its emitted code imports, each with its parameter count:
`RuntimeExport{ .name = "template", .arity = 2 }`. **The markup runtime's exports are that list,
plus one per markup primitive the build's vocabulary declares, plus `run` when the file is also the
program runtime** (§9.2). The compiler checks the file against that union with §4's check 2 (exactly
these exports, no more, no fewer), check 3 (its references are covered by its own imports) and check
4 (each export takes the declared count — a primitive's from its type — written in one of §4's
accepted forms). A primitive whose name is one of the lowering's own exports is
`duplicate_declaration` at the primitive. Those names are the compiler's contract with the platform
in the same way `eq` and `compare` are with a type (`static-dispatch-spike.md` §3.2), except that here
the contract belongs to the lowering: `backend.md` §15 lists `dom`'s and `ssr`'s. `check --platform`
runs these checks too, as it runs §4's.

**Program start.** A lowering may contribute **start data**, one pair at a time: `cx.start(key,
value)`, both strings — `cx.start("delegate", "click")`. The compiler unions every surviving module's
pairs and hands them to the runtime's well-known `start` export, from the entry file, before it calls
`run` (§5.2), as **one object whose keys are sorted and whose values are sorted, de-duplicated arrays
of strings**: `start({ delegate: ["click", "input"] })`. The shape is fixed here, so every lowering's
`start` reads the same thing. That is how a platform does once, at program start, what Solid does
with a module-level `delegateEvents` call — which beni cannot do, because loading a module must do
nothing (research 36 §0 item 9c; `backend.md` §9). A `--library` build writes no entry file and calls
no `start`, so a lowering must stay correct without it; `cx.build.library` tells it which build it is
(`backend.md` §15.3 says how `dom` does).

#### 9.4.6 Versioning

**The interface is stable under additive change** (the owner's answer of 2026-09-29): an addition
keeps every existing lowering compiling and correct, and only a breaking change moves the major
version. `beni_markup.version` is `{ major, minor }`, and each version's contract is recorded here,
dated, as the section is amended. Version **1.0** is this section as written on 2026-09-29.

| Change | Is | Version |
|---|---|---|
| a new builder or `cx` call; a new field with a default a lowering may ignore; a new fact that changes nothing for a lowering that ignores it; a new runtime export a lowering may declare | additive | minor |
| a new node kind, item kind, value class, hole kind or mode — anything a lowering must handle to render the tree faithfully | additive, **gated** (below) | minor |
| removing or renaming anything; changing a field's type or meaning; changing what a fact requires of a lowering; making an ignorable fact mandatory | breaking | major |

**How a lowering declares what it targets**: `Lowering.targets`, the version it was written against.
**How the compiler checks it**, twice:

1. **At `comptime`, when beni is built**: `targets.major` must equal `version.major` and
   `targets.minor` must not exceed `version.minor`, or beni itself does not compile, with a
   `@compileError` naming the lowering and both versions. An external platform learns of a breaking
   change when it rebuilds beni, never from a user's build; a lowering written against 1.0 compiles
   against 1.3 unchanged, because every enumeration it switches over is non-exhaustive (§9.4.2).
2. **At `build`, per module**: the compiler records in `Tree.requires` the newest minor version whose
   gated feature the tree uses (a `Show` introduced at 1.4 would make a tree using one require 1.4).
   A tree that requires more than the lowering targets is **`markup_feature_unsupported`**, at the
   first node using the newest such feature, naming the feature, the lowering, the version it targets
   and the version the feature needs — so an old lowering never meets a node it cannot render, and
   the program is refused rather than rendered wrong. Every feature of 1.0 is available to every
   lowering, so the code cannot arise until 1.1 gates its first feature; it is appended to
   `language.md` §10's catalogue then, with its first fixture.

**Version 1.1** (*amended 2026-09-29*; additive and gated on nothing, so `Tree.requires` stays 1.0
and a lowering written against 1.0 is handed the same tree and stays correct): **`Hole.call`**, set
on an `html` hole whose expression is a saturated call of a top-level function — of any module, not
a constructor nor a markup primitive — that passes no evidence (`language.md` §11.6). `callee` is the function, a value
that evaluates nothing and **may be asked for anywhere in the module, a hoisted kind included**;
`args` are values of the root, evaluated with it in §6's order. The hole's own `value` is the call
made of those two, spelled where it is asked for — so the call is made where the lowering reads the
value, after the root's other values, which is `language.md` §6's row for it — and a lowering that
ignores `call` still renders the hole faithfully. A lowering that reads `call` may make the call
only when an argument is not `===` the one it was given last render (§9.4.4). `ssr` ignores it;
`dom` targets 1.1 (`backend.md` §15.3–§15.4).

#### 9.4.7 Diagnostics

`cx.report(node, message)` reports **`markup_restructured`**, an error, at the markup node's source
region: the one code a lowering may raise, for markup the lowering cannot represent faithfully — the
`dom` lowering's use is markup the HTML parser would rebuild differently from the tree (`backend.md`
§15.3), as Solid's compiler refuses the same (research 36 §3.4). It is reported during `build` like
any emit diagnostic: after everything is produced and before a byte is written, so a refused build
writes nothing (`backend.md` §2).

*As built, 2026-09-29, for §9.4* (`src/markup/Interface.zig`, `src/js/MarkupTree.zig`, the markup
section of `src/js/Lower.zig`, `src/js/Emit.zig`). Interface 1.0 is §9.4.2–§9.4.3 as written, with
these readings and additions, each the smallest one that let the `ssr` lowering and a toy lowering
be written against it; they are 1.0's contract:

- **The builder is a table of functions behind opaque handles.** `Name`, `Expr`, `Block` and
  `Value.Index` are `enum(u32)` handles the compiler maps to `JsIr` names and nodes; `Context` and
  `Js` call through one `VTable`, so the interface module imports nothing of the compiler and a
  lowering can spell no name it was not handed. `cx.js` builds the expressions and statements of
  §9.4.3's list and nothing else (`Js.constant`, `let`, `assign`, `if`, `return`, `expression`,
  `nested`; string, number and template literals; names, calls, member and index reads, object and
  array literals, arrows, conditionals, the five binary and two unary operators).
- **Three additions to the context.** `cx.arena`, working memory freed when the module's lowering
  ends, since a lowering keeps no state and yet builds lists; `cx.isJust(e)`, because `Maybe`'s
  payload slot is `null` for `Nothing` and for `Just ()` alike, so `cx.maybe` alone cannot tell them
  apart; and `cx.hoisted(hint)`, the name the module's first hoist under a hint was given, which is
  how `root` reads back what `module` hoisted without state of its own.
- **Two additions to the tree.** `Component.children_nodes`: the children written as markup
  between a component's tags are nodes of the tree, which the lowering renders as one markup value
  in its own representation and hands to `cx.componentCall(node, children)` — the compiler cannot
  build that value. And `Item.url`: an attribute whose row says `url`, or an escape whose name the
  checker recorded as a URL, so a lowering reads one bit. An `entries` item's `dynamic` is the list
  itself, rebuilt from its entries' values without evaluating anything twice, for a lowering that
  writes the list through its runtime rather than entry by entry.
- **What a value is.** A root's values are its instructions in `language.md` §6's order, which the
  compiler evaluates where the root is evaluated, each bound to a `const` unless it is already a
  name or a literal; a component's callee is not one (the call is built by `cx.componentCall`), and
  neither is a literal `keyed` mode. A row's captures and inputs, an entries list and a prop that is
  a constant are values too, but evaluate nothing: they are spelled where the lowering asks. A
  `lambda` row's root has one value, the lambda's body; a `markup` row's root has its markup's.
  `Row.reads_index` is the arity being 2, which is safe and says nothing more.
- **`cx.rowValues` with no captures** reads the captured locals where the function is placed — by
  closure, which is all a lowering whose rows are functions in place needs; given one name per
  capture, the locals read under those names for that function only.
- **`cx.extractor`** reports `not_implemented` for an event whose row names an extractor: its
  reachability leg (`checker-v2.md` §25.7) lands with the first lowering that calls it. `ssr` drops
  events and never does. *Amended 2026-09-29, with the `dom` lowering:* the leg is built, and
  `cx.extractor` returns the vocabulary module's value, imported.
- *Amended 2026-09-29.* **An element a pattern row matched** (`"*"`, `"*-*"`) has facts of its own
  in `Vocabulary.elements`, named as the markup writes it: `ElementFacts.name` is what a lowering
  writes, and the pattern's text is no element's name. An attribute's written name was already
  `Item.name`.
- *Found 2026-09-29, not fixed here:* `html`'s custom-element declaration, `pub element "*-*"`,
  holds two `*`, which `language.md` §11.14 does not allow, and `<my-widget>` is
  `unknown_element` under `html` today. *Fixed 2026-09-29:* §11.14 now allows any number of `*`,
  each a non-empty run, ranked by literal length with ties refused, and `<my-widget>` resolves
  to the `"*-*"` row (`tests/corpus/emit/dom/DomCustomElement`).
- **`Tree.requires`** is 1.0 for every tree. The comparison with `Lowering.targets` is made, and a
  tree a lowering does not cover is reported as `internal`, since no feature is gated yet.
- **The runtime's checks** (§9.4.5) run in `build` and in `check --platform` whenever the chain names
  a lowering this binary has and a `"markup".runtime`: an export missing is
  `foreign_export_mismatch` in the runtime file at 1:1, or at the primitive's declaration for a
  primitive; a miscounted well-known export is `foreign_arity_mismatch` at the export, a miscounted
  primitive the same at its declaration (§4's check 4 wording); an export nothing declares, an
  unbound reference and a relative import are what they are for a sibling; a primitive named like
  one of the lowering's exports is `duplicate_declaration` at the primitive.
- **Program start** is called when the lowering declares a `start` export and a module written
  imports the markup runtime; the call's keys are written as string literals,
  `start({"delegate": ["click"]});`.
- **A module whose only survivors are markup primitives** — `html`'s `Html` when a program calls
  `Html.text` and nothing else of it — is not written: its primitives are the runtime's exports and
  nothing imports the module.

### 9.5 How a lowering is compiled into beni

**No dynamic loading, ever**: a lowering is Zig linked into the binary, and a platform is trusted
code by design (the owner's decision), so the security argument is §2's — a distribution fact — and
not a sandbox.

- **A platform's Zig is one Zig module**, whose root file the manifest's optional **`"zig"`** key
  names — `platforms/browser/zig/root.zig`, say. The module's `pub const lowerings` lists the
  `Lowering` values it provides — `.{ dom }` in `browser`, `.{ ssr }` in `node` — and may be empty:
  **`html`'s Zig provides no lowering**, only the HTML parser's table, as `pub const parser_table`,
  which `browser`'s `dom` and `node`'s `ssr` both import (`backend.md` §15.3, §15.6). A platform's Zig
  module may import only `beni_markup`, `std`, and the Zig modules of the platforms its platform
  depends on (§9.1), each under the name `platform_<name>` (`-` becoming `_`), so `dom.zig` writes
  `@import("platform_html").parser_table`. The compiler's own modules are never importable from a
  platform's Zig.
- **Built in.** `build.zig` embeds each built-in platform's assets as today and, for each that has a
  `"zig"` key, adds its module with those imports. It then generates the registry the compiler reads —
  every lowering of every platform module, sorted by name, a duplicate name a build error.
- **External.** Anyone may add a platform to their own beni without editing its source, in two
  equivalent ways: `zig build -Dplatform=<dir>` (repeatable), where `<dir>` holds the platform's
  `beni.json`, its modules, siblings and the Zig its `"zig"` key names; or, from a build that depends
  on beni, `beni.addPlatform(b, .{ .dir = … })`, which does the same. The platform then ships in that
  binary exactly as a built-in one does: `--platform=<name>` finds it, its assets are embedded, its
  lowerings are in the registry, and its dependencies' Zig modules are importable if they ship in the
  same binary — an external platform over `html` imports `platform_html`.
- **A platform directory without Zig** — `--platform=<dir>` at run time, §5.3 — may still select any
  lowering the binary has by name. Only a platform that brings *new* Zig needs a rebuilt beni.

*As built, 2026-09-29* (`build.zig`, `platforms/html/zig/`, `platforms/node/zig/`,
`tests/platforms/toy/`). Where the list above left a choice:

- **The `"zig"` key is read by `build.zig` alone**, at configure time; the compiler ignores it as
  an unknown key. A platform's module is `platform_<name>`, and it imports the modules of every
  platform its manifest's `"platforms"` reach, transitively, by name.
- **The registry** is a generated module, `markup_lowerings`, whose `all` is every lowering of every
  platform module, sorted by name at compile time; two of one name, and a lowering whose `targets`
  this interface does not cover, are compile errors (§9.4.6's first check).
- **`-Dplatform=<dir>`** takes the platform's name from its manifest's `"name"`, else the
  directory's; it is embedded under `platforms/<name>` as a built-in one is, and a name taken twice
  is a configure-time failure. A platform's `.zig` files are compiled, never embedded as assets.
- **`beni.addPlatform(b, .{ .dir = … })`** returns the `beni` dependency built with that one
  directory as `-Dplatform` (relative to the depending build's root); several platforms are one
  `b.dependency("beni", .{ .platform = … })` with the list.
- **The build id** hashes every `.zig` file under a compiled-in platform's directory, beside `src/`.
- **The external path is a gate**: `test-blackbox` builds a beni with `tests/platforms/toy`
  compiled in as `-Dplatform` would, at `zig-out/toy/bin/`, and
  `tests/blackbox/external_platform_test.zig` builds and runs a program for it. The toy lowering,
  written against 1.0, hoists a function in `module`, reads it back in `root` with `cx.hoisted`,
  imports `platform_html`, and contributes start data; its runtime is also the program runtime.

### 9.6 Determinism, and what the cache must know

- **A lowering is a pure function of the tree, the builder state and the build's options.** It keeps
  no state between calls, iterates no hash map, compares no pointers, reads no clock, and makes every
  name through `cx.fresh`, `cx.hoist` and `cx.hoistFunction`, which derive names from the site and a
  counter local to the module's lowering — never from a counter shared across workers, which is the
  one way a lowering could break rule 5 (research 28 §9.3). The emit workers call it for several
  modules at once, one module per call, so state kept between calls would be a data race as well
  as a determinism fault. The determinism test (`--jobs=1` against
  `--jobs=8`, twice each, byte-compared) covers it with no new machinery once a platform with markup
  is in the corpus.
- **Identity is by site.** A template's identity — what decides whether one markup value patches
  another — is `Root.site`, never the markup's text: two branches with equal markup are two kinds
  (research 36 §4.5). A lowering may share one template *string* between sites; it may not share a
  kind.
- **Cache keys.** The compiler build id (`fast-compiler.md` §8) covers every compiled-in platform's
  Zig source, built-in or external, beside `src/` — the entity table among the latter: a lowering is
  part of the compiler. **No check result depends on a lowering** (§9.4.1), so the persistent cache's
  entries are unaffected by which one a platform selects. No emitted byte is cached today; when one
  is, an emit unit's key includes the lowering's name, its targeted version and the build id.

### 9.7 What does not move

- **The four checks of §4, exactly.** The markup runtime is a sibling and meets checks 2, 3 and 4
  (§9.4.5); a payload extractor is a `foreign` and a markup primitive is held as one, both to all
  four (§9.3). Vocabulary declarations otherwise carry no JavaScript and are checked as beni. No new
  route from user code to JavaScript exists: a program writes markup and calls primitives; a platform
  lowers and implements them through the runtime it ships.
- **Where host authority comes from.** Only a sibling names the host (§9.4.4); emitted code handles
  the nodes a sibling gave it.
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
