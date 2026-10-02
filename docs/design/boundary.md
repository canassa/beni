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

*Amended 2026-09-30.* A `foreign` value also **declares its rung** — `pure`, `impure` or
`suspends` — between `foreign` and its name, and the checker infers every beni function's bits
from those declarations ([`transparent-effects-proposal.md`](transparent-effects-proposal.md)
§14.1). `pure` means total and non-throwing. The rung is a promise the platform author makes about
the sibling, like the arity check 4 counts, and none of the checks below reads the JavaScript to
test it. The rung describes the declaration's own arrow and its `where` evidence; a beni function
passed to the sibling is independent of the call until the `sync` step makes such a parameter
`sync` (P2 §14.3 rule 6).

*Amended 2026-09-30, the `sync` step* ([`transparent-effects-proposal.md`](transparent-effects-proposal.md)
§15). **A `foreign` that receives a beni function the sibling may call synchronously — during the
call, or later from an event, a render or any other host callback — declares that function type
`sync`**: `pub foreign pure onInput : sync (String -> msg) -> Attribute msg`, and inside a record
`{ view : sync (model -> Html msg), … }`. The checker then refuses, at the caller, any function that
may suspend there (`sync_boundary`), and carries the demand through every beni function the value
passes through. A function type the sibling only stores for the fiber runtime to run — a spawned
thunk, a finaliser — is left unmarked (report 43 §9.6). A `foreign`'s `where` evidence is `sync`
with nothing written, because the sibling calls it from JavaScript during the call. Like the rung
and the arity check 4 counts, the mark is a promise about the sibling; no check reads the
JavaScript to test it. `sync` anywhere else in the signature — around a type that is not a function
written out, or on a function the platform hands back — is `misplaced_sync`. *Amended 2026-10-02 (R47-4):* a platform package may also write `sync` in an ordinary beni
declaration's signature, where it demands the same of every caller
([`transparent-effects-proposal.md`](transparent-effects-proposal.md) §15.2 item 1); a user
package may not.

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

   *Amended 2026-10-02.* **A trailing run of `()` parameters may be left out.** A `foreign` whose
   annotation ends in `()` parameters — `yieldNow : () -> ()`, `start : Int, () -> Handle` — may be
   exported taking all of them or none of that run: `(unit) => …` and `() => …` both pass, and so
   does any count in between. Every call still passes `null` for each (`backend.md` §6, *A parameter
   of type `()`*), which a function that does not take it ignores, so no argument arrives nowhere —
   the one failure this check exists for. It is the same rule beni's own functions follow since that
   day, `f () = …` being `() => …`, so a runtime and a sibling agree on what `() -> a` takes. The run
   is read off the annotation as WRITTEN: a `()` before a written parameter holds its position and
   must be taken, and so must one behind an alias. `run/ForeignUnitParameters` builds a sibling of
   each shape, `build/bad/ForeignArityUnitNotLast` refuses one that drops a `()` that is not last.

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

#### How a sibling sees a `List`

*Added 2026-10-01; specified, not built* (`backend.md` §4, *Lists are arrays*; `plans/list-arrays.md`).
*Built 2026-10-01: every first-party file named below reads and returns lists this way, and so do
the test platforms' siblings.* Until now a sibling that took or returned a `List` walked or built cons cells, `{ $: 1, a, b }` and
`{ $: 0, a: null, b: null }`, by a contract written in `core/List.js`, `core/String.js`,
`core/Basics.js` and `backend.md` §4. With lists array-backed that contract is replaced by this one,
and it is the whole of what a sibling — or a platform runtime, a markup runtime, the
derived-comparison engine — may assume.

**What a sibling receives.** A `List` argument may be in any of the three forms of `backend.md` §4,
and a sibling reads it through the protocol there and nothing else: `xs.length`; `Array.isArray(xs)`
for the plain form; `xs.$plain()` for the others, a plain array it must not write. The idiom is
`const a = Array.isArray(xs) ? xs : xs.$plain();`. A sibling never writes a list it was given, never
keeps one it will later write, and never names a view's or a trie's fields: those belong to
`core/List.js`, and a platform that reached into them would break the next time the representation
is tuned.

*Amended 2026-10-01 (W35, E1tp).* The representation was tuned before it was built: a trie now has a
claimable head and a radix offset as well as a claimable tail (`backend.md` §4, *The claimable head:
E1tp*). **Nothing in this subsection changes.** A trie header still answers `length` as a data field
and `$plain()` in element order — the head's reversal and the offset are accounted for inside it — so
a sibling that follows the idiom reads a trie with a head exactly as it read one without. The two
in-place writes, head and tail, are `core/List.js`'s alone; a sibling that wrote a list it was given
would now corrupt versions at either end.

**What a sibling returns.** A `List` result is either **a fresh plain array that nothing else holds
and that the sibling never touches again** — `s.split(sep)`, `Array.from(s)`, an array it built — or
**a `List` it was given**, unchanged. An array the *host* owns is never returned as it is: a DOM
collection, an array an event carries, a buffer a callback will reuse, or any array another piece of
JavaScript may still write is copied first (`Array.from(x)`, `x.slice()`), because a list is
immutable and the host's array is not (`backend.md` §4, invariant 1). A sibling returns no view and
no trie; only `core/List.js` makes those.

**Why a protocol and not a helper.** A sibling may not import another file (`backend.md` §2), so it
cannot call `core/List.js`; and the backend reads no types, so it cannot convert a list at a
`foreign` call site. Three facts every form answers — its length, whether it is an array, and a
method that flattens it — cost a sibling one line and leave every other detail private to one file.

**The checks.** Check 1 is unchanged: `foreign xs : List a` is still refused. Checks 2, 3 and 4 are
unchanged and apply to `core/List.js` like any sibling; its core-private exports (`unsafeGet`,
`view`, `base`, `offset`, `builder`, `add`, `done`) are ordinary `foreign` declarations of
`List.beni` without `pub`, so check 2 counts them. What the protocol adds to §4.1's recipe is its
third rule, *marshal to plain data*, made specific: a list crosses as a plain array.

**The first-party files this touches**, all in `plans/list-arrays.md`'s second slice: `core/Basics.js`
(`append`'s list half, and the representation comment), `core/String.js` (`words`, `lines`, `split`,
`indexes` and `toList` return the array they make; `fromList` reads through the idiom), `core/Debug.js`
(`toString` recognises a list by `Array.isArray(v) || typeof v.$plain === "function"`),
`src/js/derived_runtime.mjs` (`listEq`, `listCompare` and their steps index a plain array),
`platforms/node/Node.js`, `platforms/browser/Browser.js`, `tests/platforms/page/Page.js`,
`platforms/browser/runtime.js` and `platforms/node/markup.js` (`backend.md` §15.5, *`For` over
arrays*). A **port**'s generated codec (§3.1) follows the same two rules: a list going out is read
through the protocol, and one coming in is a fresh array the codec built.

#### What JavaScript may read of a beni value

*Added 2026-10-01, with `backend.md` §9's* Item 4, taken up. A `--release` build renames record
fields and gives constructors integer tags wherever no JavaScript can see the difference, so
"where can JavaScript see it" is now part of this contract. **JavaScript sees the representation
of exactly the types a `foreign` annotation names, and of the type a `Js.from` or `Js.to` is
used at** — written records, named types and their bodies, transitively. Those keep their source
field names and string tags in every build.

**A type variable is opaque.** A sibling handed a value at a type variable (`foreign key : k ->
Key`), and platform code that turns one into a `Js.Value` (`Js.from msg` with `msg : msg`), may
store it, return it, compare it with `===`, and walk it reflectively — `Basics.eq`'s
`Object.keys` walk, `Hosted`'s key order — but never read a field or a tag by name: which type
it holds was never its to know, and a release build may spell that type's fields and tags
differently. A reflective walk sees the same values equal in both builds. An ORDER it imposes is
another matter, and is the one exception: a `foreign` that takes a bare type variable carrying
`compare` (`Hosted.key`) may order its values by what they hold, and a build that reaches one
keeps the names and tags of every type it compares (`backend.md` §9, *Item 4, taken up*), so the
order of keys is the same in both builds. This is parametricity, and it is what keeps a platform's
generic plumbing from pinning every program's records.

**What to do about it** is nothing new: a platform that needs to read a record by name names its
type — in a `foreign` annotation, or at the `Js.from` / `Js.to` it goes through.

### 4.1 The recipe for privileged code, written down and tested

The guarantee lives or dies in privileged code, and Elm's own has holes: a core package declares a
result type whose quantified error variable claims infallibility while its implementation listens for
an event that fires on failure too, so `null` arrives typed as a string and the next operation
throws. Well-typed code crashes. The organisation Elm's own front page cites for "no runtime
exceptions" was shipping thousands a day and fixed it by forking three core packages. **Trust is not
a mechanism.**

So the recipe is a written contract, not a convention:

- Address foreign objects by value; never hold a reference across an effect boundary. *(Amended
  2026-10-01, W52: except a handle every operation of which is total on a closed one, declared
  `equatable foreign type` — §9.8.9.)*
- Marshal every result to plain data before it crosses back.
- Every failure the specification defines is a constructor in the result type, not an exception.
- Every privileged entry point is wrapped in `try`/`catch`.

The last one is not optional and the reason is typed: an uncaught foreign throw can alter a value in
a way its type forbids, which is unsoundness rather than a crash. Gleam's core package documents
exactly this when declining to make its promise type generic over its error.

*Amended 2026-10-01 (`CLAUDE.md` rule 9, the owner's): the last bullet is replaced, and it now
reads* **every failure the host documents is caught individually, and everything else is
re-thrown.** A `catch`, or a promise's rejection handler, names what it expects — an error `code`
(`ENOENT`), a `name` (`"AbortError"`), `instanceof TypeError`, a `DOMException` — and maps each to
its constructor; anything it did not name is thrown again, unchanged. A catch-all that turns every
reason into one value (`String(error)`, `NetworkError`) is a defect: it disguises a bug in beni or in
the host as an answer the program then acts on. **An unknown error is a defect, and a defect
crashes** (`transparent-effects-proposal.md` §16.4's `Exit`, the owner's A1): on Node the error
reaches the top of the process — an uncaught exception, or a rejection nothing handles — and Node
prints it with its stack to standard error and exits 1 (§16.5, *A defect on Node*). The cancellation
a primitive asked for itself (an `AbortSignal` it aborted) is neither: the fiber was cancelled, no one
is waiting, and the answer is dropped. The testable form gains a second half: a capability whose
wrapper re-throws has a `run/` scenario that forces an error it does not name and asserts the crash
(`tests/corpus/README.md`, *A program that must crash*).

**Testable form: one corpus scenario per capability that forces the failure path and asserts a value
comes back.** A capability without that scenario is not finished. This is the discipline whose
absence produced the bug above, in the codebase that invented the wall.

**Schema format adapters** obey this privilege wall and the failure recipe
above. [`schema.md`](schema.md) §5 owns bounded JSON adaptation, fallible encode
as well as decode, and engine-owned context; §7 records the still-open H4
obligation at synchronous host boundaries. Schemas neither grant user packages
`foreign` nor replace this section's platform/main contract or ports automatically.

### 4.2 `Js`, JavaScript written from beni

*Added 2026-10-02, when the owner ordered the browser runtime rewritten in beni (`plans/browser-
decisions.md`, R47-1 and R47-2).* Core's `Js` module is research 47 §2's draft, adopted as it
stands there and with the three declarations of `Js.Ref` below: `foreign` declarations whose saturated calls the backend writes as the
JavaScript they name (`o.f`, `o.f = v`, `a === b`, `o.m(a, b)`), and whose sibling `core/Js.js`
ships only for a declaration passed as a value. **`import Js` outside core and a platform package
is `js_outside_platform`**, for the wall's own reason: `Js.to` is an unchecked cast. A module named
`Js` in the root package is an ordinary module.

**A mutable local is a `Js.Ref`** (R47-2; there is no `let mut`):

| declaration | rung | written as |
|---|---|---|
| `pub foreign type Ref a` | — | a cell holding an `a` |
| `ref : a -> Ref a` | pure | a new cell: `{ v: x }`, or a `let` |
| `read : Ref a -> a` | impure | what the cell holds: `r.v`, or the `let`'s name |
| `write : Ref a, a -> ()` | impure | the statement `r.v = x`, or `n = x`; its value `null` |

`ref` is pure because making a cell is making an object — a pure `ref` nobody reads may be dropped,
and nothing that can be dropped can be merged, since no optimiser merges two evaluations. `read` is
impure because its answer is not a function of its argument: a `read` that nothing reads may go, and
none may move past a `write`. **A cell that does not escape is a plain `let`**, a read of it the
name and a write an assignment — the shape hand-written JavaScript uses for the same thing
(`template`'s `let node = null`, the render loop's `let scheduled = false`). What "does not escape"
means, and why a closure is not an escape, is `backend.md` §4's *A `Js.Ref` that does not escape is
a `let`*; the program cannot tell the two shapes apart.

**`each : Value, (Value -> ()) -> ()`** (impure, 2026-10-02) is `for (const x of xs) f(x)`: `f`
for each element of an iterable, in order, through its iterator (`backend.md` §9, *Compact
statements*, item 4). Written with a lambda, the lambda's body is the loop's body.

**`construct : Value, List Value -> Value`** (impure, 2026-10-02) is `new c(a, b)`, its arguments a
list literal as `apply`'s are: what a constructor that must be called with `new` needs (`Map`,
`URL`), and the shape hand-written JavaScript gives an error, `throw new Error(m)`.

**`finally : sync (() -> a), sync (() -> ()) -> a`** (impure, 2026-10-02) is `try { body() }
finally { cleanup() }`: the body's value, with the cleanup run after it however it ends — on a
return, and on a throw before the throw goes on. Written with lambdas, each lambda's body is its
block and no function is made (`backend.md` §4, *`Js.finally` is `try … finally`*). Both are
`sync`, so neither may suspend: a body that parked would leave the guard before its rest ran.
There is no `catch`: a platform restores its state on the way out and lets the throw go on, which
is all the effects host needs (`plans/runtime-in-beni.md`). *(2026-10-01: so is it all the defect
rule needs, §9.8.10 (c) — a cleanup that finds its body did not complete stops the page — and what
must `catch`, `Storage`, is a sibling.)* *(Amended 2026-10-01: there is one now, `catchIf` below,
and `Storage`, `Url` and `Http` are written over it.)*

**`catchIf : sync (() -> a), sync (Value -> Bool), sync (Value -> a) -> a`** (impure, 2026-10-01,
`plans/core-in-beni.md`) is `try { return body() } catch (e) { if (!test(e)) throw e; return
handler(e) }`: the body's value, or — when it throws something `test` holds of — the handler's.
It is rule 9 (`CLAUDE.md`) as an intrinsic: **a catch names what it expects and re-throws
everything else, unchanged**, so a wrapper's test is the precise one the host API documents —
`Js.instanceOf e (Js.global "URIError")`, a `DOMException` and its `name` — and an unknown error
crashes as it would have with no `catch` at all. Written with lambdas, the body is the `try`
block, the test and the handler are the `catch` block with the lambda's parameter its binding, and
no function is made (`backend.md` §4, *`Js.catchIf` is `try … catch`*). All three are `sync`, as
`finally`'s are: a body that parked would leave the `try` with its rest outside it, where a throw
reaches no `catch`.

**`pure : sync (() -> a) -> a`** (pure, 2026-10-01) is the body's value, and the promise `foreign
pure` makes of a sibling's function — that computing it is total, throws nothing and changes
nothing an observer can see — made of beni written over `Js`, whose reads and calls the checker
otherwise infers `impure`. `String.length` is `Js.get` of `Array.from`'s `length`, and pure; written
without `Js.pure`, every function that measured a string would be `impure` in its interface and
kept by the release optimiser where it is unused (`language.md` §6, *What an optimiser may
assume*). The argument is a function handed to the intrinsic, so it joins nothing
(`transparent-effects-proposal.md` §14.3, rule 6); unchecked, like every `Js` declaration — the
caller answers for the promise. Written with a lambda, it is the lambda's body (`backend.md` §4,
*`Js.pure` is its body*).

**The operators core's arithmetic is written over** (2026-10-01): `bitOr`, `bitXor`, `shiftLeft`,
`shiftRight`, `shiftRightZero` and `rem` — `|`, `^`, `<<`, `>>`, `>>>` and `%` on two `Int`s, as
`bitAnd` is `&` — and `typeOf : Value -> Value` and `instanceOf : Value, Value -> Bool`, `typeof v`
and `v instanceof C`. Each is written in place as its operator. `rem` answers `NaN` for a zero
divisor and `shiftRightZero` an unsigned number, both of which an `Int` may not hold: the caller
guards, as `Int32.rem` does.

**`regExp : pattern, flags -> Value`** (pure, 2026-10-01) is a regular expression literal,
`/pattern/flags`, both arguments string literals: `Js.regExp "^\\d+$" ""` is `/^\d+$/`. A `/` and a
line terminator in the pattern are written as their escapes, and an empty pattern as `(?:)`; the
flags are any of `d i m s u v`, each once — `g` and `y` give the object a `lastIndex` that every
reader of one literal would share. The pattern is not checked: one JavaScript refuses stops the
file loading, as a `new RegExp` that throws stops the code that makes it (`backend.md` §4,
*`Js.regExp` is a literal*).

**`Js` names no core type but `Basics`'s and `List`'s** (2026-10-01). A property or global name and
a pattern are a type variable where the caller writes a string literal (`get : Value, name ->
Value`), and `typeOf` answers a `Value`. A module may import only a module that does not import it
back (`checker.md` §4.3), and `String` imports `Js` now; with `String` in `Js`'s signatures the two
were a cycle. What stays out of reach is below `String`: `Char`, which `String`'s signatures name,
and `Basics`, which every module's do — and a string literal written in either is a `String` the
module would depend on (`resolve/Graph.zig`, `mintedModules`), so neither can name a property.
`plans/core-in-beni.md` has what would let them.

**`Js` is exempt from the module graph** (*amended 2026-10-02*, the owner's S7 in
`plans/browser-decisions.md`), which is what lets them. Two rules together make `Js` a module every
core and platform module may import — `Basics` and `Char` included — with no import of it able to
close a cycle:

1. **`Js`'s signatures name no core type**, not `Basics`'s nor `List`'s: every position the
   paragraph above left at `Int`, `Bool` or `List Value` is a type variable — `same : a, a -> bool`,
   `bitAnd : int, int -> int`, `at : Value, index -> Value`, `call : Value, name, args -> Value`,
   `development : bool`. `Js` then names, imports and mints nothing, so it depends on no module and
   is the bottom of the core graph: an edge to it can close no cycle. The variables are unchecked, as
   everything about `Js` is; where the backend needs a list literal it still refuses anything else
   (`internal`, as before).
2. **A literal a `Js` call writes in place mints nothing** (`static-dispatch-spike.md` §6.8,
   amended): a string literal that is the name argument of `global`, `get`, `set` or `call`, either
   argument of `regExp`, and a list literal that is the argument list of `call`, `apply`,
   `construct` or `array`. The backend writes each as JavaScript syntax — a property name, a
   regular expression literal, an argument list — so no `String` or `List` value exists at run time,
   and the checker types each as a fresh type variable rather than `String` or `List a`
   (`checker-v2.md` §30), so none is visible in the module either. Only those positions, written
   there: the same literal bound to a name first, or a string handed to `Js.from`, is an ordinary
   `String` with the ordinary edge.

Both are keyed on the core package's `Js`, as `js/JsIntrinsic.zig` is: a root-package module named
`Js` is an ordinary module whose literals mint as any do. `import Js` is still written, and is still
`js_outside_platform` outside core and a platform package.

**`development : Bool`** (pure, 2026-10-01) is `True` in a development build and `False` under
`--release`; an `if` on it keeps only the branch the build takes, so a development-only
declaration — `browser`'s crash screen — is in no release build (`backend.md` §4, *`Js.development`
is the build's mode*). *(Amended 2026-10-02: it is `development : () -> bool`, written
`Js.development ()` — `Bool` is a core type `Js` may not name, and a `foreign` value that is not a
function may not be polymorphic (§4, check 1). The call is written in place as the literal, as the
value was.)*

**A `()` crossing the wall is `null` or `undefined`** (2026-10-02, `backend.md` §4's *A `()` result
is not written*). A release build writes no result for a function whose result is `()`, so a
function a platform receives through `Js.from` — an event handler, a render callback — returns
`undefined` where a development build returns `null`. A platform's JavaScript never reads what such
a function returns; a `()` it is handed, and a `()` it returns, may be either.

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

**The page that loads the program is part of that shape, and it is `"html"`** (added 2026-10-01).
It is optional and names a template file of the package — `browser` declares `"html": "index.html"`
— in which `{{entry}}` stands for the entry file; a program build writes it as `index.html` at the
root of the output. An app's own `beni.json` may name a template of its own instead. The rules — the
placeholder must occur, inheritance down the chain, what `--library` and `--release` do — are
`backend.md` §2's *The page shell*; a template that cannot be read or never names the entry is
`invalid_html_shell`.

**A `"runtime"` naming a file that is not there is `foreign_sibling_missing`, reported against the
MANIFEST.** Every other manifest failure is an exit-2 line naming the path (§5.3, `src/platform.zig`),
because a manifest is JSON and has no beni tokens; this one is a diagnostic because it is found
during emit, alongside §4's sibling checks. It therefore points at `<platform root>/beni.json` at the
whole-file position `1:1`, with no excerpt — the same shape `invalid_module_path` uses for a fault
that is about a file rather than a place inside one. *Corrected 2026-09-19: it used to be reported on
file 0, token 0, which is the first token of the USER'S source, so a fault in the platform package
put a caret under an `import` the reader wrote.*

**`"runtime"` is optional when the runtime module is the whole runtime** (*amended 2026-10-02*,
`plans/runtime-in-beni.md` step 6). A chain that declares a `"program"` needs something for the
entry file to hand `main` to: a `"runtime"` file, as above, or — when the chain names a markup
`"lowering"` and a runtime module (`"markup".module`, §9.2) and no `"runtime"` and no
`"markup".runtime` at all — the module's `run`. Such a chain has no hand-written runtime: the
module supplies `run` and every export of §9.4.5's union, and each one it does not declare as a
`pub` value with a body is `foreign_export_mismatch`, reported against the manifest that named the
module at `1:1` (a markup primitive at its declaration, as with a file) — there is no file to hold
it instead. A build writes no runtime file, and the entry file imports `run` (and `start`) from the
module's output. A chain that names neither is refused before a source is read, as before. A chain
with no `"program"` asks the module for no `run`. `browser` is such a platform since this
amendment: its `runtime.js` exported nothing once `safeUrl` moved to `Rt.beni`, and is deleted.

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
neither may perform, and everything a program performs lives in a thunk handed to the runtime.
*Given a mechanism 2026-09-30* (P2 §15): `Browser.program` declares its `update` and `view` fields
`sync` (§4), `main`'s evaluation is `sync`, and the checker refuses a suspending one at the record
field that hands it over. What
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
        Typed q       -> ( { model | q = q }, Cmd.keyed "search" Restart (λ() -> search q) GotHits )
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

*Superseded 2026-10-01 by §9.8*, the owner's W46–W55. A body is `Send msg -> ()`, not a thunk and
a tagger (`Cmd.task` is that form, defined over it); `Cmd.keyed k policy body`; keys are
`compare`-able values of any type, matched by value, and namespaced by a `Cmd.map` whose segment is
written (W47, amending W7); `Cmd.cancel` with nothing running is silent; and subscriptions are
§9.8.5's.

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

*Amended 2026-10-01: a platform the binary carries is checked as far as the program reaches it*
(the rule `checker.md` §4 gives core, amended the same day). Every package of the chain is still
enumerated, but a module of an EMBEDDED package is read, lowered and checked only when a root
reaches it through imports — and the roots of a chain are the modules its manifests name, which the
compiler reaches with no import: the module of `"program"`'s type, `"markup"`'s runtime `"module"`,
its `"vocabulary"` and the module of its `"type"`. A program for `node` that never imports `Io` or
`Ssr` does not check them; one for `browser-tea` that never imports `Random` does not check it. The
embedded packages are beni's own and are checked whole by its tests, as core is. **A platform read
from a directory is checked whole**: it is somebody's code under development, and a mistake in a
module the program does not import is still theirs to hear about, so every module of it is a root.
*Measured:* `abuse_wide_test`'s 65 600-entry derived row, checked with `--platform=node` again, is
back under its budget: 4 264 M instructions, where the whole platform made it 4 308 M, past the
4 300 M budget.

### 9.2 The `markup` manifest key

```json
"markup": { "vocabulary": "Html", "type": "Html.Html" }          -- html
"markup": { "lowering": "dom", "runtime": "runtime.js", "module": "Rt" }   -- browser: the same file as its "runtime"
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

**A runtime module: the markup runtime written in beni** (*added 2026-10-02*, `plans/browser-
decisions.md` R47-1; research 47 §6 item 1). A fifth field, `"module"`, names a module of the
package that declares `"runtime"`:

```json
"markup": { "lowering": "dom", "runtime": "runtime.js", "module": "Rt" }
```

| Field | Is | Checked |
|---|---|---|
| `module` | a beni module of the package that declares `runtime`, whose `pub` values stand in for runtime exports | when `lowering` is checked: a name that is no module of that package is `foreign_sibling_missing` against the manifest; one of another package is the exit-2 `markup_split` failure `lowering` and `runtime` already have |

- **Which exports it supplies.** Every name of §9.4.5's union — a lowering's declared export, one
  per markup primitive of the vocabulary, and `run` when the markup runtime is also the program
  runtime — that the module declares as a `pub` value with a body is supplied by the module, and
  the file supplies the rest. Check 2 holds the file to exactly the rest. *(Amended the same day,
  `plans/runtime-in-beni.md` step 2: a markup primitive was always the file's. It is supplied like
  any other name, and a use of it then reads the module's declaration — `Html.text` is `Rt$text` —
  so §9.3's "binds to the markup runtime" means the file or its module, whichever supplies it.)*
  A supplied value must take the
  declared count of parameters and no evidence (`Convention`'s arity, a trailing `()` run counted as
  written or not, as check 4 counts a sibling's), or it is `foreign_arity_mismatch` at the
  declaration. `run` takes one. The module is ordinary platform code: it may import `Js` (§4.2)
  and every module its package sees, and it may not import the file.
- **The file may import the module.** `import { first, slot } from "beni:Rt";` — the one
  specifier a hand-written file may name that is not a package, and only in the markup runtime,
  only for its own `module`. Each name must be a `pub` value of the module, or it is
  `foreign_unbound_reference` at the name; check 3 counts the import as covering them like any
  other. What the build writes for it is `backend.md` §15.1's.
- **What ships** is what is reached (`backend.md` §9's *Roots*, amended the same day): the
  module's values that the lowering imported in some module of the build, that the entry file
  calls (`run`, `start`), and that a part of the file the build keeps imports — and whatever those
  reach. Nothing else of the module is written, so a runtime can move to beni one function at a
  time without the empty page paying for the functions it does not use.

A lowering does not change: `cx.runtime(name)` answers the name emitted code reads either way, and
the lowering's `Lowering.runtime` list is its contract with both halves together.

**A runtime module with no file** (*amended 2026-10-02*). `runtime` may be left out when `module`
is given and the package names no program `"runtime"` either (§5.2's amendment): the module is
then the whole markup and program runtime, held to the whole union, and the `lowering` and the
`module` must come from one package — a chain whose first `module` is another package's than its
first `lowering` is the exit-2 `markup_split` failure. `browser` declares
`"markup": { "lowering": "dom", "module": "Rt" }` and nothing else since then.

`browser` has a runtime module since 2026-10-02: `Rt.beni` holds the slot and mount half and the
render loop, `runtime.js` the rest (`backend.md` §15.11's last amendment;
`plans/runtime-in-beni.md`). Since step 2 it also holds the `Maybe Html` hole, a text hole's node,
the attribute writes but for URLs, classes and styles, and both primitives, `text` and `map`.

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
                                  //   and the position (language.md §11.9); function: [function]
    selector: ?Selector = null,   // 1.3: the input that is a selector (language.md §11.9), if one is
};
pub const Selector = struct {     // 1.3
    input: u32,                   // its position among `inputs`
    probe: Value.Index,           // a value of the enclosing root: the one key its comparisons can hold for
};

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
from needing the representation. *(Amended 2026-10-01: once lists are arrays the runtime reads them
through §4's protocol, *How a sibling sees a `List`*, and `backend.md` §15.5's *`For` over arrays*;
the reason a loop is the runtime's is unchanged.)*

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
  are — *amended 2026-09-29*, `language.md` §11.6 — a row or `Show` body whose inputs are, and a
  row's item-only values while its item is, §11.11; *amended 2026-09-30*, a row whose selector
  changed and whose key neither probe is, §9.4.6's version 1.3). It
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
(`backend.md` §15.3 says how `dom` does). *(Amended 2026-10-02: nor does a build whose modules
contribute no pair. `start({})` did nothing a lowering could rely on — it must already be correct
without the call — and calling it kept everything the runtime's `start` names: for `dom`, the
delegated listener and the message dispatch from a node to its program, 250 bytes of brotli of the
empty page's 1 234.)*

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

**Version 1.2** (*amended 2026-09-29*, additive and gated on nothing): **`Tree.item_only`**, per
value, whether it is a value of a `markup` row's root that reads nothing but the row's item — every
local it reads is bound inside it or by the item's pattern, so no capture, no `let` the row peeled
off and no position — and `tree.itemOnly(v)` to ask; and **`cx.rowValuesApart(block, apart_block,
row, item, index, captures, apart)`**, `cx.rowValues` with the values named in `apart`, each
item-only, emitted into `apart_block` after the others instead. A lowering may run `apart_block`
and what it writes from those values only when the item is not `===` the one the row last showed
(`language.md` §11.11), and must not read one of them outside it. `dom` targets 1.2 (`backend.md`
§15.5).

**Version 1.3** (*amended 2026-09-30*, additive and gated on nothing; research 39 §12):
**`Row.selector`**, set only on the `markup` row of a `For` keyed by a key function or by
reference, when one of its inputs is a *selector* (`language.md` §11.9): an input the row reads only
in `==`/`/=` comparisons with the row's list key. `input` is its position among `Row.inputs`;
`probe` is a value of the enclosing root that evaluates nothing and may be asked for wherever the
inputs may, the one key the comparisons can hold for — or, when no key can, a value `===` to no
key. A lowering that ignores it stays correct. One that reads it may skip a row whose item, position
and other inputs are `===` to last render's, and whose selector is not, when the row's list key is
`===` neither to last render's probe nor to this one's (`language.md` §11.11), and nothing else:
the rows whose key is one of the two are run as any row whose input changed. `ssr` ignores it;
`dom` targets 1.3 (`backend.md` §15.5).

**Version 1.4** (*amended 2026-09-30*, additive and gated on nothing; research 41 §5.2):
**`Tree.constant`**, per value, whether it is the same JavaScript value every time the program
evaluates it — a number, character or string literal (not an interpolation), a constructor of no
fields (one shared object or a bare tag, `backend.md` §4), a reference to a top-level value or
function of any module, or a slot that evaluates nothing and names one of these — and
`tree.isConstant(v)` to ask. A lowering may skip remembering and comparing such a value from
render to render: it is `===` to the last one by construction, so a helper call or a component
whose other arguments are unchanged is skipped as §9.4.4 allows. `ssr` ignores it; `dom` targets
1.4 (`backend.md` §15.3–§15.4).

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

### 9.8 Effects in a page program: commands, subscriptions and the dispatch order

*Added 2026-10-01*, the owner's answers to W46–W55 of
[`plans/browser-decisions.md`](../../plans/browser-decisions.md) — W46 option (A), W47–W55 as
recommended — which take [research 45](research/45-effects-in-a-browser-program.md) (R45) as the
design. This section is normative for `browser`'s `Browser.hosted`, `Hosted`, `Cmd`, `Sub` and its
first primitives, and for `browser-tea`'s `Tea.element`. It supersedes §5.4's sketch where the two
differ, and amends W7 as W47 says (§9.8.3).

#### 9.8.1 What `update` returns, and where each piece lives

`update : msg, model -> ( model, Cmd msg )`. **A `Cmd` is inert data**: a list of work items, each
naming a **body** `Send msg -> ()` — an ordinary direct-style beni function, which may suspend — and,
for a keyed item, a key path and a **policy**. `Cmd` has no `andThen`, no `map2`, no `sequence`: a
body sequences with `let` and runs things side by side with `Task.scope`/`spawnIn`, like any other
function. `update` therefore stays `sync` and a function of its inputs: a test asserts the model and
the command's items by value, replay drops the commands, and an update computed and thrown away has
done nothing (R45 §2.1). `subscriptions : model -> Sub msg` says, from the model, what should keep
running (§9.8.5). Neither `update` nor `view` is demanded *pure* (W54): only `sync`, which they
inherit from `Browser.hosted`'s `foreign` fields with nothing written (P2 §15.3).

**The layers.** R45 §3.1 put `Cmd` and `Sub` in `browser-tea`. They are **`browser` modules**,
written in beni with no sibling, because the primitives that return a `Sub` — `Time.every`,
`Browser.Events.onResize` — need a sibling of their own, and `browser-tea` has no JavaScript
(§9.1); a module of `browser` cannot import one of `browser-tea`. What stays `browser-tea`'s is what
R45 gives it: `Tea.element`, whose command table, four policies and subscription diff are beni over
the pieces below. `browser-tea` re-exports `Cmd`, `Sub`, `Time`, `Dom`, `Http` and `Browser.Events`.

| Module | Package | Is |
|---|---|---|
| `Browser` | `browser` | `Program`, `program`, `mountAt`, `programs`; and now `Send msg` (`msg -> ()`), `Host msg`, `hosted`, `flush`, `onRendered` |
| `Hosted` | `browser`, not re-exported | the typed pieces a `Host` is driven with: `Key`, `Outlet`, `Later`, `Tap`, `Relay` (§9.8.7) |
| `Cmd` | `browser`, beni | `Cmd msg`, `Policy`, `Send`, `none`, `batch`, `perform`, `keyed`, `cancel`, `cancelAll`, `map`, `afterRender`, `task`, `do`; and `Item msg`, `items` for the architecture that runs them |
| `Sub` | `browser`, beni | `Sub msg`, `none`, `batch`, `map`, `listen`; and `taps` for the architecture |
| `Time`, `Dom`, `Http`, `Browser.Events` | `browser` | the first primitives (§9.8.8) |
| `Tea` | `browser-tea`, beni | `sandbox`, and `element { init : ( model, Cmd msg ), update, view, subscriptions }` |

`Tea.sandbox` stays `Browser.program`, and a page built on it reaches no byte of `Task` (R45 §7).

#### 9.8.2 The command API and the four policies

```elm
pub type alias Send msg = msg -> ()
pub type Policy = Restart | Ignore | Queue | Concurrent

pub none : Cmd msg
pub batch : List (Cmd msg) -> Cmd msg
pub perform : (Send msg -> ()) -> Cmd msg                        -- a fiber in the program's scope
pub keyed : k, Policy, (Send msg -> ()) -> Cmd msg               where k.compare : k, k -> Order
pub cancel : k -> Cmd msg                                         where k.compare : k, k -> Order
pub cancelAll : Cmd msg                                           -- every keyed body at this path and below
pub map : Cmd a, k, (a -> msg) -> Cmd msg                         where k.compare : k, k -> Order
pub afterRender : (Send msg -> ()) -> Cmd msg                     -- §9.8.6
pub task : (() -> a), (a -> msg) -> Cmd msg                       -- perform λsend -> send (tag (work ()))
pub do : (() -> ()) -> Cmd msg                                    -- perform λ_ -> work ()
```

A keyed body arriving at a key path under which bodies still run (the architecture keeps, per path,
the fibers not yet ended):

- **`Restart`**: the running bodies' sends are closed at once (§9.8.4), and the new body runs in a
  fiber that first `Task.cancel`s each of them — so it starts only after their cleanup, an aborted
  request aborted and a cleared timer cleared (A1's "the interrupter waits").
- **`Ignore`**: the new body is dropped.
- **`Queue`**: the new body runs in a fiber that first waits for each running one to end.
- **`Concurrent`**: the new body starts beside them; the path keeps all of them.

With nothing running under the path, each policy starts the body. `cancel k` closes the sends of
every body under `k` and cancels their fibers (from a fiber of the program's scope, since `update`
cannot wait); nothing running, nothing happens. Debounce is `Restart` whose body sleeps first;
throttle is `Ignore` whose body sleeps last (R45 §3.5).

*Amended 2026-10-02 (§9.8.11 (b)):* a body that cannot suspend — what the checker infers of the
function where `perform` or `keyed` is used — runs with no fiber, queued where its fiber would
have started, and each policy does for it what it did for the fiber; "a fiber" above is that
body's fiber or its queued run.

#### 9.8.3 Keys, and `Cmd.map` (W47, amending W7)

**A key path** is a list of keys, the component's own key last: `keyed k` makes `[ k ]`, and
`Cmd.map cmd segment tag` puts `segment` in front of every path in `cmd` and passes every message its
bodies send through `tag`. **The segment is written** — W7's "`Cmd.map` pushes a path segment"
cannot use the tagger, a new closure on every `update`, which would match nothing from one message
to the next and make every `Restart` a silent `Concurrent`. There is no unkeyed `map`: a singleton
child passes `()`, and a component that later has two instances cannot inherit a shared key.

**Keys match by value, never by how their evidence was built** — an implementation obligation, not
a choice. A key's type must have `compare` (the `where` clause), which is what admits it and keeps
functions out of keys; the architecture then compares keys of any types with one total order over
the values themselves (`Hosted.compare`: the kind of value, then numbers and strings by value, then
a value built of fields by its field names and, in that order, their values), so a key of a
structural type — a tuple, a `Maybe Int`, a record — whose evidence the emitter builds afresh at
each call matches the same key built anywhere else. A key type's own `compare` is not what orders
it there. `tests/corpus/browser/tea/TupleKeyRestart` pins it: a tuple key under `Restart` cancels
the body a previous message started.

**What a value key cannot tell apart.** Two keys of *different types* built alike — two
constructors of one name and payload in two modules — are one key. For a command that only merges
two namespaces a program chose to share; for a subscription it routes one resource's values through
another's taggers (§9.8.5), which is a silent wrong answer, so **a library that calls `Sub.listen`
keys it with a type the library declares and names every parameter the body depends on**, as
`Time.every` does. Closing this for good needs a key that carries its type's identity — a
fingerprint the compiler supplies — and is open.

#### 9.8.4 Running a command, and the dispatch order (W53)

**The program is a scope.** `Tea.element`'s `init` opens a root scope (`Task.openRoot`), and every
command body and subscription body is spawned into it with `Task.spawnIn`, never into the fiber
whose message started it — a later `Restart` of that sender must not kill work it does not own.
`Task.closeRoot` ends it: every fiber is interrupted, children before parents, finalisers last
first. Nothing calls it yet (W51: no unmount now; W2's defect teardown is §9.8.9's).

**A body's `send` is bound to it.** Each body is handed a send through an **outlet** of its own
(`Hosted.outlet`), and the architecture closes the outlet when it cancels the body — at `Restart`,
`cancel` or `cancelAll`, in the `update` that returned the command, before the fiber has even been
interrupted. A closed outlet drops what is sent through it, so a stale response cannot land: the
send belongs to the cancelled body, not to the program. A subscription's relay closes the same way
when its key leaves the set.

**The ordering contract.**

1. A message is dispatched when `send` is called: `update` runs at once, on the current model, and
   the commands it returns are started — their fibers spawned — before `send` returns. Messages are
   applied one at a time, in the order the `send`s happened, each exactly once.
2. A `send` made while a dispatch is running — from inside `update` through a captured `Send`, or
   from anything `update` calls — is queued, page-wide, and applied when the running dispatch ends,
   never re-entrantly. Spawned bodies cannot trigger it: `fork` never runs a child inline.
3. A `send` through a closed outlet or relay does nothing.
4. A dispatch queues the program's render **before** `update` runs, so the flush that shows the
   message's model is queued ahead of the first run of any body it starts: a body that answers at
   once still lands after that render (`backend.md` §15.11).

`update` always takes the current model, so a message carries data, not a model.

#### 9.8.5 Subscriptions (W48)

```elm
pub type Sub msg
pub none : Sub msg
pub batch : List (Sub msg) -> Sub msg
pub map : Sub a, (a -> msg) -> Sub msg
pub listen : k, (Send a -> ()), (a -> msg) -> Sub msg          where k.compare : k, k -> Order
```

`listen key body tag`: while `key` is in the set, one fiber runs `body`, and each value it sends
reaches `update` through `tag`.

- **The key is the resource's whole identity.** Two declarations with one key share one fiber; the
  body that runs is the first declaration's when the key arrived. A subscription has no path
  segment: sharing is the point, and it is cancelled by leaving the set, not by key.
- **Every declaration of a live key gets every value through its own, latest tagger**, in
  declaration order: the fiber's send looks up the taggers of the current declarations, so a tagger
  that is a new closure each model never restarts the body.
- **The set is recomputed once per render** — in `settle` (§9.8.7), before the program's `view`, on
  every flush that renders it — not once per message. The diff is Elm's three-way merge: keys that
  left have their relay closed and their fiber cancelled; keys that stayed keep their fiber and take
  their new taggers; keys that arrived are spawned into the program's scope.
- **`Sub.listen` is public** (rule 7): a subscription the platform did not think of is ordinary beni
  over a primitive.

A value reaches `update` one fiber resumption after the host produced it, so a subscription cannot
`preventDefault`; that needs a `sync` filter in the host's dispatch, which is not designed.

#### 9.8.6 After render, the DOM capabilities, `Browser.flush` (W49, W50)

**`Cmd.afterRender body`** queues `body` into phase (2) of the next flush (`backend.md` §15.11):
after every write of the render, synchronously, before the next message. The body is `sync` — the
demand arrives from `Hosted.later`'s `sync` parameter through `Cmd.afterRender`'s summary — and it
may send, which queues the next flush.

**DOM capabilities are `impure`, address a node by its id, and return a `Result`**: `Dom.focus`,
`Dom.blur`, `Dom.box`, `Dom.scrollTo`, `Dom.scrollIntoView` (`Err (NotFound id)` for a node that is
not in the page) and `Dom.viewport`. Called outside phase (2) they are still correct — a measurement
forces a layout, which is slow and right. Research 17 §4.7's `suspends` capabilities are withdrawn.
**`Dom.rendered : () -> ()`** suspends: at once when no render and no after-render work is queued,
otherwise until the next flush's after-render phase begins; its fiber goes on at the scheduler's
next drain, before paint.

**`Browser.flush : () -> ()`**, `impure`, renders every program with a message waiting now, then runs
phase (2). Called during a dispatch or a flush it does nothing more than the flush already queued,
so no render sees a half-handled message.

#### 9.8.7 The low-level form: `Browser.hosted` and `Hosted`

```elm
pub foreign type Host msg
pub foreign pure hosted :
    { init : sync (Host msg -> model)
    , update : sync (Host msg, msg, model -> model)
    , settle : sync (Host msg, model -> model)
    , view : sync (model -> Html msg)
    }
    -> Program
pub foreign impure flush : () -> ()
pub foreign impure onRendered : Resume () -> (() -> ())     -- `Dom.rendered` is `Task.callback` over it
```

`init` is called once, at mount, with the program's `Host`; `update` for each message; `settle` once
per render of the program, just before `view`, on the model about to be rendered (and once after
`init`), returning the model that is rendered. R45 §3.9 sketched `send` and `scopeOf` on the host:
the scope is the architecture's own (`Task.openRoot` in `init`), and every send goes through an
outlet or a relay, so the host itself is only `{ send, after }`, reached through `Hosted`:

| `Hosted` | Rung | Is |
|---|---|---|
| `Key`, `key : k -> Key where k.compare`, `compare`, `eq` | `pure` | a key of any type, compared by value (§9.8.3) |
| `Outlet msg`, `outlet : Host msg -> Outlet msg`, `emit`, `close` | `impure` | a closable send into the program |
| `Later msg`, `later : sync (Send msg -> ()) -> Later msg`, `mapLater`, `afterRender : Host msg, Later msg -> ()` | `impure` (`mapLater` `pure`) | after-render work |
| `Tap msg`, `tap : (Send a -> ()), sync (a -> msg) -> Tap msg`, `mapTap` | `impure` (`mapTap` `pure`) | a subscription's body and tagger, the payload type hidden |
| `Relay msg`, `relay : Host msg, Tap msg -> Relay msg`, `retap`, `closeRelay` | `impure` | a live subscription's current taggers |
| `run : Relay msg -> ()` | `suspends` | run the relay's body in the calling fiber |

A function the platform hands a body — every `Send` — is `impure` because the `foreign` that hands
it is (P2 §14.3 rule 6), so a release build never drops a send. `retap` trusts that every tap it is
given sends what the relay's first did; §9.8.3 says what keeps that true and what does not.
**A sibling may not import another file**, so `Browser.js` reaches the render loop by value: every
mount a `Browser` constructor makes carries a function of that file, and `run` hands it the loop
before mounting anything; `flush` and `onRendered` call it. The platform's runtime file gains no
export. *(Amended 2026-10-02, `backend.md` §15.11's last amendment: only a `hosted` mount carries
one, called at its own mount; the dispatcher, the after-render phase and `flush`'s guards are
`Browser.js`'s, so a page of `Browser.program`s alone ships none of them.)* *(Amended again
2026-10-02: they are `Browser.beni`'s now, written over `Js.finally` (§4.2), and `hosted`, `flush`
and `onRendered` are beni declarations with the signatures above, less `foreign`; the mount still
reaches the loop by value, `h(root, flush, setPhase)`. `backend.md` §15.11.)*

**`Task` gains three** (R45 §3.9 item 2): `running : Fiber a -> Bool`, `impure`, `False` once the
fiber has ended either way; `openRoot : () -> Scope` and `closeRoot : Scope -> ()`, both `impure`,
a scope no function brackets. A fiber spawned into a closed root scope is cancelled before it runs.

#### 9.8.8 The first primitives

A suspending primitive is beni over `Task.callback` and an `impure` sibling that starts the host's
operation and returns its canceller (P2 §16.5); one that never parks is `impure`.

| Module | Signature | Rung |
|---|---|---|
| `Time` | `Duration` (`millis`, `seconds`, `inMillis`), `Posix` (`toMillis`, `fromMillis`) | — |
| | `now : () -> Posix` | `impure` |
| | `sleep : Duration -> ()` | `suspends`; cancelling clears the timer |
| | `every : Duration, (Posix -> msg) -> Sub msg` | keyed by its interval, one timer per interval |
| `Dom` | `focus`, `blur`, `scrollIntoView : String -> Result Error ()`; `box : String -> Result Error Box`; `scrollTo : String, Float, Float -> Result Error ()`; `viewport : () -> Viewport` | `impure` |
| | `rendered : () -> ()` | `suspends` |
| `Http` | `get : String -> Result Error String`, `post : String, String -> Result Error String`, `getJson`, `postJson` | `suspends`; `fetch` with an `AbortController`, aborted when the fiber is cancelled |
| | `type Error = BadUrl String \| NetworkError \| BadStatus Int \| BadBody String` | a failure is a value, never an exception (§4.1) |
| `Browser.Events` | `onResize : (Size -> msg) -> Sub msg`, `onVisibilityChange : (Visibility -> msg) -> Sub msg`, `visibility : () -> Visibility` | the listener added when the key arrives, removed when it leaves |

`getJson`/`postJson` send and accept `application/json` and answer the body's text once it parses
as JSON, `BadBody` otherwise; decoding it into a type waits on schemas' parse (`schema.md`).
**Still owed** from R45 §5: `Http.send` with a request record and a streaming body, `Time.here`,
`Browser.nextFrame` and `onAnimationFrame`/`onKeyDown`/`onWindow`, `Random`, `Storage`, `Nav` and
`Tea.application`, `Ws`, and core's `Queue` (W52 settles its handle rule, below).
*(Amended 2026-10-01: `onKeyDown`, `Random` and `Storage` are §9.8.10's, with `Url` read-only and
`Log`.)* *(Amended again 2026-10-01: `Http`'s row, `getJson`/`postJson` and the request record are
superseded by §9.8.12, HTTP version 2; `Nav` and `Tea.application` are §9.8.13's.)*

#### 9.8.9 The rest of the answers

- **W51, unmount**: not now; the root scope and `Task.closeRoot` are what it would call.
- **W52, handles in a model**: §4.1's "never hold a reference across an effect boundary" is amended
  for a handle every operation of which is total on a closed one — each returns a `Result` — and
  which is declared `equatable foreign type`, so a model holding it keeps its derived `==`. None is
  built yet; `Queue` will be the first.
- **W55, faking a service**: through records of functions only (A7); a test passes a record whose
  functions wait on `Time.sleep`, and the page driver's clock is virtual (`tests/corpus/README.md`,
  *`browser/`*, the `advance` step).
- **W2, a defect's teardown**, which R45 §8 item 8 asks to close the program's scope, is **not
  built**: a `foreign` that throws inside a fiber escapes the scheduler's microtask as an uncaught
  exception, and nothing yet closes the scope. *(Amended 2026-10-01: the rest of W2 is built —
  a throw in a program's own code stops the page, with a development crash screen, §9.8.10 (c);
  closing the scope and a fiber's throw are still owed there.)* *(Amended again 2026-10-02:
  closing the scope is specified in §9.8.14.)*

*As built, 2026-10-01* (`platforms/browser/`: `Browser.beni`, `Hosted.beni`, `Cmd.beni`,
`Sub.beni`, `Time.beni`, `Dom.beni`, `Http.beni`, `Browser/Events.beni` and their siblings,
`runtime.js`; `platforms/browser-tea/Tea.beni`; `core/Task.beni`): as specified above. The pages
are `tests/corpus/browser/tea/`: `DebouncedSearch` (a `Restart` debounce, a stale answer's send
dropped, the new body after the old one's cleanup), `Policies`, `TupleKeyRestart`, `OwnedByProgram`,
`ReentrantSend`, `FlushLatched`, `ClockStops`, `LatestTagger`, `AfterRenderFocus`, `HttpResults` and
`WindowEvents`; `run/TaskRootScope` is the root scope under Node. **Measured** (`bench/size.mjs`,
`--release`, brotli): the empty `Tea.sandbox` page 1 551 bytes and it reaches no `Task`; the empty
`Tea.element` 5 496 — declaration-granular elimination keeps the command table, the diff and the
fiber runtime whenever `element` is reached, so R45 §7's "must not reach `Task`" holds for
`sandbox` only; a page on a keyed `Restart` `Http.get` and a `Time.every`, 6 144. *(Amended
2026-10-02: see the note below — 1 945 and 5 427, and an `element` that asks for no work reaches
no fiber.)* A message
dispatched to a counter costs about 30 ns under `Tea.element` against 13 ns under `Tea.sandbox`
(happy-dom in Node, the update and the dispatcher, one render per thousand messages).

*Amended 2026-10-02: what a page asks for is what it ships.* Three changes, one rule each:

- **The hosted loop is `Browser.js`'s** (`backend.md` §15.11's last amendment), so a page of
  `Browser.program`s alone ships no dispatcher, after-render phase or waits.
- **An arm on a constructor nothing builds keeps nothing alive** (`backend.md` §9, *A `case` arm on
  a constructor nothing builds*). `Tea.element`'s command table is a `case` over `Cmd.Item`, so
  each item kind's code — and the fiber runtime, `Dict` and `Hosted.compare` behind it — ships only
  when the program builds that kind; a page that asks only for `Restart` ships no `Ignore`,
  `Queue` or `Concurrent`.
- **`Sub` has a constructor for "nothing"**: `type Sub msg = None | Listen (List ( Key, Tap msg ))`.
  Only `listen` makes a `Listen` from nothing (`batch` and `map` rebuild one from one), and `Tea`'s
  live set is `Idle` until a `Listen`'s diff makes it `Running`, so a program that never subscribes
  ships neither the diff nor the cancellation of what it started. `taps` and the rest of §9.8.5's
  surface are unchanged; the constructors are for the architecture, as `Cmd.Item`'s are.
- Core's `Task.js` makes its outside-any-fiber record on first use, so a build that keeps only
  `openRoot` of it keeps no call at its top level (research 40 §8, rule 5).

Measured (`bench/size.mjs`, `--release`, brotli): the empty `browser` page **1 234**, the empty
`Tea.sandbox` **1 239**, the empty `Tea.element` **1 945** with no fiber runtime
(`reaches_task` false; `build_test`'s *an element whose commands are all `Cmd.none` ships no fiber
runtime*), and the `Http` + `Time` page **5 427** — and, once a build with no start data calls no
`start` (§9.4.5's amendment), **980**, **993**, **1 697** and **5 190**, none of these pages
having a delegated event. What the `Http` + `Time` page still ships, each group priced by
leaving it out of the file: the fiber runtime (about 1 150: the scheduler, suspension, spawn into
a scope, cancellation and its wait), the keyed-`Restart` table and the subscription diff (about
520), `Dict` (about 370: `get`, `insert` and `foldl`, for the table and the diff), `Http`'s
request (about 280) and `Hosted.compare` (about 190, the order keys are matched by). Each is used
by what the page does; the rest is the 980 of any page, and `Time`'s.

#### 9.8.10 Keys, storage, randomness, the address, defects and the log

*Added 2026-10-01* (`plans/status-2026-10.md` §6, Milestone 1 items 1–2; R45 §5). What a
TodoMVC-class page needs beyond §9.8.8: a handler that reads a key, storage, a random number, the
page's address, the owner's W2 answer built, and a log a release build keeps. Each capability is a
module of `browser`, written in beni over `Js` (§4.2) except where it must `catch` (§4.1's recipe),
re-exported by `browser-tea`; a page that does not import one ships none of it. Where a choice was
the owner's and was taken here it says so; each is reversible.

**(a) What a handler reads of its event.** `Html`, the vocabulary module, gains:

| | Rung | Is |
|---|---|---|
| `key : Event -> String` | impure | `KeyboardEvent.key`: the character typed or the key's name (`"Enter"`, `"Escape"`) |
| `code : Event -> String` | impure | the physical key (`"KeyA"`) |
| `ctrlKey`, `shiftKey`, `altKey`, `metaKey : Event -> Bool` | impure | whether the modifier was held |
| `preventDefault : Event -> ()` | impure | the DOM's `preventDefault()` |

Each reads the property of its name, and is total: an event without it (a click's `key`) reads
`""` or `False`, never `undefined`. **`preventDefault` takes effect because a handler runs while
its event is dispatched** (`backend.md` §15.11: the delegated listener calls it), so "Enter adds,
and the key does nothing else" is `onKeyDown={λevent -> if Html.key event == "Enter" then let _ =
Html.preventDefault event in Add else Ignored}`; a subscription's value arrives a fiber turn later
(§9.8.5) and cannot. Elm decides a message and the default together in a decoder that may fail;
here a handler always makes a message, and a key the program ignores is a message `update`
ignores — one render, which writes nothing. A declaration's own `preventDefault` (`onSubmit`) is
applied before the handler, as before.

**Elm's API is the model** (the owner, 2026-10-01: mirror Elm's module and function names, adapt
the argument order to beni's subject-first calls, deviate only where beni forces it, and say why).
Elm reads an event with a `Json.Decode.Decoder`; **beni has no decoder library until schemas parse
(`schema.md`), and its handlers are already typed functions of the event** (`language.md` §11), so
these accessors are what Elm's `targetValue` and `keyCode` decoders are, and a "decoder" is a
function `Event -> msg`. Elm's `preventDefaultOn` returns the decision with the message; a beni
handler may call an impure function, so it calls `preventDefault` instead.

`Browser.Events` gains **`onKeyDown`, `onKeyUp`, `onKeyPress : (Html.Event -> msg) -> Sub msg`**,
Elm's three, each taking the function a handler would be (`onKeyDown (λevent -> Pressed
(Html.key event))`, Elm's `onKeyDown (Decode.map Pressed (Decode.field "key" Decode.string))`).
Unlike a resize, **no key is coalesced**: each event is queued as it is dispatched until the body's
fiber takes it, in order, and the function reads it there — the properties it reads do not change
after dispatch, and only `preventDefault` would come too late. The queue is `Listen.each : String,
String, sync (Js.Value -> a), Send a -> ()` — the window's or the document's events of one name,
each `read` as it fires — a module of `browser` for its own modules (`Browser.Navigation` uses it
too), not re-exported by `browser-tea`, as `Hosted` is not. Elm's decoder may fail, sending
nothing; a beni function always makes a message, which `update` may ignore.

**(b) Storage, randomness and the address.**

| Module | Signature | Rung |
|---|---|---|
| `Random` (elm/random) | `Seed`, `Generator a` (opaque); `int : Int, Int -> Generator Int`, `float : Float, Float -> Generator Float`, `minInt`, `maxInt`, `uniform : a, List a`, `weighted : ( Float, a ), List ( Float, a )`, `constant`, `pair`, `list : Generator a, Int`, `map`, `map2`, `map3`, `andThen`, `lazy` | pure |
| | `step : Generator a, Seed -> ( a, Seed )`, `initialSeed : Int -> Seed`, `independentSeed : Generator Seed` | pure |
| | `generate : Generator a, (a -> msg) -> Cmd msg` | — |
| `Url` (elm/url) | `type alias Url = { protocol : Protocol, host : String, port_ : Maybe Int, path : String, query : Maybe String, fragment : Maybe String }`, `type Protocol = Http \| Https` | — |
| | `fromString : String -> Maybe Url`, `toString : Url -> String`, `percentEncode : String -> String`, `percentDecode : String -> Maybe String` | pure |
| `Browser.Navigation` | `currentUrl : () -> Maybe Url`, `onUrlChange : (Url -> msg) -> Sub msg` | impure, — |
| `Storage` | `type Area = Local \| Session`, `type Error = QuotaExceeded \| Unavailable` | — |
| | `get : Area, String -> Maybe String`, `keys : Area -> List String`, `remove : Area, String -> ()` | impure |
| | `set : Area, String, String -> Result Error ()` | impure |

- **`Random`** is elm/random, every name and every generator: a function argument moves last and
  the generator first (`map : Generator a, (a -> b)`, `list : Generator a, Int`, as core's
  `List.repeat : a, Int` did with Elm's), and `generate` is Elm's command — subject-first,
  `Random.generate (Random.int 1 6) Rolled` — run as `Cmd.task` runs work (§9.8.2), each one
  stepping one page-wide seed, as Elm's effect manager keeps one. That seed starts from
  `crypto.getRandomValues` rather than Elm's clock, so two pages opened in one millisecond do not
  share a sequence (the test driver makes both deterministic). The generator is PCG as Elm's, its
  32-bit products in `Int32` (exact where Elm's `*` on doubles rounds), so a seed gives the same
  sequence in every beni build, not Elm's sequence. *Amended 2026-10-02 (§9.8.11 (a)):* the
  generators and seeds are core's `Random.Pcg`; `browser`'s `Random` names them as Elm does and
  adds `value : Generator a -> a` (`impure`), the direct form, of which `generate` is `Cmd.task`;
  `node` has the same `Random` without `generate`.
- **`Url`** is elm/url's `Url` module, pure: Elm's record, its two protocols, its parser and
  printer, percent encoding. **How a program gets the page's address** is Elm's
  `Browser.application`, which hands `init` a `Url` and takes `onUrlChange`; until
  `Tea.application` and its navigation key land (Milestone 2), **two stand-ins** in
  `Browser.Navigation`, Elm's navigation module, which they will join: `currentUrl ()`, the page's
  `location` through `Url.fromString` — `Nothing` for an address that is not `http` or `https`,
  where Elm's `application` crashes (§4.1: a failure is a value) — and `onUrlChange`, the new
  address after each `hashchange` or `popstate` (one that does not parse sends nothing). A filter
  in `#/active` is read by `init` from `currentUrl ()` and kept by `onUrlChange`.
- **`Storage`** has no Elm counterpart (Elm reaches Web Storage through ports): R45 §5's table
  with the area a value, since `localStorage` and `sessionStorage` are one API. Each failure the
  Web Storage standard documents is one value (rule 9, §4.1): **reading the area may throw
  `SecurityError`** (storage disabled, a sandboxed frame) — the area is then unavailable, holding
  nothing, so `get` is `Nothing`, `keys` empty, `remove` nothing to do and `set` `Err
  Unavailable` — and **`setItem` may throw `QuotaExceededError`**, `Err QuotaExceeded`. An area
  the host leaves `null` is unavailable too. Any other exception is not caught: it is a defect
  (c). The catches are a sibling's (`Storage.js`), because `Js` writes no `catch` (§4.2).
  *(Amended 2026-10-01: they are `Js.catchIf`'s, each naming its `DOMException` by `name`, and
  `Storage.js` is gone.)* `onChange` (another tab wrote) is still owed.

**(c) A defect stops the program** (the owner's W2, *as recommended*; A1). A throw that escapes a
program's own code — `init`, `update`, `view`, `subscriptions`, a markup handler, a render's patch
or after-render work — **stops every program of the page** (one build is one application): from
that moment no message is applied (a `send` from a handler, a fiber or after-render work does
nothing), no render or after-render work runs and no listener calls a handler. **The throw goes
on**, never caught and dropped: the host reports it as an uncaught exception — the console with
its stack, `window.onerror` for a crash reporter — which is the log in both builds. **In a
development build the page also shows a crash screen**: a fixed overlay appended to `body`, above
the page and leaving the page's DOM in place to inspect, saying that the program has stopped
because of an error, with the error's message (`String(error)`, not its stack, which the console
has). **A release build adds nothing** — the screen's code is in no release build, through
`Js.development` (`backend.md` §4, *`Js.development` is the build's mode*), the core intrinsic
added for it: `True` in a development build, `False` under `--release`, and an `if` on it keeps only
the branch the build takes, in reachability and in lowering.

- **Where it is caught.** Four guards, each a `Js.finally` whose body ends by noting that it
  completed and whose cleanup stops the page when it did not: the delegated and own listeners'
  `fire` (a handler and the dispatch it starts), the hosted dispatcher (a send from a fiber), the
  render loop's `flush` (renders, `settle`, `view`, after-render work) and `run` (`init` and the
  first render). The hosted loop's latches are still released in their `Js.finally` cleanups,
  as before, though nothing reads them once the page has stopped.
- **A fiber that throws stops the page too.** Core's scheduler guards its drain the same way, and
  a throw out of a fiber stops it — no fiber runs again, as `Task`'s "a defect ends the program"
  says — and calls the hook a platform gave `Task.onDefect : (() -> ()) -> ()` (impure, core). A
  hosted mount hands it the page's stop, which reaches `Browser.beni` as the mount's fourth
  argument, `h(root, flush, setPhase, stop)`, as the loop reaches it (§9.8.7).
- **An error a primitive did not expect is a throw in the fiber that waited on it** (rule 9):
  `Http`'s sibling names each failure `fetch` documents — a `TypeError` from `new URL` is
  `BadUrl`, a rejection with a `TypeError` is `NetworkError`, a `SyntaxError` from `JSON.parse`
  is `BadBody`, an `AbortError` after the fiber's own abort is nothing (the fiber is gone) — and
  resumes the fiber with anything else wrapped, `{ d: error }`, which `Http.beni` throws where
  the request was made. The page stops through the fiber's guard, and the report's stack is the
  request's.
- **The message on the screen** arrives with the host's report: stopping registers a one-time
  `error` listener on the window, which the throw reaches after the cleanup ran.
- **Not yet:** the program's scope is not closed (W2 option (b), R45 §8 item 8): a fiber parked
  when the page stops stays parked, never resumed. Closing it needs the host to reach `Tea`'s root
  scope, which is the next step. *(Amended 2026-10-02: specified in §9.8.14 — core keeps every
  root scope, and a defect's teardown closes them all, each finaliser running once.)*
- **This replaces `browser/tea/ThrowRecovers`**, which pinned the opposite — a throw left the loop
  able to run the next message.

**(d) A log a release build keeps.** `--release` refuses `Debug` (`backend.md` §9), and report §4
item 6 found nothing in its place. **`Log`**, a module of `browser`:

| | Rung | Is |
|---|---|---|
| `info`, `warn`, `error : String -> ()` | impure | `console.info`, `console.warn`, `console.error` of the string |

*Taken by the implementer as the manager's call, reversible:* the smallest API that gives a shipped
program a console line at three levels. A `String`, not any value: `Debug.toString`'s text is not a
promise (its own documentation) and a release build renames fields, so a program that logs a value
formats it. No `debug` level (that is `Debug.log`'s job in development), no structured fields, no
reporting hook and no log context (A7's third slot) — each can be added without changing these
three. Being `impure`, a call is never dropped by `--release`, and an unused `Log` costs nothing.

*As built, 2026-10-01* (`platforms/html/Html.beni`; `platforms/browser/`: `Listen.beni`,
`Browser/Events.beni`, `Browser/Navigation.beni`, `Url.beni`/`.js`, `Random.beni`,
`Storage.beni`/`.js`, `Log.beni`, `Rt.beni`, `Browser.beni`, `Http.beni`/`.js`; `core/Task.js`,
`core/Js.beni`), as specified above, every module but `Listen` re-exported by `browser-tea`.
Written in beni over `Js` except three siblings' worth of `catch`: `Storage.js`, `Url.js`'s
`decodes` and `Http.js`. *(Amended 2026-10-01: all three are beni over `Js.catchIf`, and so is
`Time.js`'s clock and timer; `plans/core-in-beni.md`, step 1.)* The pages are `tests/corpus/browser/tea/`: `KeyEvents`,
`KeySubscription`, `RandomValues`, `UrlAddress`, `StorageBasics`, `StorageFaults`, `LogLevels`,
`DefectInUpdate`, `DefectInRender`, `DefectAfterRender`, `DefectInFiber`, `HttpDefect`,
`browser/dom/DefectInHandler`, and **`TodoMVC`**, the acceptance test: Enter adds a todo and
prevents the key's default, the list is saved after every change and read back at start, and the
filter follows `#/active` from the address the page was opened at and from each change of it.
Its rows are positional (`keyed={False}`): keyed rows took the page over the per-test
instruction budget, and a row holds no state of its own.

**Measured** (`--release`, the page's one file, brotli 11, against `master` at the time): the
empty `Browser.program` page 490 → **536**, a click counter on `Tea.sandbox` 892 → **958**, the
empty `Tea.element` 1 499 → **1 576** — the defect rule's guards and flag, the only change every
page pays. A page that imports every new module and calls none is byte for byte the empty page.
Each capability, priced against the counter: an Enter handler with `preventDefault` +51, a
`Log.info` in `update` +21, a `Storage.set` +169; `Random.generate` on `Tea.element` +1 707,
almost all of it the fiber runtime a command needs; `currentUrl` with `onUrlChange` 5 239 in all,
the fiber runtime, the subscription diff and the URL parser. `TodoMVC` is 8 120. A message
through the delegated listener costs the same within noise (happy-dom, 20 000 clicks, a render per
thousand: 2 789 ns before, 2 820 after, almost all of it happy-dom's own dispatch).

**Where this departs from Elm, and why** (the owner's 2026-10-01 instruction): event reading is
by functions of the event, not `Json.Decode` decoders — beni has no decoder library until
schemas parse, and its handlers are already typed functions of the event, so a "decoder" cannot
fail and a key the program ignores is a message `update` ignores; `preventDefault` is a call in
a handler, not a `Bool` returned beside the message, because a handler may be impure; every
argument order is subject-first; `Random.generate` seeds from `crypto.getRandomValues`, not the
clock, and its products are exact; the page's address is read by two stand-ins in
`Browser.Navigation` until `Tea.application` lands, and `currentUrl` is a `Maybe` where Elm's
`application` crashes on an address that is not `http` or `https`; `Url.percentEncode` writes a
lone surrogate as U+FFFD where Elm's would throw; `Storage` and `Log` have no Elm counterpart.

#### 9.8.11 Direct forms first, and commands without fibers

*Added 2026-10-02*, the owner's direction: **The Elm Architecture is a framework on top of beni.
Every capability has a plain direct form first, usable from any beni code; `Cmd` and `Sub` are
thin wrappers over it.** Two consequences, one rule each.

**(a) Every capability has a direct form.** The audit of `browser` and `node`, each capability
that a program could reach only through a `Cmd` or a `Sub` until now, and its direct form:

| Wrapper (Elm's name, kept) | Direct form | Rung |
|---|---|---|
| `Random.generate : Generator a, (a -> msg) -> Cmd msg` | **`Random.value : Generator a -> a`**, on `browser` and `node` | `impure` |
| `Browser.Events.onResize`, `onVisibilityChange` | **`eachResize : (Size -> ()) -> ()`**, **`eachVisibilityChange`**; `size ()` and `visibility ()` read the current one | `suspends` |
| `Browser.Events.onKeyDown`, `onKeyUp`, `onKeyPress` | **`eachKeyDown : (Html.Event -> ()) -> ()`**, **`eachKeyUp`**, **`eachKeyPress`** | `suspends` |
| `Browser.Navigation.onUrlChange` | **`eachUrlChange : (Url -> ()) -> ()`**; `currentUrl ()` reads the current one | `suspends` |
| `Time.every` | `Time.sleep` and `Time.now`, already | — |
| `Cmd.task`, `Cmd.do` | the function they are handed | — |

Everything else — `Time`, `Dom`, `Http`, `Storage`, `Log`, `Url`, `Io` — had only direct forms
already. An `each…` form calls `f` with each event, in order, for as long as the calling fiber
runs, and never returns; cancelling the fiber removes the listener. Each subscription is now
`Sub.listen` over its direct form (`onKeyDown tag = Sub.listen KeyDown (eachKeyDown _) tag`), so
the two cannot drift; what §9.8.5 and §9.8.10 (a) say of coalescing and order is the direct
form's. `browser/tea/DirectEvents` runs three of them in the bodies of keyed commands and
cancels them.

**`Random` is split between core and each platform** (`schema.md` §14.3, which a core library's
generator needs). **Core's `Random.Pcg`** is the pure half: `Seed`, `Generator`, `step`,
`initialSeed`, `independentSeed` and every generator, as §9.8.10 (b) lists them. **Each platform's
`Random`** is that module by Elm's names — a `type alias` and a one-line definition per name —
plus the impure seed source: `value` steps one page-wide (`browser`) or process-wide (`node`)
seed, which its first draw starts from `crypto.getRandomValues` (Web Crypto, a global in Node 19
and later); `browser`'s adds `generate generator tag = Cmd.task (λ() -> value generator) tag`.
*Why two modules and not one:* module names are unique per package, and a platform module
shadows the core module of its name for the program and for the platform itself (§9.1), so a
platform `Random` cannot import a core `Random`; the core half takes elm-random-pcg's name,
`Random.Pcg`. A library that runs on any platform imports `Random.Pcg`; a program imports
`Random`. `getRandomValues` throws only for an array that is not of integers or is longer than
65 536 bytes (rule 9), and the one it is handed is neither, so `value` catches nothing; a host
with no Web Crypto is a defect. `run/RandomValue` (Node) and `browser/tea/RandomValues`'s
`#draw` call it directly.

**(b) A command whose body cannot suspend runs without a fiber.** Until now every body ran in a
fiber spawned into the program's scope, so a page that issued any command shipped the fiber
runtime — `Random.generate` cost 1 707 bytes over a counter, almost all of it that. Now:

- **The choice is static, per use, from the inferred bit.** `Cmd.perform` and `Cmd.keyed` ask
  `Js.maySuspend body` (`backend.md` §4, *`Js.maySuspend` is the body's answer*), so each has two
  bodies: the direct one builds **`Now`** (`KeyedNow`), the suspendable one **`Perform`**
  (`Keyed`), and each use takes the body the class of the function it passes says. `Cmd.task`,
  `Cmd.do` and `Random.generate` pass a function of their arguments and inherit the choice. The
  body is held in a `foreign type`, **`Hosted.Job`**, built by `Hosted.job` and run by
  `Hosted.runJob` (`suspends`, in a fiber) or `Hosted.callJob` (`impure`): a function in a
  constructor's field would share one class with every command it is batched or returned with
  (`transparent-effects-proposal.md` §14.5), and one body that waits would make every body of
  the program take the suspendable form. `Cmd.map`'s tag goes through `Hosted.mapJob`, `sync` as
  `mapLater`'s already was.
- **Where it runs: exactly where its fiber would have started.** A fiber spawned now is queued at
  the back of the scheduler's ready queue and first runs when the drain reaches it. **Core's
  `Task.soon : sync (() -> ()) -> Soon`** queues work in that same queue, at that same place, and
  runs it outside any fiber, as `main` is evaluated; `Task.queued` says it has not run. So
  everything §9.8.4 orders is ordered as before, by construction: the body runs after the update
  that asked for it has returned and after the render that update queued (rule 4), in the order
  the commands were asked for and interleaved with fibers' first runs and resumptions in queue
  order; its `send` dispatches at once, never re-entrantly (rules 1–2); the drain's budget of 64
  counts it as a resumption, so a chain of commands answering commands still yields to the host;
  and a throw in it is a defect through the drain's guard (§9.8.10 (c)). The scheduler's queue
  holds a step function per entry, so a build whose only queued work is `soon`'s keeps the queue
  and the drain but no fiber record, run loop, suspension or cancellation.
- **The policies and `cancel`, for a body that cannot suspend.** Such a body cannot be stopped
  once it starts, and — exactly as a fiber not yet started runs until its first suspension before
  its cancellation can reach it — one still queued when a `Restart`, `cancel` or `cancelAll`
  closes its outlet still runs, to its end, its sends dropped. So a queued body is *running*
  until it has run (`Ignore` drops a new body meanwhile); `Restart` and `Queue` start a new body
  that cannot suspend queued, behind the old ones, unless one of them is a fiber, in which case
  the new body starts in a fiber that cancels (`Restart`) or waits for (`Queue`) them first — the
  only path on which a body that cannot suspend still takes a fiber, reached only when a `Keyed`
  body exists; and `Concurrent` queues it beside them. `Tea`'s table keeps `InFiber fiber outlet`
  or `Queued soon outlet` per body, and every step that waits for or cancels a fiber is in an
  `InFiber` arm, so a program that builds no `Perform` and no `Keyed` reaches none of them
  (`backend.md` §9, *A `case` arm on a constructor nothing builds*).
- **Structured concurrency does not change** (*amended 2026-10-02*, the manager's review). A
  fiber started with `Task.spawn` belongs to the fiber that started it and is cancelled when that
  one ends; a body that runs with no fiber owns what it spawns the same way. While `soon`'s work
  runs, `spawn` outside any fiber makes the child the work's own — no fiber is made: the run's
  record keeps its children — and when the work returns each is cancelled, where a fiber's
  `finish` would have cancelled it. Such a child is queued behind the body, so it is cancelled
  before it runs, in both forms; a child the body must wait for (`Task.join`) makes the body one
  that may suspend, which runs in a fiber. The one thing a fiber did beyond this — staying
  *running* until its cancelled children had unwound — no one can observe of a queued body,
  whose children never run. `browser/tea/SyncSpawnOwned` pins it, the same log both ways.
- **What is not the same.** `Task.closeRoot` (which nothing calls yet, W51) does not reach queued
  work. *(Amended 2026-10-02: a defect's teardown, §9.8.14, drops queued work unrun.)* And the choice is as precise as the class: a function chosen at run time between one that
  waits and one that does not (`if b then f else g`) may wait, and runs in a fiber.

**The proof that ordering is unchanged** is a pair of pages that do the same work both ways,
each body written once and made one that may wait by a wait on a branch no run takes:
`browser/tea/SyncCommandOrder` (a batch of two bodies that never wait around one that waits, the
first one's message asking for a fourth; update, render, bodies and messages log one order for
both) and `browser/tea/SyncKeyedPolicies` (each policy with two messages in one task, a body
cancelled in the update that asked for it, and a body that never waits restarting one that waits
in a fiber, after its cleanup). `build_test`'s *an element whose commands never wait ships no
fiber runtime* pins the size claim on a `Random.generate` page and a keyed `Restart` page;
*an element whose commands are all `Cmd.none`* pins the other side, a `Cmd.do` of a function that
sleeps.

**Measured** (`bench/size.mjs`, `--release`, brotli 11): the `Random.generate` page (`browser-tea
random`) **2 923 → 1 970**, and it reaches no fiber; the empty `Tea.element` 1 237 → 1 249 (two
more dead arms in the command table); the `Http` + `Time` page 5 394 → 5 478 (the `Job` calls,
the `Run` arms and the scheduler's step column). A message whose command's body sends one message
back costs **196 ns** with no fiber against **383 ns** in a fiber (happy-dom in Node, the update,
the dispatcher and the body, sent straight to the mount, settled every thousand); a body that
may wait costs what it did (368 → 383 ns, within noise), and a message with no command 40 ns.

#### 9.8.12 HTTP, version 2

*Added 2026-10-01* (`plans/status-2026-10.md` §4 Tier 1 item 2, §6 Milestone 2 item 2). This
section is normative for `browser`'s `Http` and **replaces §9.8.8's `Http` row**: `get`, `post`,
`getJson`, `postJson` and the four-constructor `Error` are withdrawn, and the fixtures that use
them are migrated by the slice that lands this (`plans/http-and-routing.md`). The choices it takes
for the owner are H1–H5 of that plan; each is written here as recommended and is reversible until
its slice lands.

**The model is elm/http 2.0** (the owner, 2026-10-01: mirror Elm's packages, read their code;
`Http.elm` and `Elm/Kernel/Http.js` at `2.0.0`). Its pieces keep their names — `request`, `get`,
`post`, `riskyRequest`, `Header`/`header`, `Body` and its constructors, `Expect` and its
constructors, `Error`, `Response`, `Metadata`, `Progress`, `fractionSent`, `fractionReceived` —
and beni changes what its language or its rules force, each listed at the end of this section with
the reason.

**(a) The direct form is the API; a command is `Cmd.task` over it** (§9.8.11). A request is a
function that **suspends** the calling fiber until it has an answer and returns it as a `Result`:
Elm's `Task`-returning `Http.task` with its `Resolver x a`, which a beni call that waits simply
*is*. So the direct form takes the names of Elm's command form, and `Expect` carries the error type
Elm's `Resolver` carries and no message, because there is no tagger to carry:

```elm
-- module Http (browser), re-exported by browser-tea
pub type Error
    = BadUrl String          -- the URL does not parse, relative to the page, or holds user information
    | BadRequest Problem     -- beni: a request the host would refuse, found before anything is sent
    | Timeout                -- the request's own timeout ran out before the body was read
    | NetworkError           -- no answer: the network, DNS, a refused connection, CORS, a body cut off
    | BadStatus Int          -- an answer whose status is not 2xx
    | BadBody (List Schema.Issue)   -- `expectJson`: a 2xx body the schema does not parse

pub type Problem
    = InvalidMethod String   -- not an HTTP token
    | ForbiddenMethod String -- CONNECT, TRACE or TRACK, in any case
    | InvalidHeader String   -- a name that is not a token, or a value holding NUL, CR or LF
    | ForbiddenHeader String -- a forbidden request-header name (the Fetch standard's list, below)
    | BodyNotAllowed String  -- a body on GET or HEAD; the method is the payload
    | MultipartContentType   -- a `Content-Type` header on a multipart body, whose boundary is the host's
    | UnprintableBody (List Schema.Issue)   -- `jsonBody`'s value the schema does not print

pub type Header                -- opaque
pub header : String, String -> Header

pub type Body                  -- opaque
pub emptyBody : Body
pub stringBody : String, String -> Body          -- the MIME type, then the text
pub jsonBody : Schema e a, a -> Body              -- `Schema.print`, sent as application/json
pub multipartBody : List Part -> Body
pub type Part                  -- opaque
pub stringPart : String, String -> Part           -- the field's name, then its value

pub type Expect x a            -- opaque: how the answer is read
pub expectString : Expect Error String
pub expectJson : Schema e a -> Expect Error a
pub expectWhatever : Expect Error ()
pub expectStringResponse : (Response String -> Result x a) -> Expect x a

pub type Response body
    = BadUrl_ String
    | BadRequest_ Problem
    | Timeout_
    | NetworkError_
    | BadStatus_ Metadata body
    | GoodStatus_ Metadata body

pub type alias Metadata =
    url : String                    -- the address that answered, after redirects
    statusCode : Int
    statusText : String             -- "" over HTTP/2 and HTTP/3, which carry none
    headers : Dict String String    -- names lower-cased, repeated headers joined with ", "

pub type Progress
    = Sending { sent : Int, size : Int }
    | Receiving { received : Int, size : Maybe Int }
pub fractionSent : { sent : Int, size : Int } -> Float
pub fractionReceived : { received : Int, size : Maybe Int } -> Float

pub request :
      { method : String
      , headers : List Header
      , url : String
      , body : Body
      , expect : Expect x a
      , timeout : Maybe Duration          -- `Time.Duration`
      , tracker : Maybe (Progress -> ())
      }
    -> Result x a                                                       -- suspends
pub riskyRequest : <the same record> -> Result x a                      -- suspends
pub get : { url : String, expect : Expect x a } -> Result x a           -- suspends
pub post : { url : String, body : Body, expect : Expect x a } -> Result x a   -- suspends
```

`get` is `request` with `"GET"`, no headers, `emptyBody`, no timeout and no tracker; `post` the
same with `"POST"` and its body — Elm's two, and there is no `put` or `delete`, as Elm has none:
those are `request` with their method. **The command form** is `Cmd.task`, `Cmd.keyed` and
`Cmd.cancel` over these (§9.8.2), and Elm's `tracker`-and-`cancel` pair is a key:

```elm
update msg model =
    case msg of
        Search q ->
            ( model
            , Cmd.keyed SearchKey Cmd.Restart λsend ->
                send (Found (Http.get { url = Url.Builder.absolute [ "api", "search" ] [ Url.Builder.string "q" q ], expect = Http.expectJson results }))
            )
        Leave ->
            ( model, Cmd.cancel SearchKey )   -- aborts the request: Elm's `Http.cancel "search"`
```

A body that wants progress passes a tracker that sends: `tracker = Just λp -> send (Progressed p)`
— the progress messages and the answer leave one body in order, so there is no `track`
subscription and no tracker string to match.

**(b) What a request does, in order.** Steps 1–5 run in the calling fiber before anything is sent,
and each failure is decided by a test of the value, not by catching what the host throws, so every
one is named precisely and nothing is caught to find it (rule 9):

1. **The URL** is parsed by `new URL(url, document.baseURI)` inside `Js.catchIf` that takes only a
   `TypeError` (the URL standard's one failure): `Err (BadUrl url)`. A parsed URL with a username or
   password is also `BadUrl url` — `fetch` rejects it with a `TypeError` that is otherwise the
   network's, so it must be found first. Every scheme `fetch` takes is allowed (`data:` and `blob:`
   included); one it does not (`file:`, `ftp:`) is the network error `fetch` gives.
2. **The method** must be an HTTP token (RFC 9110's `tchar`), else `BadRequest (InvalidMethod m)`;
   `CONNECT`, `TRACE` and `TRACK` in any case are `BadRequest (ForbiddenMethod m)`. The method is
   sent as written; `fetch` upper-cases `delete`, `get`, `head`, `options`, `post` and `put` and no
   other, so `"patch"` is sent lower-case, as the standard says.
3. **Each header**: a name that is not a token, or a value that after trimming HTTP whitespace holds
   NUL, CR or LF, is `BadRequest (InvalidHeader name)`; a forbidden request-header name is
   `BadRequest (ForbiddenHeader name)` — `Accept-Charset`, `Accept-Encoding`,
   `Access-Control-Request-Headers`, `Access-Control-Request-Method`, `Connection`,
   `Content-Length`, `Cookie`, `Cookie2`, `Date`, `DNT`, `Expect`, `Host`, `Keep-Alive`, `Origin`,
   `Referer`, `Set-Cookie`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`, `Via`, any name
   beginning `Proxy-` or `Sec-`, and `X-HTTP-Method`, `X-HTTP-Method-Override` or
   `X-Method-Override` naming a forbidden method (the Fetch standard, *forbidden request-header*),
   compared without case. *Why refuse what the host silently drops:* a header the program set and
   the host removed is a silent wrong answer, the kind rule 7 keeps an error (H3). Headers are appended
   in order, so a name given twice is sent once with both values joined, as `Headers` does.
4. **The body**: any body but `emptyBody` on `GET` or `HEAD` is `BadRequest (BodyNotAllowed m)`;
   a `Content-Type` header with a `multipartBody` is `BadRequest MultipartContentType`. A
   `jsonBody` whose value the schema does not print is `BadRequest (UnprintableBody issues)` — it
   is printed when the body is built, which is pure, and the request reports it.
5. **The defaults**: a `stringBody` sends its MIME type and a `jsonBody` `application/json` as
   `Content-Type` unless a header names one (the program's header wins, unlike Elm's XHR, which sent
   both joined); `expectJson` sends `Accept: application/json` unless a header names one. A
   multipart body's `Content-Type` and boundary are the host's.
6. **Sent**: `fetch` with the method, headers, body, `credentials: "same-origin"`
   (`riskyRequest`: `"include"`), `mode: "cors"`, `redirect: "follow"` and the signal of an
   `AbortController` of the request's own. The timeout, when there is one, starts now, on the
   page's `setTimeout` (so the test driver's virtual clock is the one it reads), and runs until the
   body has been read, as Elm's did; a duration of zero or less times out at once. Anything
   `fetch` or `new Request` throws *synchronously* is a defect: steps 1–4 found every failure the
   standard documents for the inputs this module gives it.
7. **The answer.** A status in 200–299 (`response.ok`) is `GoodStatus_`, any other `BadStatus_`;
   both carry the `Metadata` and the body, read as text — UTF-8 with replacement and a leading BOM
   dropped, `response.text()`'s decoding. With a tracker, the body is read through
   `response.body.getReader()` and the same decoding (a `TextDecoder` in streaming mode), so the
   tracker sees each chunk; a `null` body (`HEAD`, a 204) is the empty text. The `Expect` turns the
   `Response` into the result: `expectString` gives the text, `expectWhatever` `()`, and both give
   each failure constructor its `Error`; `expectJson` runs `Schema.parse schema text` on a
   `GoodStatus_` body, an `Err issues` being `Err (BadBody issues)` (a `JSON.parse` failure is its
   `ParseFailed` issue); `expectStringResponse f` hands the `Response` to `f`.

**(c) Every way the host can fail, and how each is told apart.** A promise from `fetch`, from
reading the body or from the reader rejects; the reason is tested in this order, by identity or
by class, never by message, and nothing broader is caught:

| The rejection | Is | Detected by |
|---|---|---|
| the request's own timeout ran out | `Timeout` | `error === reason`, where `reason` is a fresh `DOMException` named `"TimeoutError"` that this request passed to `abort(reason)` when its timer fired |
| the fiber was cancelled (`Restart`, `Cmd.cancel`, a scope's end) | nothing: no fiber waits | `signal.aborted && error === signal.reason` for the canceller's own `abort()`; the rejection is dropped, the timer cleared |
| no answer, or a body cut off | `NetworkError` | `error instanceof TypeError` — the Fetch standard's *network error* for DNS, a refused or reset connection, a CORS failure, mixed content, a CSP block, a redirect loop, and a stream that errors while the body is read. CORS failures are deliberately indistinguishable from the network's to a page, so beni cannot name them apart either |
| anything else | a defect (§9.8.10 (c)) | thrown in the fiber that waited, as today: the page stops with the request's stack |

Before the fetch: `new URL`'s `TypeError` is `BadUrl` (step 1), every `BadRequest` is a test of a
value (steps 2–4). After it: a non-2xx status is `BadStatus` (`expectString`, `expectJson`,
`expectWhatever`) or `BadStatus_` with its body (`expectStringResponse`), and a body the schema
rejects is `BadBody` — so **each failure the standards document is one constructor**, and a
failure none documents still stops the page.

**(d) Cancellation is the fiber's** (§9.8.8, built): cancelling the fiber that waits aborts the
request — its connection, its body read and its timer — and nothing answers. A `Restart` therefore
releases the old request at once, which is what lets a search box's keyed body replace Elm's
`tracker`/`cancel` pair with no string to keep unique.

**(e) Progress.** With `tracker = Just f`, `f` is called in the requesting fiber, in order:
`Sending { sent = 0, size }` before `fetch` is called and `Sending { sent = size, size }` once the
response's headers arrive — `size` the request body's length in UTF-8 bytes (0 for `emptyBody`,
the text's length for a multipart body made only of string parts) — then `Receiving { received = 0,
size }` with `size` the `Content-Length` header's value when there is one, and `Receiving` again
after each chunk with the bytes received so far. **`fetch` reports no upload progress**, so the two
`Sending` calls say only "not sent" and "sent"; a page uploading a large file needs `XMLHttpRequest`
(H4). The bytes counted are those the reader hands over — after the host has undone any
`Content-Encoding` — while `Content-Length` counts the encoded bytes, so `received` may pass `size`;
`fractionReceived` clamps to 1, as Elm's does. A tracker that suspends holds the next chunk back,
and a tracker that throws is a defect.

**(f) What the page sees of the answer.** `Metadata.headers` holds what `response.headers`
iterates: names lower-cased, a header sent twice once with its values joined by `", "`, and — for a
cross-origin answer — only the CORS-safelisted response headers plus those the server lists in
`Access-Control-Expose-Headers`; `Set-Cookie` never. That is the host's rule and is documented on
`Metadata`, not worked around.

**(g) Rungs and cost.** `request`, `riskyRequest`, `get` and `post` suspend; every builder is pure.
A page that imports `Http` and calls nothing ships nothing of it; one that calls `get` with
`expectString` ships the request and its classification but no `Schema`, multipart, tracker or
timeout code, each of which is reached only from a constructor or a branch the program builds
(`backend.md` §9, *A `case` arm on a constructor nothing builds*). The slices measure each against
the `Http` + `Time` page of §9.8.9.

**Where this departs from elm/http, and why.**

- **The direct form takes Elm's command names, and `Expect` has the error type, not a message.**
  beni's direct form is the API (§9.8.11) and a call that waits is Elm's `Task`, so Elm's
  `task`/`Resolver`/`stringResolver` and its `request`/`Expect`/`expectStringResponse` are one pair
  here: `Expect x a` is Elm's `Resolver x a` under `Expect`'s names (H1). The command form is
  `Cmd.task` over it, and Elm's `tracker` string with `cancel` and `track` is a `Cmd.keyed` key, a
  `Cmd.cancel`, and a tracker function that sends.
- **`expectJson` and `jsonBody` take a schema** (`schema.md`), not a `Json.Decode.Decoder` or a
  `Json.Encode.Value`: schemas are beni's JSON story, and one schema reads the answer and writes the
  request.
- **`BadBody` carries the schema's issues, not a string** (H2): each issue has its path and code,
  `Schema.formatIssues` (`schema.md` §14.4, slice S12) makes the text, and a typed failure is what rule 9 asks.
- **`BadRequest` is new**, for the requests Elm let crash (`setRequestHeader` throwing) or reported
  as `BadUrl` (`xhr.open` throwing on a bad method), and for what `fetch` would silently drop. A
  `jsonBody` that does not print — a non-finite `Float`, a refinement a value breaks — is the one
  failure Elm's total `Json.Encode` never had.
- **`timeout` is a `Time.Duration`, and zero means at once.** Elm's `Maybe Float` of milliseconds
  treated `Just 0` as "no timeout" (XHR's convention), a value that says the opposite of what it
  does.
- **The tracker is a function, and `Sending` is coarse.** `fetch` has no upload progress; beni says
  so in the two `Sending` calls rather than inventing a curve (H4).
- **No `bytesBody`, `fileBody`, `filePart`, `bytesPart`, `expectBytes`, `expectBytesResponse`**:
  beni has no `Bytes` or `File` type yet. Each arrives with the type, under Elm's name.
- **The program's `Content-Type` wins over the body's**, where Elm's XHR sent both joined.
- **Requests use `fetch`, not `XMLHttpRequest`**: `fetch` is what cancellation (`AbortController`)
  and streaming are built on, and the only HTTP API a Worker has.

*Not in this version, each additive later:* `cache`, `redirect`, `referrerPolicy`, `keepalive`,
`priority` and `integrity` options; `credentials: "omit"`; a streaming request body; response
streaming as a `Sub`; `Http` on the `node` platform (Node 24 has the same `fetch`, so the module
could be shared once Node is an application platform).

#### 9.8.13 Routing: `Url.Parser`, `Url.Builder`, navigation and `Tea.application`

*Added 2026-10-01* (`plans/status-2026-10.md` §4 Tier 1 item 3, §6 Milestone 2 item 3). Normative
for `Url.Parser`, `Url.Parser.Query`, `Url.Builder`, `Browser.Navigation`, `Browser.UrlRequest`,
`Tea.application` and `Tea.document`, and for how `beni serve` answers a deep link. It completes
§9.8.10 (b)'s two stand-ins, which stay. `plans/browser-platform.md` §2.7's "a capability record,
not Elm's opaque `Key`" is **superseded** by (c) below: the owner's later instruction is Elm's API,
and the `Key` keeps what the record bought (H6). The choices taken for the owner are H6–H10 of
`plans/http-and-routing.md`.

**(a) Where `Url` lives** (H7). `Url`, `Url.Parser`, `Url.Parser.Query` and `Url.Builder` are
pure and use nothing of a page, so they are **core modules**: a library, the `node` platform and a
test can parse and build addresses. `browser`'s `Url` (§9.8.10 (b)) moves to `core/Url.beni`
unchanged, and `browser-tea` stops re-exporting it (every program reaches core). Its
`percentEncode` and `percentDecode` are `Js` over `encodeURIComponent`/`decodeURIComponent`, which
every host has.

**(b) The parser: elm/url 1.0's, with no currying.** Elm's `Url.Parser` threads a continuation
through its type — `Parser (Int -> a) a` is "a parser that will hand an `Int` on" — and that shape
needs nothing beni lacks: a function type returning a function is ordinary (`language.md` §3,
`a, b -> c -> d`), and `slash` composes two continuations as Elm's does. What beni lacks is
*currying*, so a constructor of two fields is `Int, String -> Route`, not `Int -> String -> Route`;
and user-defined operators, so `</>` and `<?>` are written as the functions Elm's own source names
them, `slash` and `questionMark`.

```elm
-- module Url.Parser (core)
pub type Parser a b                                           -- opaque
pub string : Parser (String -> a) a
pub int : Parser (Int -> a) a
pub s : String -> Parser a a
pub custom : String, (String -> Maybe a) -> Parser (a -> b) b
pub top : Parser a a
pub slash : Parser a b, Parser b c -> Parser a c              -- Elm's </>
pub map : Parser a b, a -> Parser (b -> c) c
pub map2 : Parser (a -> b -> r) r, (a, b -> r) -> Parser (r -> c) c
pub map3 : Parser (a -> b -> d -> r) r, (a, b, d -> r) -> Parser (r -> c) c
-- … map4 to map8, the same pattern
pub oneOf : List (Parser a b) -> Parser a b
pub questionMark : Parser a (query -> b), Query.Parser query -> Parser a b   -- Elm's <?>
pub query : Query.Parser query -> Parser (query -> a) a
pub fragment : (Maybe String -> fragment) -> Parser (fragment -> a) a
pub parse : Parser (a -> a) a, Url -> Maybe a
```

`map` is Elm's, subject first: its second argument is a value for a parser that captures nothing
(`map top Home`) and a one-parameter function for one capture (`map (s "blog" |> slash int)
Blog`). **`map2`…`map8` are beni's**: each takes the n-parameter function a constructor of n
fields is, and is `map` over the curried function it makes (`map2 p f = map p λx -> λy -> f x y`).
Elm's `Url.Parser.Query` already has `map2`…`map8`, so the names are Elm's.

```elm
type Route
    = Home
    | Blog Int
    | Comment String Int
    | Search (Maybe String)
    | NotFound

route : Parser (Route -> a) a
route =
    Parser.oneOf
        [ Parser.map Parser.top Home
        , Parser.s "blog" |> Parser.slash Parser.int |> Parser.map Blog
        , Parser.s "user" |> Parser.slash Parser.string |> Parser.slash (Parser.s "comment") |> Parser.slash Parser.int |> Parser.map2 Comment
        , Parser.s "search" |> Parser.questionMark (Query.string "q") |> Parser.map Search
        ]

toRoute : Url -> Route
toRoute url = Maybe.withDefault (Parser.parse route url) NotFound
```

Its behaviour is elm/url 1.0's, read from `Url/Parser.elm`: the path split on `/`, a leading empty
segment and one trailing empty segment dropped; `oneOf` tries in order and the first parser that
consumes the whole path wins (a trailing `/` left over still matches); `s` matches a segment
exactly; `query` and `questionMark` never fail, a missing parameter being the query parser's
`Nothing`; `fragment` hands on `url.fragment` as it is. **Two decoding changes** (H8), both
because Elm's answer is a silent wrong one:

- **A path segment is percent-decoded before `string`, `int`, `custom` and `s` see it**, and a
  segment that does not decode (`Url.percentDecode` is `Nothing`) matches nothing. Elm hands
  `/user/J%C3%BCrgen` to `string` as `"J%C3%BCrgen"` (elm/url issue 16).
- **A `+` in a query key or value is a space**, decoded before the percent escapes, as
  `application/x-www-form-urlencoded` — what a browser writes for a form's `GET` — says. Elm keeps
  the `+`. A pair without `=` and a pair whose key or value does not decode are skipped, as Elm's
  `addParam` skips them, and values keep their order of appearance.

```elm
-- module Url.Parser.Query (core)
pub type Parser a                                              -- opaque
pub string : String -> Parser (Maybe String)
pub int : String -> Parser (Maybe Int)
pub enum : String, Dict String a -> Parser (Maybe a)
pub custom : String, (List String -> a) -> Parser a
pub map : Parser a, (a -> b) -> Parser b
pub map2 : Parser a, Parser b, (a, b -> r) -> Parser r
-- … map3 to map8, the same pattern, the function last
```

As Elm's: `string`, `int` and `enum` are `Nothing` unless the key appears exactly once with a
value that converts; `custom` gets every value of the key, in order.

```elm
-- module Url.Builder (core)
pub type Root = Absolute | Relative | CrossOrigin String
pub type QueryParameter                                        -- opaque
pub absolute : List String, List QueryParameter -> String
pub relative : List String, List QueryParameter -> String
pub crossOrigin : String, List String, List QueryParameter -> String
pub custom : Root, List String, List QueryParameter, Maybe String -> String
pub string : String, String -> QueryParameter
pub int : String, Int -> QueryParameter
pub toQuery : List QueryParameter -> String
```

Elm's, with one change (H8): **each path segment is percent-encoded** (`Url.percentEncode`), as
query keys and values already are — `absolute [ "tags", "c/c++" ] []` is `/tags/c%2Fc%2B%2B`, where
Elm's is `/tags/c/c++`, a different path. With the parser's decoding, `parse` of a built URL gives
back the segments it was built from. `custom`'s fragment is written as given.

**(c) `Browser.Navigation`: the page's address, changed on purpose.**

```elm
-- module Browser.Navigation (browser), re-exported by browser-tea
pub type Key                                                    -- opaque, equatable: a model may hold it
pub key : () -> Key                                             -- impure: the page's key
pub type Error = BadUrl String | CrossOrigin String | Throttled

pub pushUrl : Key, String -> Result Error ()                    -- impure
pub replaceUrl : Key, String -> Result Error ()                 -- impure
pub back : Key, Int -> Result Error ()                          -- impure
pub forward : Key, Int -> Result Error ()                       -- impure
pub load : String -> Result Error ()                            -- impure
pub reload : () -> ()                                           -- impure

-- §9.8.10 (b), kept
pub currentUrl : () -> Maybe Url
pub eachUrlChange : (Url -> ()) -> ()                           -- suspends
pub onUrlChange : (Url -> msg) -> Sub msg
-- new
pub eachUrlRequest : (Browser.UrlRequest -> ()) -> ()           -- suspends
pub onUrlRequest : (Browser.UrlRequest -> msg) -> Sub msg

-- module Browser (browser)
pub type UrlRequest
    = Internal Url
    | External String
```

**The `Key`.** Elm hands a `Key` only to `application`, so that a program that changes the address
is one that hears every change ("navigation in elements", `references/elm-browser/notes/`): a bare
`history.pushState` fires no `popstate`, and a program that pushed would never learn of it. beni
closes that hole where it is instead of by who holds the key: **every change `pushUrl`,
`replaceUrl`, `back` and `forward` make is announced to every follower** (`eachUrlChange`,
`onUrlChange`), so no program on the page can fall out of step with the address, whoever pushed.
The key is therefore not a permission, and `key ()` hands the page's one key to any code, which is
what makes the direct form complete — The Elm Architecture is a framework on top of beni (§9.8.11),
and `Tea.application` gets its key from `key ()` like anyone. It is kept, as Elm's API, because it
is the one value a test driver for TEA programs will replace to fake navigation (§9.8.9, W55;
`plans/browser-platform.md` §2.7's capability record, inside the key) — so a program's navigation
goes through a value it was given (H6).

**Each function, and its failures** (rule 9: each found by a test of the value where it can be,
each `DOMException` named where it cannot, nothing else caught):

- **`pushUrl key url`** resolves `url` against the page (`new URL(url, location.href)`, a
  `TypeError` being `Err (BadUrl url)`); an origin other than the page's is `Err (CrossOrigin
  url)` — `pushState` would throw `SecurityError` for it; then `history.pushState(null, "", url)`.
  A `SecurityError` from that call is `Err Throttled`: with the URL checked, the documented reason
  left is the rate limit Safari and Firefox enforce by throwing (Elm's note: about 100 calls in 30
  s). Chrome enforces its own by dropping the call with a console warning, so after the call
  `location.href` is compared with the resolved URL and a mismatch is `Err Throttled` too — the one
  way to see a silent drop. On `Ok ()`, every follower is sent the new `Url` once (below).
- **`replaceUrl`** is the same with `replaceState`.
- **`back key n`** and **`forward key n`** call `history.go(-n)` and `history.go(n)`; `n = 0` does
  nothing (Elm's `n && history.go(n)`). A `SecurityError` is `Err Throttled`. The address changes
  later, when the host traverses: the `popstate` it fires is what followers hear. *Unlike Elm*, no
  message is sent at the call — Elm's `go` sent `onUrlChange` with the address *before* the
  traversal, then the `popstate` sent the new one.
- **`load url`** leaves the page: `location.assign(url)`. An address that does not resolve is `Err
  (BadUrl url)`, and so is a `javascript:` one, which would run text as script (the same rule as
  markup's URL attributes). A `SyntaxError` from `assign` is `Err (BadUrl url)` and a
  `SecurityError` `Err Throttled`. Elm caught every exception and reloaded instead. A `load` of the
  page's own address with only a different fragment does not leave the page — the host scrolls and
  fires `popstate` — so followers hear it, and `load`'s "always a page load" is Elm's prose, not
  the host's.
- **`reload ()`** is `location.reload()`, which documents no failure for a page's own document.
  Elm's `reloadAndSkipCache` passed `forceGet`, a Firefox-only argument every other engine ignores,
  so it is **not provided**: it would do what `reload` does while saying otherwise.

**Followers.** `eachUrlChange f` calls `f` with the new `Url` after each `popstate` and after each
successful `pushUrl`/`replaceUrl` anywhere on the page, in order, for as long as the calling fiber
runs (§9.8.11); an address that is not a `Url` is skipped. The announcement of a push is made
during the push: each follower's listener reads `currentUrl ()` then and queues it, as a `popstate`
is queued (§9.8.10 (a)), so it reaches `f` at its fiber's next turn and two pushes in one `update`'s
command are two values, in order. The announcement is an event of the platform's own on the window
(`"beni:navigate"`), not a `popstate`: other code on the page sees `popstate` only for the host's
traversals, as it should.

**Link requests: Elm's guard, made precise.** `eachUrlRequest f`, for as long as the calling fiber
runs, holds one `click` listener on the **window**, in the bubbling phase — after every handler on
the page, the program's delegated ones included, have run. For each click it decides, **while the
event is dispatched**, in this order:

1. the event's default was not already prevented — a handler that prevented it has handled it
   (*beni's*: Elm checks nothing here);
2. `event.button === 0` (Elm's `button < 1`) and none of `ctrlKey`, `metaKey`, `shiftKey`,
   `altKey` is held (*beni adds `altKey`*: an Alt-click downloads the link in Chrome and Firefox on
   Windows and Linux, which the user asked for);
3. the nearest `HTMLAnchorElement` at or above `event.target` in the composed path has an `href`;
4. it has no `download` attribute, and its `target` is empty or `_self` (*beni adds `_self`*, the
   same browsing context; Elm intercepts only an empty `target`).

When all hold, it calls `preventDefault()` and queues `Internal url` when `Url.fromString a.href`
is a `Url` with the page's protocol, host and port (Elm's comparison), else `External a.href`. A
click that fails a test is left to the host, which follows the link. **The listener covers the
whole document**, not only a program's mount: a link in markup the server wrote around a
`Browser.mountAt` program becomes a request too, which is what Elm's "navigation in elements" note
asks ports for. A page should have one follower of requests; two each get every request.
`onUrlRequest tag` is `Sub.listen` over it, keyed by a type of this module (§9.8.3).

A link whose only difference from the page is its fragment (`href="#top"`) is `Internal`, as in
Elm, and a program that pushes it gets no scroll; scrolling to a fragment is the program's
(`Dom.scrollIntoView`).

**(d) `Tea.application` and `Tea.document`.**

```elm
-- module Tea (browser-tea)
pub type alias Document msg =
    title : String
    body : Html msg

pub document :
      { init : ( model, Cmd msg )
      , update : msg, model -> ( model, Cmd msg )
      , view : model -> Document msg
      , subscriptions : model -> Sub msg
      }
    -> Program

pub application :
      { init : Url, Key -> ( model, Cmd msg )
      , update : msg, model -> ( model, Cmd msg )
      , view : model -> Document msg
      , subscriptions : model -> Sub msg
      , onUrlRequest : UrlRequest -> msg
      , onUrlChange : Url -> msg
      }
    -> Program
```

Elm's three programs, minus flags (beni has none). `document` is `element` whose render also sets
`document.title` to the view's `title` whenever it differs from the page's — read and written in
the render that renders the body, so the title and the body never disagree after a flush.
`application` is `document` plus:

- `init` gets `currentUrl ()` and `key ()`. **A page whose address is not a `Url`** (opened from a
  `file:` address) **stops at start, as a defect**, with the development crash screen saying an
  application needs an `http` or `https` address — the answer W9 gave a missing mount element, and
  Elm's (`__Debug_crash(1)`), since no route can be computed. A page that must run there uses
  `document` and `currentUrl ()`'s `Maybe`.
- its subscriptions are the program's batched with `Navigation.onUrlRequest onUrlRequest` and
  `Navigation.onUrlChange onUrlChange`, so link requests and address changes arrive as messages
  through `update`, and a program's own `onUrlChange` shares their fiber (§9.8.5).

`application` reaches no fiber beyond what `element` with two subscriptions does. Mounted with
`Browser.mountAt` it still follows the whole document's links, as (c) says.

```elm
update msg model =
    case msg of
        ClickedLink (Browser.Internal url) ->
            ( model, Cmd.task (λ() -> Navigation.pushUrl model.key (Url.toString url)) Pushed )

        ClickedLink (Browser.External href) ->
            ( model, Cmd.task (λ() -> Navigation.load href) Pushed )

        UrlChanged url ->
            ( { model | route = toRoute url }, Cmd.none )

        Pushed _ ->
            ( model, Cmd.none )
```

**(e) Deep links on `beni serve`.** `frontend.md` §10.4 already answers a path that names no file
and whose last segment has no `.` with `index.html`, and the page shell names its entry by an
absolute path, so `/blog/42` reloads into the application. **Amended here** (H9): a `GET` for a
path that names no file is also answered with `index.html` when its `Accept` header lists
`text/html` — what a browser sends when it navigates — whatever its last segment, so a route such
as `/users/jane.doe` survives a reload; a request without it (a module, a fetch of a missing
`.json`) is still `404`. A program served under `"base": "/app/"` sees `/app/` at the front of
`url.path` and routes with `Parser.s "app"`, as it will when deployed there; nothing hides the base
from it. A static host in production needs the same fallback configured; the user guide says how.

**Where this departs from elm/url and elm/browser, and why.**

- **`</>` and `<?>` are `slash` and `questionMark`**, Elm's own internal names: beni has no
  user-defined operators (`language.md` §0).
- **`map` is subject first, and `map2`…`map8` exist** because a beni constructor of n fields takes
  n parameters, not one at a time; Elm's `Url.Parser.Query.map2`…`map8` are moved to subject first
  the same way.
- **Path segments are decoded and `+` is a space in a query; built path segments are encoded**
  (H8) — each a silent wrong answer in Elm.
- **`Url` and its parser and builder are core**, not a package of the browser (H7).
- **`key ()` is public, and every push is announced** (H6): the hole Elm's `Key` fenced is closed
  at the announcement, so the direct form can do what `Tea.application` does.
- **`pushUrl`, `replaceUrl`, `back`, `forward` and `load` return `Result Error ()`** where Elm's
  were `Cmd msg` that crashed on a throttled or cross-origin push. The command form is
  `Cmd.task`/`Cmd.do` over them (H10 asks whether to add command-returning helpers).
- **`back` and `forward` send nothing at the call** (Elm's sent the old address), **`reloadAndSkipCache`
  is not provided**, **`load` refuses `javascript:`**, and **the link guard adds `altKey`, `_self` and
  an already-prevented default**.
- **`onUrlRequest` and `eachUrlRequest` are new**: Elm offered link requests only to
  `application`; here any program can follow them.
- **`Document.body` is one `Html msg`** (a fragment for several roots), not a `List (Html msg)`:
  a beni view is one markup tree.
- **An application opened at a non-`http(s)` address stops as a defect**, as Elm's did, with the
  crash screen saying why instead of `Debug.crash`'s code 1.

#### 9.8.14 A defect closes the program's scope

*Added 2026-10-02.* The rest of the owner's W2 — option (b), *tear down the mount: close the root
scope, so finalisers run and requests abort* — and R45 §8 item 8, which §9.8.10 (c) left as **Not
yet**. Today a defect stops the page and leaves every fiber where it was: a request in flight runs to
its end, a timer fires into a stopped scheduler, a subscription's listener stays on the window, and
no `bracket` release runs. This section specifies the teardown. Nothing in it changes what a program
that has no defect does, and nothing in it is a `catch` (`CLAUDE.md` rule 9).

**(a) The guarantee.** When a defect stops a page, every finaliser that the page's fibers hold runs
**exactly once**, in the order (e) gives, and is told `Cancelled`; every host resource a parked
fiber holds is released; and no other code of the program runs. What is reached, and how:

| What | Held as | Released by |
|---|---|---|
| a `Task.bracket` release | a fiber's finaliser list | the fiber's unwinding, with `Cancelled` |
| a nested `Task.scope` | a finaliser of the fiber that opened it | the same unwinding: its fibers cancelled and waited for |
| a timer (`Time.sleep`, `Time.every`'s body), a request (`Http`), a listener (`Listen.each`, every `each…` and subscription), a `Dom.rendered` wait | the canceller a parked fiber's `Task.callback` registered | the interrupt itself, at once (step 1 of (d)) |
| a command's body in a fiber, keyed or not, a subscription's fiber, a `Restart`'s cancelling fiber | a child of the program's root scope | the root scope's close |
| what any of those `spawn`ed | a child fiber | its parent's unwinding, children first (A11) |
| a command's body queued with no fiber (`Task.soon`, §9.8.11 (b)) | the scheduler's queue | nothing: it is dropped unrun, and what it would have spawned never exists |
| after-render work (`Hosted.afterRender`, `Cmd.afterRender`) | `Browser.beni`'s `later` queue | nothing: dropped unrun, as every render after the defect is |
| a `bracket` left open outside any fiber by the throw (in `soon` work, in `init`) | the outside-any-fiber record's finaliser list | a fiber of its own, step 4 of (d) |

A dropped body or after-render function is program code, which (c) of §9.8.10 says no longer runs; it
holds no finaliser — work that cannot suspend cannot have parked on anything — so dropping it
releases nothing that needed releasing. Outlets and relays are not closed one by one: every send is
already dead through the page's `dead` flag, from a body, a finaliser or a listener alike.

**What cancellation already lets a cancelled fiber do, it may do here, and nothing more.** A fiber
interrupted inside an uninterruptible region — a `bracket`'s acquire — finishes the region and runs
on to its next suspension point, where the interrupt is delivered (`transparent-effects-proposal.md`
§16.4; report 43 §9.2's rule 2). Delivering it at the end of the region instead would leak the
resource the acquire just returned, whose release `bracket` registers only after the region, so the
rule is kept. That code can no longer send, render or start a fiber that runs (below), so what it
can do is what a release can do.

**(b) Three phases: stop, report, tear down.** A defect is a throw that escapes one of the guards
§9.8.10 (c) lists — the listeners' `fire`, the hosted dispatcher, the render loop's `flush`, `run`,
and core's scheduler drain. Its handling is split in three, so that **nothing that can throw runs
while the original throw is in flight**:

1. **Stop**, synchronously, in the guard's cleanup (a `Js.finally`, or `Task.js`'s `finally`): the
   page's `dead` flag is set; core's scheduler enters *stopping* (it runs nothing until the teardown
   starts); the after-render queue is emptied; in a development build the crash screen is shown.
   No program code, no finaliser and no canceller runs here. If any of them threw inside the
   cleanup, JavaScript would replace the original exception with theirs, and the defect the
   developer must see would be lost.
2. **Report.** The throw goes on, unchanged, to the host, which reports it as an uncaught
   exception: the console with its stack, `window.onerror` and the crash screen's `error` listener.
3. **Tear down**, in a macrotask core schedules during the stop (`Task.js`'s `macrotask`:
   `setImmediate` where it exists, a `MessageChannel` otherwise), so it starts only after the host
   has reported the original. A microtask would also run after the report in a browser, but a
   macrotask also lets a page that stopped mid-flush finish its task before the teardown begins, and
   it is the same in both of the test driver's DOMs.

**(c) How the host reaches every root scope: core keeps them.** The teardown is the runtime's, not
the architecture's. Core's `Task.js` already holds every fiber it has started, except for the
roots. It now also keeps a registry of **every root**, in creation order: each scope `openRoot`
made that `closeRoot` has not closed, each fiber `start` made that has not ended, and the record of
work outside any fiber. One new kernel operation closes them all:

```elm
--| Stop every fiber: close every root scope, cancel every fiber and run its cleanup, drop queued
--| work, and start nothing new. Cleanup that suspends is given `deadline` milliseconds from the
--| call; `done` is called once every fiber has ended, with how many cleanups were cut short.
--| What a platform calls when its program stops; a program never does.
pub foreign impure shutdown : Int, sync (Int -> ()) -> ()
```

**`shutdown` itself does only phase 1's part**: it enters *stopping* and schedules the teardown's
macrotask, and returns; it calls no canceller and no finaliser, so it is safe inside a guard's
cleanup. A second call does nothing. **Why core, and not `Tea`.** `Tea.element` opens its root scope in
`init` and keeps it in its state, which the platform cannot see, and an architecture written
straight on `Browser.hosted` opens its own. If each had to hand its scope to the host, an
architecture that forgot to would leak, and the page's guarantee would rest on every framework
remembering it. With a registry, **`Tea` changes by nothing**, and so does any other `hosted`
program: every root `openRoot` makes is closed, whoever made it. A `Browser.program` page runs no
fibers and reaches no `Task`; its stop is today's. The registry costs one array in `Task.js` and a
push and a removal per root, and only a build that keeps `openRoot` or `start` keeps it.

**Who calls it.** Two paths reach one teardown:

- **A throw in a fiber** (or in `soon` work): core's drain guard enters *stopping*, notes the fiber
  that threw (the *culprit*) or the `soon` work, resets the state the throw left behind (the
  current fiber, the pending suspension, the running `soon` record, the outside record's masks),
  schedules the teardown with the deadline the platform gave, and calls the platform's
  `Task.onDefect` hook, which stops the page as before.
- **A throw in the program's own code** outside any fiber (a handler, `update`, `view`, `settle`,
  after-render work, `init`): `Rt.beni`'s `stop` calls the page's *teardown*, a reference that is
  null until a hosted mount fills it. The runtime hands a hosted mount a fifth argument for it —
  `h(root, flush, setPhase, stop, onStop)`, `onStop` storing the function — and `Browser.beni`'s
  `host` passes a function that empties the after-render queue and calls `Task.shutdown deadline
  finished`. A page whose mounts are all
  `Browser.program`s fills nothing and ships nothing of `Task`, as now (§9.8.9's measurements).

`deadline` is a constant of the `browser` platform, **1 000 ms** (choice 3 below), as W3's slice
and budget are the platform's.

**(d) The teardown, step by step.** Every step runs in the teardown's macrotask or in the drains
after it; each is deterministic, ordered by creation and by the scheduler's FIFO.

1. **The sweep.** Every root in the registry, in creation order: a root scope is marked closed and
   each of its fibers interrupted, in the order they were started; a root fiber is interrupted;
   the outside record's children are interrupted. The culprit, if any, is unwound as an
   interrupted fiber is (its continuations discarded, its children cancelled, its finalisers run)
   unless it was unwinding already, when its stack is cut back to its next finaliser (step 3). An
   interrupt delivered to a parked fiber calls its wait's canceller **now**, so every timer is
   cleared, every request aborted, every listener removed and every `Dom.rendered` wait dropped
   before any finaliser runs: what the host holds is released by platform code alone, which no slow
   or failing finaliser can delay. **The interrupted fiber is queued before its canceller is
   called**, so a canceller that throws ((g)) cannot leave a fiber that never unwinds.
2. **Queued work.** In *stopping*, the drain drops every `soon` entry unrun and cancels any child it
   had spawned before the defect. Fiber entries run, and each fiber that runs is already
   interrupted.
3. **Unwinding.** The drain runs as it always does — FIFO, 64 resumptions and then a macrotask —
   and each fiber unwinds by the existing rule: its children are cancelled and waited for, then
   its finalisers run, **last first**, uninterruptibly, then it ends `Cancelled`, and whoever
   joined or waited on it is answered. Each finaliser runs above a **boundary** on the fiber's stack,
   so the teardown can tell one finaliser's continuations from the next one's ((f), (g)).
   Finalisers may suspend, as ever (report 43 §9.4): a finaliser that waits on a timer or a request
   is resumed normally, until the deadline.
4. **Leftovers outside any fiber.** Finalisers a throw left on the outside-any-fiber record — a
   `bracket` whose use threw in `soon` work or in `init` — run last first, in one fiber the teardown
   starts for them after the sweep, under the same rules.
5. **Nothing new runs.** A fiber spawned while *stopping* — by a finaliser, `spawnIn` a closed root,
   `start` — is cancelled before it runs, as a fiber spawned into a closed root scope is today
   (§9.8.7). `Task.soon` queues nothing. A `send` does nothing (`dead`); `Browser.flush` does nothing;
   `Dom.rendered` never answers, since no render comes.
6. **The end.** When every fiber has ended, the deadline's timer is cleared, the scheduler stops for
   good (no drain runs again, and a late host callback finds its wait done and is dropped, as
   today), and `done` is called with the number of finalisers the deadline cut short, normally 0.

Each finaliser runs exactly once because each fiber unwinds once (`unwinding` makes a second
interrupt a no-op), a fiber's finaliser list is taken whole when it starts to unwind, and a
finaliser is popped before it is called — so one that threw or was cut short is never started
again. A `bracket` whose release was running when the defect struck had already popped it, on its
success path, and is not released twice. A root scope closed once is not closed again, and a second
`shutdown` does nothing.

**(e) The order, in one place.** The host's resources, all at once in the sweep, in root creation
order and then fiber start order. Then each fiber's cleanup in the order the scheduler reaches it:
the root scopes' fibers in start order, interleaving only where a finaliser suspends; within one
fiber, its children's cleanup first, then its own finalisers, last registered first. Several
programs' roots in the order the programs were started (`Browser.programs`' order). This is the
order `Task.closeRoot` and `Task.scope`'s close already use, and Effect's `interruptAll` (children
interrupted in insertion order, then awaited); a test can therefore pin it with a log.

**(f) A finaliser that suspends: a deadline, not a hang.** A finaliser that waits forever — on a
request no server answers, on `Dom.rendered` — holds up only its own fiber, since fibers unwind side
by side and the page's thread is never blocked. But it would hold back **the finalisers registered
before it on the same fiber**, which would then never run. So the teardown has a **deadline**,
P2 §6.3's *bounded shield* (Trio's `move_on_after(CLEANUP_TIMEOUT, shield=True)`, not Kotlin's
unbounded `NonCancellable`), counted from the sweep on the host's timer (`setTimeout`, which the
test driver's virtual clock owns). When it passes:

- each fiber parked inside a finaliser has its wait cancelled (its canceller runs, its late answer
  is dropped) and **the rest of that finaliser is abandoned** — its continuations, back to the
  finaliser's boundary, are discarded — and the fiber goes on to its next finaliser;
- from then on, each finaliser still to run runs until its first suspension and is abandoned
  there.

Every finaliser therefore **starts** exactly once, and the teardown ends in bounded time. The count
of abandoned ones reaches `done`; the `browser` platform writes one `console.warn` line when it is
not 0 (in both builds: it is a cleanup that did not happen, which a release's log should hold, and
it costs one short string) and, in a development build, adds the same line to the crash screen. A
synchronous loop that never returns cannot be interrupted under any lowering (P2 §6.2) and hangs the
page as it would anywhere; nothing here claims otherwise.

**(g) A finaliser that throws.** A1 makes a finaliser infallible in its type (`-> ()`), but a
`foreign` it calls may still throw, and so may a canceller in the sweep or the masked code of (a).
**Nothing catches it.** The drain's guard, a `finally`, sees the drain did not complete and, since
the runtime is already *stopping*: cuts the throwing fiber's stack back to its next finaliser
boundary (the finaliser that threw counts as run) and queues it again — or, for a throw out of
masked code, unwinds the fiber as the sweep would have; resumes the sweep at the next root, for a
throw from a canceller; and schedules the drain to go on in a new macrotask. The throw then goes on
to the host **as its own uncaught exception**: the console shows it with its stack, `window.onerror`
sees it. It does not call `onDefect` again and does not re-enter *stopping*.

So **the original defect is never swallowed and never replaced**: it reached the host a task before
any finaliser ran ((b)), and each later throw is a separate report. Nor are they combined into one
value, as Effect's `Cause` combines them — beni has no `Cause` (A1), and the host's two reports
are the two facts. In a development build the crash screen keeps the original as its message and
lists each later one beneath it under *While stopping, cleanup also threw:*; its `error` listener
stays registered until the teardown ends rather than `once`. Every other finaliser, of that fiber
and every other, still runs.

**(h) The render loop and after-render work.** Nothing renders after the stop: a flush already
queued finds `dead` and does nothing, `settle` — and so `Tea`'s subscription diff — never runs again
(subscriptions end through their fibers, not through the diff), and `view` is not called. The DOM is
left as the last render wrote it, a half-written patch included, under the development crash screen,
to be inspected. After-render work queued but not run is dropped ((a)); a fiber waiting in
`Dom.rendered` is a parked fiber and is interrupted in the sweep, its canceller taking it out of the
waiters. The hosted loop's latches (`busy`, `dispatching`) are released by their own `Js.finally`
cleanups, as today, though nothing reads them again. **The delegated and own listeners stay on the
document, inert** (they test `dead`; choice 5); every listener a *fiber* added is removed by its
canceller.

**(i) Several programs: one defect stops them all** (choice 2). §9.8.10 (c) already stops every
program of the page, and the teardown follows it: every root scope of every program is closed. One
build is one application, its programs share one heap, one scheduler and one fiber runtime, and A1's
defect is a bug in core or a platform, not in one program's code: the scheduler's own queue is
shared, and a throw out of its drain leaves it mid-run for every program. Continuing the others
would run them on state nobody can vouch for, which is what A1 forbids. A host page that embeds an
independent beni application builds it separately, and gets its own runtime. Isolating programs
would need every fiber attributed to a program (each knows its root through its parent chain, so it
is possible), a guard per mount for synchronous throws, and a crash screen per mount; it is the
road to W51's unmount, which closes one root with the same steps 1–3, and is not taken now.

**(j) Development and release.** **The teardown is the same in both builds**: finalisers are the
program's semantics, and a release build behaves exactly as its development build does
(`language.md` §6). The differences are only what §9.8.10 (c) already makes them: the crash screen,
with its later-throw list and its abandoned-cleanup line, is in no release build (`Js.development`).
A release build's log is the host's reports of the throws and the one `console.warn` of (f).

**(k) Node is unchanged** (choice 7). Under Node an uncaught exception ends the process before any
macrotask can run, so a teardown there would need a process-wide `uncaughtException` handler to keep
it alive — a hook that, unlike a guard, does stop the exception from crashing the process, and must
then reproduce Node's report and its exit code by hand. Node keeps
`transparent-effects-proposal.md` §16.5's *A defect on Node*: the report, exit 1, no finaliser;
the operating system closes what the process held. The kernel's `shutdown` is platform-free and is
tested under Node by calling it directly ((m)).

**(l) Against Effect v4**, the gold standard for interruption and finalisers
(`references/effect`, `packages/effect/src/internal/effect.ts`). Effect's run loop turns a throw
into a defect, `exitDie(error)`, and unwinds the fiber's stack through every `onExit` with that
`Exit` (`runLoop`, `OnExit`'s `contE`); a scope closes with an `Exit`, running its finalisers last
first and sequentially, each one's own outcome collected with `exit(…)` so one failure skips none,
and the failures combined into the closing cause (`scopeCloseUnsafe`, `scopeCloseFinalizers`,
`combineFinalizerCause`); a finaliser added to a closed scope runs at once; `fiberInterruptAll`
interrupts every child, then awaits them all; and no deadline bounds a finaliser. beni keeps every
one of those structural rules: last first, every finaliser run even after one fails, children
before the parent's finalisers, work added after the close cancelled at once, interrupt all and
then wait. It departs in three places, each forced: **the defect is not a value** (A1; a release
is told `Cancelled`, choice 1), **a later failure is a separate host report, not a combined cause**
(there is no `Cause`, and rule 9 keeps the original intact), and **the teardown has a deadline**,
because a page has no process exit to fall back on and P2 §6.3 already chose the bounded shield.
Effect's own `runLoop` turns *every* throw into a value with a broad `catch (error)`; beni's guards
are `finally` blocks that let the throw go on, which is rule 9's requirement.

**(m) What changes, for the implementer.**

- **`core/Task.js`**: the root registry; the *stopping* and *stopped* states; `shutdown`; the drain
  guard's stopping path (culprit, state reset, scheduling, `onDefect`) and its secondary-throw path
  ((g)); `soon` entries dropped while stopping; finaliser boundaries on the unwinding stack and the
  cut back to one; the deadline's timer and its abandonment; `interrupt` queuing the fiber before
  calling the canceller; the outside record's leftover finalisers. `core/Task.beni` gains the
  declaration in (c). `openRoot`, `closeRoot`, `onDefect` and `start` keep their signatures.
- **`platforms/browser/Rt.beni`**: a `teardown` reference, the fifth mount argument, and `stop`
  calling the teardown, once, after setting `dead`; the crash screen's later-throw list, its
  abandoned-cleanup line, and its `error` listener kept until the teardown ends.
- **`platforms/browser/Browser.beni`**: `host` hands `onStop` the function of (c) — the
  after-render queue emptied, then `Task.shutdown` with the deadline and its `done` (the warning,
  and the screen's line in development).
- **`platforms/browser-tea/Tea.beni`**: nothing.

Estimated cost: about 70 lines of `Task.js` and 25 of beni. A page whose mounts are all
`Browser.program`s and an `element` that runs no fiber are byte for byte unchanged; a page that
runs fibers pays the registry, `shutdown` and the deadline, estimated 250–350 bytes brotli, to be
measured on `bench/size.mjs`'s `Http` + `Time` page.

**(n) Tests.** The pages are `tests/corpus/browser/tea/` (and one `browser/dom/` page on `hosted`),
each with a `throws` step for the defect and the transcript as golden, a `.release-expected` where
the crash screen differs, and run hashes; the virtual clock drives every timer, and so the deadline.
Two driver steps come first, so that what the host still holds is visible without program code:

| Step | Logs |
|---|---|
| `timers` | `(timers: <n>)`, the virtual clock's pending timers |
| `listeners <window\|document> [<name>]` | `(listeners: <n>)`, the listeners of that target (of that event) the page added and has not removed, counted by the prelude's wrapper |

A finaliser's running is shown by a `Log.info` line in its release (not `Debug.log`, so the release
pass needs no exemption), which prints the `Exit` it was given.

| Fixture | Pins |
|---|---|
| `DefectRunsReleases` | two bodies in fibers, one inside two nested `bracket`s, the other inside one; a third body throws. The releases log, each once, inner before outer, the first body's before the second's, each told `Cancelled`; nothing the bodies would have sent after arrives |
| `DefectReleasesHost` | R45 §8 item 8: a body sleeping, a keyed `Http` request to a faked service sleeping on the clock, a `Time.every` and an `onResize` subscription; a defect in `update`. Before it `timers` and `listeners window resize` count them; after it both are 0, and `advance` sends nothing |
| `DefectQueuedDropped` | a body that cannot suspend queued behind the one that throws, and an after-render body queued in the same update: neither logs; a fiber waiting in `Dom.rendered` has its release run |
| `DefectReleaseSuspends` | a release that sleeps 200 ms and then logs; another fiber's release that sleeps 5 000 ms, followed by an earlier-registered release in the same fiber. `advance 200` logs the first; `advance 1000` reaches the deadline: the long one never logs its second line, the one after it in its fiber logs, the warning is logged, and the development screen shows it |
| `DefectReleaseThrows` | a release that throws during the teardown, and two others. The `throws` step records the original, then the release's, in that order; both other releases log; the screen keeps the original first and lists the second |
| `DefectReleaseRunning` | a `Restart` in progress — the old body cancelled and its release mid-sleep — when another body throws: the release runs once, not twice |
| `DefectEveryProgram` | `Browser.programs` with two `Tea.element`s; a defect in the first's `update` runs the second's releases, and a click on the second does nothing |
| `DefectInViewReleases` | the synchronous path through the render loop's guard: a throw in `view` closes the root scope as a fiber's throw does |
| `browser/dom/HostedRootReleases` | a program straight on `Browser.hosted` with a root scope of its own, never handed to the platform, whose fiber's release runs: the registry, not `Tea`, reaches it |
| `run/TaskShutdown` (Node) | `Task.shutdown` called directly, with a deadline of 100 and a `done` that prints its count: releases in the order (e) gives, a `soon` dropped, a new spawn cancelled before it runs, a second call doing nothing |
| `run/TaskDefectOnNode` (Node, `.crash`) | the unchanged Node path: a fiber's throw exits 1 with the report, its release unrun |

`browser/tea/DefectInFiber`'s golden gains a `timers` step after the throw, now 0 where the timer
used to fire into a stopped scheduler. Every page also runs under `zig build test-browser` in Chrome.

**(o) Choices for the owner.** Each was taken here as recommended, so the slices can proceed.
*Confirmed 2026-10-02: the owner took all eight as recommended.*

| # | Choice | Recommendation | Alternative |
|---|---|---|---|
| 1 | What a release is told on a defect | **`Cancelled`**: `Exit` stays `Done a \| Cancelled` (A1: a defect is not a value), and a release cannot recover anything anyway | a third constructor, `Defected`, so a release can tell a crash from an ordinary cancel (Effect's `Exit.Failure` with a `Die` cause); every `case` on `Exit` changes |
| 2 | `Browser.programs`: does one program's defect stop the others? | **Yes, all stop and all are torn down**: one heap, one scheduler, and A1's defect is core's or a platform's | stop only the culprit's program and close its root; attribute fibers by root, a guard and a crash screen per mount; the way to W51's unmount |
| 3 | A finaliser that suspends during the teardown | **Allowed, bounded by a 1 000 ms deadline** (a `browser` platform constant), then cut at its wait, the next finaliser going on | 0 ms: each finaliser runs to its first suspension and no further; or unbounded, as Effect, at the cost of the finalisers after a stuck one |
| 4 | A finaliser that throws during the teardown | **A separate host report**, the rest of the teardown going on in a new macrotask; the original stays first; the development screen lists the later ones | the screen shows only the original (later throws in the console only) |
| 5 | The page's delegated and own listeners | **Left on the document, inert** behind `dead`: removing them changes nothing a user sees and costs a registry | one `AbortController` for the page, its `signal` on every `addEventListener`, aborted at the stop (W2's literal "remove every listener"; worth it with W51's unmount) |
| 6 | Who closes the roots | **Core's registry of roots**, so `Tea` and any other `hosted` architecture change by nothing | each architecture hands its root scope to the host (`Hosted.onStop`); a framework that forgets leaks |
| 7 | Node | **Unchanged**: report, exit 1, no finaliser; no `uncaughtException` hook | an `uncaughtException` hook that prints Node's report, runs the teardown under the same deadline, then exits 1 |
| 8 | The abandoned-cleanup warning | **`console.warn` in both builds**, and on the screen in development | development only, so a release ships no string for it |

## Appendix — what is deliberately not done

- **User-writable `foreign`.** It has never been made safe in any of the fourteen languages surveyed,
  and the wall is the product.
- **A synchronous port variant.** Three independent mechanisms in Elm exist to prevent it, and the
  failure class it admits is the one nothing can catch.
- **A synchronous escape hatch "just for core".** Core is where the bugs in §4.1 were.
- **Settling for opaque-JSON-only ports.** That is the status quo, and it is the *unchecked* path.
