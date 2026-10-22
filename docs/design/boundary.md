# The JavaScript boundary — platforms, ports and `foreign`

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


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

*Withdrawn 2026-10-03 by the owner; the text below is kept as the record.* **A project names
exactly one platform, and every line of JavaScript a build runs is in that platform.**
- **Libraries cannot break beni's guarantees.** A library package is pure beni: it writes no
  `foreign` and ships no `.js`. It may import its platform's modules, and so be platform-specific,
  but whatever it does goes through what a platform wraps. A dependency therefore cannot bring a
  throw, a mistyped value or an unmanaged effect with it, by construction.
- **Ports are not built.** An app that needs JavaScript the platform does not wrap — an npm
  library, a browser API — writes its own platform: a package of the project, layered on a shipped
  one by §9.1 (`"platforms": ["browser-tea"]`), with `foreign` declarations and siblings under §4's
  checks and rule 9's precise-error discipline. The project names that platform as its one
  platform. Platforms are trusted, the project's as the shipped ones are.
- **"One" is what the project names.** §9.1's layering is how platforms are built, kept as it is:
  `browser-tea` over `browser` over `html` is one platform to the program that selects it, and a
  project platform is one more layer.
- **The cost, stated:** a binding over a JavaScript library cannot be published as a library.
  Shared bindings are vendored, below.
- **Bindings are vendored, never depended on** (*decided 2026-10-04 by the owner*). JavaScript in
  a build is beni's — the shipped platforms — or the project's own; a published platform layer
  that projects build on would be a library allowed JavaScript, so it is not admitted. A binding is
  published like any package, but adding it COPIES its source — the `.beni` modules and their
  `.js` siblings — into the project's platform (`./platform/`), recording where it came from and
  its content hash. From then on it is the project's code, reviewed and edited like any other, and
  under rule 9 because the project's platform is; an update is an explicit diff the project takes
  or leaves, never a version bump. shadcn/ui distributes React components this way. The command's
  name and the provenance record's format are the specification's, before code.

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
package may not. *Amended 2026-10-02 (research 48 decision 10):* core is such a package (§2), and
the owner chose this mark — not a `foreign` — for `Ref.update` and `Ref.modify`'s function
parameter, so that their read and write cannot be split by another fiber; `transparent-effects-proposal.md`
§17.2 says what the mark promises there. Nothing in the check changes.

*Amended 2026-10-12, ownership words* ([`ownership-checker.md`](ownership-checker.md) §24; thesis Change
5(a), the owner's decision of 2026-10-12). **A `foreign` may say what a call does with the lists it is
handed and what it returns** — `pub foreign pure from : returned a → Value`, `pub foreign impure array :
aliased elements → fresh Value`, `pub crossing foreign type Event` — with the vocabulary of
`ownership-checker.md` §24.2: a parameter `unused`, `borrowed`, `aliased`, `returned`, `escaped` or
`consumed`, a function-typed one `once` or `many` and `owned`, a result `fresh` (`exclusive`), `escaped` or
`unknown`. The words are part of the declaration's contract, like the rung and `sync`, and the same kind of
promise: about the sibling, checked by no reading of the JavaScript, and trusted — a wrong word is a
correctness bug in privileged code, which is why each annotated declaration is listed with a test program
that pins it (`ownership-checker.md` §24.6). The four checks below do not read them; lowering erases them,
so the type, the interface, the arity check 4 counts and the emitted code are what they are without them.
**What carries no words is taken at its worst**: a `foreign` with none escapes every argument and returns
anything (the thesis's row), whatever its rung. The same words may stand on an ordinary declaration's
signature in a package that may write `foreign` — core's functions over `Js`, such as `String.join`, are
`foreign` in all but form — and on no declaration of any other package (`misplaced_ownership_word`): the
owner did not approve them for application code (Change 5(b)), whose ownership the checker reads from the
body.

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
   review, not a check. `Debug.log` is the one deliberate violation, as it is in Elm. *(Amended
   2026-10-02: `Debug` is beni over `Js` now, with no sibling, so the violation is no longer a
   `foreign`'s: `log`'s type is still pure and it still writes to the console, and its body's
   `Js.call` makes it inferred `impure`, so no optimiser drops it.)*
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

*Amended 2026-10-15 (the owner: `List` is a plain array; `backend.md` §4, *The representation: a plain
array*; built by `browser-direct.md`'s S7).* There are two forms, plain and view, and no trie. `$plain()` is
withdrawn. A sibling reads a plain list in place, and a view as `xs.$b[xs.$o + i]` for
`0 ≤ i < xs.length`; `xs.$b.slice(xs.$o)` gives it an array of its own. The idiom becomes
`Array.isArray(xs) ? xs : xs.$b` from offset `Array.isArray(xs) ? 0 : xs.$o`. `$b` and `$o` are the
protocol's two names, and only a view has them, so `Debug.toString` recognises a list by
`Array.isArray(v) || v.$b !== undefined`. On an in-place platform, beni may later write in place a
list it handed a sibling. So a sibling that **keeps** a list past the call must say so in its
signature's ownership words (`ownership-checker.md` §24), or the checker would take it as
`borrowed`. A sibling still never writes a list it was given.

*Amended 2026-10-15 again (the owner; `ownership-checker.md` §30):* "on an in-place platform"
now means every platform. Every list a sibling is handed may later be written in place by the
program, once nothing the checker sees still reads it. So the paragraph above holds for the
siblings of `node`, `html`, `browser`, `browser-tea` and the test platforms as it does for
`browser-direct`'s. Concretely:

- A sibling that keeps a list past the call writes no word that says it does not. A `foreign`
  with no words escapes every argument (`ownership-checker.md` §24.5), which is the safe reading.
- A sibling that returns a list returns a fresh array (`fresh`) or a list it was given
  (`returned`), as below.
- A sibling never writes a list, whatever its words say.

A word that claims less than the sibling does is a correctness bug in privileged code, as it was
for `browser-direct`. Every worded declaration is pinned by `trusted-surface.txt` and
`word-bodies.txt` (`ownership-checker.md` §24.6).

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

**Amended 2026-10-22: field spellings may be reused.** One source field text
has one spelling everywhere. Different texts that can coexist in one runtime
record have different spellings; fields whose full set is unknown conflict
with every other text. Release assignment greedily colours these sets by uses
(descending), then text, choosing the lowest available spelling. Boundary-pinned
and plain-property field texts keep their source names, no spelling equals a
kept text or contains `$`, and the library and development rules below remain.
This changes the single global namespace in backend §9, not what a host may
read or which records it may construct.

*Added 2026-10-01, with `backend.md` §9's* Item 4, taken up. A `--release` build renames record
fields and gives constructors integer tags wherever no JavaScript can see the difference, so
"where can JavaScript see it" is now part of this contract. **JavaScript sees the representation
of exactly the types a `foreign` annotation names, and of the type a `Js.from` or `Js.to` is
used at** — written records, named types and their bodies, transitively. Those keep their source
field names and string tags in every build, and a type of one constructor with one field keeps
its object, where elsewhere a release build represents it by its field (*amended 2026-10-02*;
`backend.md` §9, *A type of one constructor with one field is its field*).

*Amended 2026-10-14 (inert foreign reachability):* absence of tag construction
is not permission to forget a differently typed result. A foreign can convert
between nominal types with matching representations by returning its argument,
so its annotation constructors remain reachable for nominal result casts
unless the whole returned parameter
has the same declared constructor-bearing type structure. This includes returned callbacks and nested nominal
fields in a result record. Unclassified code anywhere in the same sibling
retains the types its module annotations expose. Backend §9's forwarding proof changes reachability,
not these boundary representations: visible tags still use `$` and source strings
in release; record fields carry no constructor tag.

**Types a shape reads keep their names** *(added 2026-10-19, the owner's decision;
`schema.md` §6, *A validator run is a shape that one shared validator reads*)*. A shape
names a record's fields by text, and its one generic reader copies a validated host object into
a fresh record by those names, so every field of every record a live shape reads keeps its source
name in every build: the record types of the shape's definition, of every definition it reaches
through references, and of each variant's payload, transitively. They are pinned by text as the
fields above are (`Fields`), so a field of that name keeps its name wherever the program names
it. What JavaScript may read of these values is unchanged: the reader writes them, nothing
outside beni reads them.

**Amended 2026-10-22 (the owner's decision): shape-read records get release field
names.** This supersedes the 2026-10-19 requirement that records read by shapes
keep their source field names. A shape produces an internal beni record, as a
validator worker does, and alone pins no field. Each record entry names the
field it writes using the existing deterministic whole-program field assignment
(`assignFields`), the same spelling every other use of the field gets.
Slot 0 stays the host key. Slot 3 uses the existing `[key, shape, flag, name]`
format: `["cups", shape]` can become `["cups", shape, 0, "z"]` in release.
When the written name equals the host key, no name is added. Development
entries and fields independently pinned by a real host boundary keep their
existing format, including any `as "…"` output name. Optional fields retain
flag 1, derived `Maybe` fields flag 2. This includes nested records, tagged
payloads, references and Json codec shapes.

The 2026-10-19 copy design stays: one shared copy loop, no `make` arrow, and
a fresh object. Its four protections are unchanged: getters are read once,
later host writes cannot change the record, no extra or inherited keys are
copied, and beni's writes never land in the host object. Only the written name
changes. T remains 29; [#655](https://github.com/canassa/beni/issues/655) tracks
re-measuring the crossover with short names.

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

*Amended 2026-10-20 (the owner's decision D2, in its safe form; issue #488):* **the release
optimiser relies on nothing of `Js.to`'s contract.** "The caller answers for the type" stays what
it was, a duty of the core or platform code that writes the `Js.to`, and a wrong one may still
mistype a value. It may not also make a `--release` build drop a flow the types did not
predict. Fact 3's declared-type filter (`backend.md` §9, *Declared-type filtering of fact 3*)
treats as wild every type that crosses the wall here: every type a `Js.from` or a `Js.to` is
instantiated at and every type a live `foreign` names, transitively, as unboxing's boundary set
already is, and every type a `Js.from` reaches through a type variable, followed through the
callers that instantiate it. A value a `Js.to` yields is therefore either one JavaScript made,
which the optimiser already treats as unknown, or one that went in at a `Js.from` and is wild. This
changes nothing that privileged code may write or must check.

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

**`suspending : sync (() -> a) -> a`** (suspends, 2026-10-02, `plans/core-in-beni.md` step 2;
**decided** by the owner the same day) is the body's value, and the opposite promise to `pure`'s:
that the value may be the fiber runtime's sentinel, so a call of it may suspend. It is how
`core/Task.beni` parks a fiber — its `park` sets the pending suspension and returns the sentinel
through it — and it is the one way beni code acquires the `suspends` rung without calling
something that already has it. The argument is `sync`: what computes the value cannot itself
suspend. Unchecked, like every `Js` declaration: a body that returns an ordinary value through it
costs its callers a comparison and nothing else, and only `Task` holds the sentinel. Written with a
lambda, it is the lambda's body (`backend.md` §4, *`Js.suspending` is its body*).

**The operators core's arithmetic is written over** (2026-10-01): `bitOr`, `bitXor`, `shiftLeft`,
`shiftRight`, `shiftRightZero` and `rem` — `|`, `^`, `<<`, `>>`, `>>>` and `%` on two `Int`s, as
`bitAnd` is `&` — and `typeOf : Value -> Value` and `instanceOf : Value, Value -> Bool`, `typeof v`
and `v instanceof C`. Each is written in place as its operator. `rem` answers `NaN` for a zero
divisor and `shiftRightZero` an unsigned number, both of which an `Int` may not hold: the caller
guards, as `Int32.rem` does.

**`fingerprint : k, order → name where k.compare : k, k → order`** (pure, 2026-10-02, the owner's
decision on keys, §9.8.3) is **the identity of `k`'s type**: a string the compiler writes at the
call, naming the type with its module, its package and every argument, equal at two calls exactly
when the two types are one (`static-dispatch-spike.md` §8.6). `name` is a `String` and `order` an
`Order`, each a type variable because this module names no core type: the second argument is any
`Order` — `Js.fingerprint k EQ` — and only says what `compare` answers, since a `where` clause may
name no variable its type does not. Both arguments are evaluated for what they do and their values
are not read. Where `k` is a type variable of the enclosing declaration, the
string is built from that declaration's own hidden identity parameter, which its callers supply in
turn — inferred, never written. It is the one way beni code learns which type a value has, and it
exists for `Hosted.key`; written in place, the sibling `core/Js.js` answers it only as a value
(`backend.md` §4, *`Js.fingerprint` is its type's identity*).

**`typeIs : Value, name -> bool`** (pure, 2026-10-02, `plans/core-in-beni.md`; **decided** — the
owner confirmed it the same day) is `typeof v ===
"name"`, the name a string literal written in place: `Js.typeIs v "string"` is `typeof v ===
"string"`. It is `same (typeOf v) …` with the string the comparison needs written by the backend,
which is what lets a module below `String` ask it: `Basics`' `append` asks whether a value is a
string (its `eq` asked whether one is an object too, until `eq` dispatched like `==`,
`static-dispatch-spike.md` §3.1, amended the same day), and a `"string"` handed to `Js.from` would
be a `String` `Basics` may not hold (rule 2 below). The name is not checked against `typeof`'s eight answers;
one that is none of them is a test that is never true, as the JavaScript is. A name that is not a
string literal is refused (`internal`), as a non-literal argument list is.

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
   argument of `regExp`, the type name of `typeIs` (*amended 2026-10-02*), and a list literal that
   is the argument list of `call`, `apply`, `construct` or `array` — *amended 2026-10-02:* or the
   field list of `object`, with its pairs and their key strings (below). The backend writes each as JavaScript syntax — a property name, a
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

**`object : fields → Value`** (pure, 2026-10-02, the owner's decision on research 50 §7) is an
object literal: `Js.object [ ( "k1", v1 ), ( "k2", v2 ) ]` is `{k1: v1, k2: v2}`. The argument is a
list literal of pair literals written in place, each key a string literal that is a JavaScript
identifier (`$` and `_` allowed, `__proto__` not — in a literal it sets the prototype rather than
making a field), no key twice; anything else is **`invalid_js_object`**, at the call, from the
checker. The keys are written in the order given and are **never sorted and never renamed in any
build** — they are property names, which §9's passes never touch — so every object one call makes
has one shape, which is what a hand-written header literal gave V8 (`backend.md` §4, *`Js.object`
is an object literal*). The values are evaluated in written order, each of any type of its own (a
fresh variable, as `Js.from`'s argument is). The list, its pairs and its keys are in-place literals
(rule 2 below): they mint no `List`, `String` or tuple edge, so a module below `String` may write
one. `pure`: making an object changes nothing an observer can see. Passed as a value, `Js.js`'s
`object` builds the same object from a list of pairs. Its first use is `core/List`'s view and trie
headers, whose `$plain` and `length` a reader of a list relies on by name (`backend.md` §4, *What a
reader of a list may rely on*). *Amended 2026-10-15:* with the trie withdrawn, its use there is the view header
`{ $b, $o, length }` alone (`backend.md` §4, *The representation: a plain array*).

**`method : sync (Value → a) → Value`** (pure, 2026-10-02, the owner's decision on research 50 §7)
is a function JavaScript calls as a method: `Js.method λself → body` is `function () { const self
= this; body }`, so `o.m()` hands `o` to the lambda as `self`. It is written with a lambda in place
— anything else is refused (`internal`), as a non-literal argument list is — and is printed as a
`function` expression, never an arrow, whose `this` is not the receiver's, and always with a block
body; it takes no argument but its receiver. `sync`: JavaScript calls it and waits for nothing, so
a body that may suspend is `sync_boundary`. `pure`: making a function changes nothing. *(Amended 2026-10-15: with `$plain()` withdrawn,
`core/List` no longer uses it (`backend.md` §4, *The representation: a plain array*). S7 decides
whether `Js` keeps it.)* Its one use
is a field of a `Js.object` that a reader calls by name — a list header's `$plain`, which the
protocol makes a field and not a prototype method (`backend.md` §4, *What a reader of a list may
rely on*) — and the optimiser keeps every object holding one whole, since the method reads and
writes it through a receiver the optimiser cannot name (`backend.md` §4, *`Js.method` is a
`function`*). Passed as a value, `Js.js`'s `method f` is `function () { return f(this) }`.

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

*Amended 2026-10-20:* "not a compiler change" held for every platform until the fifth, `cloudflare`
(§9.12), whose host finds a Durable Object class by the entry module's export names: that needed
one general output key, `"exports"` (§5.2), and nothing else.

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

**Whether the platform edits lists in place is part of that shape, and it is `"lists"`** (*added
2026-10-13*, [`ownership-checker.md`](ownership-checker.md) §28.2). `"lists": "in-place"` says that the
code the chain emits may write a list's array where the ownership checker accepted the edit, so
`check` and `build` run the checker on every program built for it, and every edit it cannot prove
safe is an error; no other value is accepted, and a chain that does not say it edits nothing in place
and runs no checker at all. Inherited first-found down the chain like every field (§9.1).
`browser-direct` declares it; no other platform the binary carries does.

*Withdrawn 2026-10-15 (the owner: "no 'fallbacks', i want a proper implementation. this is no
longer a platform decision, it's core to beni"; [`ownership-checker.md`](ownership-checker.md)
§30).* Every platform edits lists in place, and the ownership checker runs in every `check` and
`build`, so a platform has nothing to declare. `"lists"` is no longer read. A manifest that still
writes it has an unknown key, which is ignored like any other (§5.2's forward-compatibility rule),
and `browser-direct`'s manifest drops it. What a platform does owe instead:

- **ownership words** on every `foreign` that takes or returns a list or a function (§4,
  amended the same day);
- **the word `entry`** on the record parameter of each program constructor whose functions the
  runtime calls (`ownership-checker.md` §30.3);
- **the direct row's obligations** that its runtime keeps: P1–P4 and P7, in
  `ownership-checker.md` §30.3 and `backend.md` §15.5's amendment of 2026-10-15.

**The entry file's named exports are part of that shape, and it is `"exports"`** (*added
2026-10-20*, §9.12 (c)). A platform whose host finds code by the entry module's export names — a
Durable Object class, under Cloudflare Workers — declares `"exports": "program"`: the entry file
then takes what `run(main)` returns, writes its `default` as the default export, and writes one
named export per name the app's `beni.json` lists under `"exports"` (`frontend.md` §10.1), each the
answer of the result's `exports(name)`. The platform declares the mechanism and the app the names,
as the app replaces the chain's `"html"` with its own. Any other string, or a list, under the
platform's key is `unknown_exports_mode`, and a value of another JSON type is the manifest's exit-2
failure, as any key of the wrong type is; a name that is not an ASCII identifier name (letters,
digits, `_` and `$`), is `default`, is `flush` or is listed twice is `invalid_entry_export`, both
against the manifest that holds them at `1:1` (*amended 2026-10-21, P599-1, P599-3 and P599-5:
`flush`, `$` and the wrong type; a reserved word is legal, §9.12 (c)*);
a list on a chain that declares no `"exports"` is the warning `exports_ignored`. A chain that
does not declare it reads no list, and `run`'s result is not read, as before. §9.12 (c) has the
contract whole.

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

Cmd.run    : (⊤ → a), (a → msg) → Cmd msg               -- fire and forget
Cmd.keyed  : k, Policy, (⊤ → a), (a → msg) → Cmd msg    -- k equatable
Cmd.cancel : k → Cmd msg
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
        Typed q       → ( { model | q = q }, Cmd.keyed "search" Restart (λ⊤ → search q) GotHits )
        NavigatedAway → ( model, Cmd.cancel "search" )
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
| `html` | — | the HTML vocabulary, and since 2026-10-12 the SVG one in the same module (§9.9): elements, attributes, events, the markup primitives `text` and `map`, the markup type `Html msg` (§9.3), and in its Zig the HTML parser's table (§9.5). No `program` and no lowering; it is only depended on |
| `browser` | `html` | DOM capabilities, a low-level `Program` and its runtime, the `dom` lowering; re-exports `Html` |
| `browser-tea` | `browser` | The Elm Architecture in beni over `browser`'s `Program`; re-exports `Html` and `browser`'s modules |
| `node` | `html` | today's Node platform, plus the `ssr` lowering, so a `view` renders to a string under Node and `tests/corpus/run/` can test it (research 36 §5.5); re-exports `Html` |

*Amended 2026-10-20:* a fifth platform ships, `cloudflare` (§9.12), which depends on no platform and
declares no markup.

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
*Amended 2026-10-21.* The `foreign` need not be `pub`. Visibility is about names (`language.md`
§5). A program cannot call the extractor, and the event can. The vocabulary row stores the
name. A build that reaches the event imports that name, or writes it in the vocabulary module
itself, and the vocabulary module exports the declaration, as it exports a core-private value.
The runtime's `identity` stays the extractor of an event with no `via`.

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

*Amended 2026-10-12* (§9.9 (d)): the table also knows SVG's foreign content — inside an `<svg>`, short
of its HTML integration points, none of HTML's rules apply, and an element whose declared namespace the
parser would not give it where it stands is `markup_restructured`. Which namespace an element is declared
in is the vocabulary's fact, handed to the table by the lowering.

*Amended 2026-10-20* (§9.8.20 (d)): **every lowering calls a `via` extractor synchronously, while
the event is dispatched; for an event that is not `delegated`, in the listener of the element that
has the handler, so that `currentTarget` is that element.** A `delegated` event's extractor can run
in a listener higher up — under `dom`, the document's (`backend.md` §15.3, *Events*), where
`onInput`'s and `onChange`'s `targetValue` and `onCheck`'s `targetChecked` run — so it must not read
`currentTarget`. An extractor may read what is true only during the dispatch — the pointer events'
reads `currentTarget` and its box — so a lowering that queues an event and extracts later breaks it
(issue #559).

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
| `cx.fresh(hint) Name` | a local name `$<hint>$<n>`, unique in the top-level declaration being lowered; a hint that would print as a positional name (`m`, `in`, `l` and digits) is refused. *Amended 2026-10-15:* was "unique in the module" (`backend.md` §4, *A compiler-made name is numbered within its top-level declaration*, and *A `$` in front of every compiler-made name*) |
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
- **Skip on a list's identity** (*added 2026-10-15*, the owner's decision that every platform
  edits lists in place, `ownership-checker.md` §30). Every skip above that compares a value with
  `===` is allowed only for a value whose type is not a list. That includes a type a release build
  represents by a list. A list that is `===` the last one may have been written in place since
  then. A lowering's runtime keeps no list from one render to the next, and compares none by
  identity (`backend.md` §15.5, amended the same day). This binds every platform's lowering
  (`dom`, `ssr`, `direct`, a third party's) and every runtime module.
- **Skip on a record's identity** (*added 2026-10-17*, the owner's decision that a record update
  consumes its base on every platform, `ownership-checker.md` §31). The rule above holds for every
  value whose type may hold a record: a record, and a tuple, constructor or closure that may hold
  one. A record that is `===` the last one may have been written in place since then. A runtime may
  keep such a value, but it concludes nothing from its identity and never reads it expecting the
  contents it had (`backend.md` §15.5, amended the same day). A skip by `===` stays allowed only for
  a value whose type holds no record and no list.

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

**`stop`, the page's unmount** *(amended 2026-10-17, `browser-inline`'s first slice; W51)*. A
program runtime may export **`stop`**, of one parameter (it takes `⊤`), beside `run`, `start` and
`flush`, and the compiler holds it to the same checks. When the runtime declares it and the build
reaches it, the entry file exports it as `stop` from the module the page loads, exactly as it
exports `flush` (`backend.md` §15.11): `export { … as stop }`. A page — a test driver, an
embedding page, the research adapter's `dispose` — calls it to unmount the program, and it does
three things, in this order:

1. it sets the page's dead flag, so no send made after the call — a listener's, a timer's, a
   command body's, the page's own — runs program code;
2. it runs every disposer the program's mount registered, once each, the last registered first:
   each listener the program added is removed, each timer it started is cleared, and the
   program's root node is removed from the document;
3. nothing else: it runs no program code, renders nothing and is not a `catch` (`CLAUDE.md`
   rule 9).

A second call does nothing, nor does a call before the mount has run. A call after a defect
stopped the page still runs the disposers that had not run, so a page the defect left inert
also gives its listeners and timers back. A call made while a dispatch runs — only page code can
make one, from inside a handler it wrapped — lets the running function finish and drops what was
queued behind it. **One per page**: a platform with `stop` mounts one program per page
(`browser-inline` has no `Browser.programs`), so the export needs no argument naming a program.
The name is tea-inline's (`../reactivity-research/frameworks/tea-inline/template/adapter.js`). A
runtime that declares no `stop` builds exactly as before.

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

**Version 1.5** (*amended 2026-10-04*, additive and gated on nothing; research 56 §6.2, Fix B, the
owner's decision): **a root may carry its inputs, and the lowering compute its values by what they
read.** For a root of kind `expression`:

- **`Root.inputs`**, values of the root that each read one **local** of the enclosing declaration
  whole — every local any of the root's values reads, bound outside the root, in first-use order;
  and **`Root.reads`**, values that each read one **path** through one of those locals (the local
  itself, or a chain of field accesses and tuple indices through it, at most four links), every
  path any value reads, distinct, in first-use order. Both evaluate nothing and may be asked for
  wherever the root's values may.
- **`tree.readsOf(v)`**, per value of the root — the instruction values, and the slots of its rows'
  captures, inputs and selector probes, its helper calls and class lists — the positions in
  `Root.reads` of the paths it reads. The analysis is `language.md` §11.9's for a row's inputs,
  applied to every value: a use of a local that is a field access or a tuple index is that path;
  a use as an argument of a top-level function of the same module reads what that function's
  summary says it reads of the parameter, iterated to a fixpoint; every other use — an argument of
  another module's function or of a local function, a `case`, a record, a list, a call of the local
  itself — reads the whole local. A value whose paths are all `===` to what they were when it was
  last evaluated has the same value, because it reads nothing else that can change: beni has no
  mutation, a top-level value never changes, and a local function is itself a local.
- **`tree.everyRender(v)`**, per value, whether a render must evaluate it every time: it may have
  an effect other than `Debug`'s — a call, outside any function the value makes, whose callee may
  be `impure` or suspend (`transparent-effects-proposal.md` §16.2's `impure` answer) and is not
  one of `Debug`'s. A grouped root evaluates such a value on every render. Markup nested in a
  value — a root inside it, a helper's or a component's markup — is no reason to evaluate it
  again (*amended after the second review*): a lowering that skips a value keeps what the value
  showed current itself, as `dom` does by restating the slot (`backend.md` §15.4).
- **`tree.pathOf(v)`**, per value, the position in `Root.reads` of the path the value is exactly —
  a local of the enclosing declaration read through at most four field or tuple accesses and
  nothing more — or null: such a value changed exactly when that path did.
- **`Component.impure`**: the component's call may have an effect other than `Debug`'s; a lowering
  never skips it. For it and for a helper call's `everyRender`, a call is impure when the checker
  says its callee may be, except that a call of `Debug`'s is not, and neither is a call of a
  function of the same module whose body has no effect but `Debug`'s (asked once per function; a
  cycle is taken to be impure). Another module's function, and a function reached through a value,
  are taken at the checker's word.
- **`Lowering.groups`**: a lowering that sets it may be handed roots whose values the compiler has
  **not** evaluated where the root stands. **`cx.grouped(root)`** says whether this root is one:
  true when the lowering sets `groups` and the compiler can evaluate the root's values outside the
  enclosing function — the enclosing declaration takes no evidence, its own or a `let`
  function's (`static-dispatch-spike.md` §8.1), may not suspend, has no suspendable body and is
  not being lowered in the suspendable form (`transparent-effects-proposal.md` §16.2), and no
  value holds a `?` (which returns from the enclosing function). The answer is the same for every
  root of a declaration, since one is lowered inside another. For such a root, a lowering evaluates the values
  itself, inside its own functions, by **`cx.bindInputs(root, names)`** — every input's local read
  under the name given, until **`cx.unbindInputs(root)`**, nested innermost first — and
  **`cx.rootValues(block, root, values)`**, which evaluates the instruction values among `values`
  into `block`, in the root's order. What the root evaluates to where it stands may then read only
  `Root.inputs`. A lowering may evaluate a value of such a root zero times in a render, and must
  evaluate it in a render in which one of its paths is not `===` to what it was at the value's last
  evaluation, and at the first (`language.md` §11.11, as amended 2026-10-04). *A known cliff:* the
  declaration's own answer covers everything it calls, so a `view` that calls a function value it
  does not know — `model.render x`, a function in a field — may suspend as far as the checker can
  tell, and none of its roots is grouped; they are lowered as before §15.4's amendment.

**A `let` read only by the root** (*the same day*, research 56 §6.2's `let` rule): **`Root.lets`**,
values of a grouped root that each are one `let` of the enclosing declaration — a constant one,
`shown = top model.items`, bound outside the root, whose every use in the declaration is inside the
root's values or inside another such `let`'s expression, and whose expression holds no `?`, has no
effect but `Debug`'s — in source order. Only a root inside no other root's
value takes `let`s, and **a `let` is one root's at most**: when two roots could take it, the root
first in instruction order does, which is the innermost (a root inside another's `let` comes before
it). Which `let`s a root takes is decided in one pass from the last `let` to the first, since a
`let` reads only earlier ones: linear in the declaration.
The compiler does not evaluate such a `let` where it is written: it is a value of the root, read
through its own paths (`tree.readsOf` of a `Root.lets` value), and a value that uses it reads what
the `let` reads instead of the `let` itself; it is never one of `Root.inputs`.
**`cx.bindLet(root, k, name)`** makes the `k`-th `let`'s local read under `name` until
`cx.unbindInputs(root)`, and `cx.rootValues` evaluates a `Root.lets` value as it does an
instruction value. A lowering must evaluate a `let` before any value that uses it in a render that
evaluates both, and must give a value that uses it the `let`'s value as last evaluated.

A root `cx.grouped` answers false for is lowered exactly as before. `ssr` does not set `groups`;
`dom` targets 1.5 (`backend.md` §15.3, *A root computes its own values*).

**Version 1.6** (*amended 2026-10-09*, additive and gated on nothing; `browser-direct.md` §11.1,
slice S0): **the program hook** — a lowering may compile a whole program of The Elm Architecture
where its constructor is called, rather than its markup one root at a time. A lowering that sets
none of the four fields below is handed exactly what 1.5 hands it. S0 builds what a program whose
`view` is static markup needs; `browser-direct.md` §11.1's other calls (`cx.arm`, `cx.writes`,
`cx.reads`, `cx.conflicts`, `cx.site`, `cx.carriers`, `cx.literal`) are added by the slices that
consume them, each as a minor version of its own.

- **`Lowering.programs`**, the program constructors the lowering compiles whole, each a `foreign`
  of its platform named by module and value (`Tea.sandbox`). The compiler finds **every call** of
  one in a surviving declaration before any declaration is lowered. A use of one that is not the
  callee of a call — `List.map apps Tea.sandbox` — makes programs whose `view`s are known only at
  run time, and is **`view_not_compiled`** at the use. An entry may carry **`refused`**, a message:
  every use of that value is then `not_implemented` with it, and the hook never sees it — how a
  lowering turns away another architecture's constructor its runtime cannot run (`browser-direct`
  refuses `Browser.program` and `Browser.hosted`).
- **`Lowering.program(cx, tree, program) Expr`**, called where each call stands, **instead of
  evaluating the call's argument**. It returns the program's **mount**, and the call is compiled as
  the constructor applied to it — so the constructor's own JavaScript makes the platform's
  `Program` value of the mount (for `browser-direct`, `[{ a: mount, n: null }]`, the shape
  `Browser.mountAt` and `Browser.programs` already rewrite). The record is never evaluated as a
  value; what the lowering needs of it, it asks for. **`Program`** describes the call as the
  compiler found it (`write-sets.md` §1.1's shape): `constructor`, its index in `programs`;
  `record`, whether the argument is a record literal written at the call; and for `view` and
  `update` a **`Shape`** — `markup` (a top-level function of this module, or a lambda written in
  the record, whose body is markup written in place; `view_root` is then that root of this module's
  tree), `function` (one whose body is anything else), `other_module`, or `computed` (a call, a
  local, a value). A module that calls a constructor and writes no markup of its own is handed an
  empty tree; `module` is not run for it.
- **`cx.programInit(block) Expr`** (*amended 2026-10-12, §9.8.16: what it evaluates is `init ⊤`; a
  lambda of `⊤` in the record is lowered as its body, any other function is called, and on every
  platform `init` now runs at mount*): the program's `init`, evaluated into `block` and bound to a
  name that `--release` keeps when `init` may have an effect (`backend.md` §9's rule for any such
  binding), and that name. At most once per program. So `init` is evaluated where the lowering
  places it — for `browser-direct`, inside the mount, which runs inside the dispatch guard — and
  nowhere else. **`init` therefore runs when the program mounts, not when its program value is
  built**: a `Debug.log` in it prints at mount, and a throw in it is a defect of the mount, where
  a platform that builds the record as a value (`browser-tea`) evaluates it where `main` is
  evaluated. An `init` that may suspend is refused (`not_implemented`), since a mount cannot
  wait; the checker's `must_not_suspend` at `main` already refuses every such program written
  today.
- **`cx.programReport(part, code, message)`** reports `not_implemented` or `view_not_compiled` at
  the call, its `init`, its `update` or its `view`; **`cx.notImplemented(node, message)`** reports
  `not_implemented` at a markup node. Both are the lowering's way to refuse a program it does not
  compile *yet*, naming what will compile it — a diagnostic, never a silent miscompile. §9.4.7's
  "the one code a lowering may raise" now reads: `markup_restructured`, and these two.
- **What the hook consumes is not emitted.** A `view` or `update` that is a function of the
  calling module, not `pub`, not the entry, named by no method, and named by nothing in a surviving
  declaration but program records, is not written: the hook compiled what it needed of it. Its
  callees survive reachability as before (`backend.md` §9 is unchanged), which over-approximates
  and is sound. A `view` that is `pub` or named elsewhere is written as the function it is, and
  its markup is a value (below).
- **`Lowering.no_markup_values`**, a message: the lowering has no run-time value of the markup
  type. A markup root lowered anywhere but as a program's `view_root`, and every use of a markup
  primitive, is then `not_implemented` with that message, and the markup runtime is **not held to
  the vocabulary's primitives** (§9.4.5's union leaves them out): nothing can call one.
- **`Lowering.placements`**, the values that place programs on a page (`Browser.programs`, its
  list; `Browser.mountAt`, its first argument). A lowering lists them when one program value
  mounted twice would share one state: the compiler walks `main`'s placements — through the
  top-level values of its module that hold placements — and a top-level program value named twice
  among what they place is **`program_mounted_twice`** at the second (`browser-direct.md` §8.2).
  A program value only the run time can see twice (a local) is the runtime's to refuse.

The host-access rule of §9.4.4 gains one pair of writes for a lowering whose mount the runtime
hands a node and a `template` element (`browser-direct`'s `run`): the mount writes the template
element's `innerHTML` and appends its `content` to the node. Both objects are the runtime's grants;
the lowering names no host global. `direct` targets 1.6 (`browser-direct.md`, *As built, S0*).

**Version 1.7** (*amended 2026-10-09*, additive and gated on nothing; `browser-direct.md` §4, §5,
§8.3, slice S1): the calls a program lowering compiles a program's messages and holes with. A
lowering that calls none of them is handed what 1.6 hands it. They are valid inside
`Lowering.program` only, and read what the write-set pass (`write-sets.md`) found of the program
being compiled: in a build whose lowering names a program hook, the compiler runs the pass once,
before any module is lowered, over every call of a program constructor in an application module
(not only `main`'s), and the lowerings read its result while they run in parallel.

- **`cx.programKeys() []const Program.Key`**: the program's leaf message keys (`write-sets.md`
  §4.4) in the dump's order — a key's named children before its default one. Each has its `name`
  (the dump's, for a handler's name), `params` — the handler's parameters: the constructor's
  fields for a key that is one named constructor, one (the message itself) for any other — and
  `star`, a key whose write set is `value ρ`. A program the pass does not recognise has one key,
  `*`.
- **`cx.programHole(ref) Program.HoleFacts`**, for a text hole (`.node`) or an attribute
  (`.item`, its index in `Tree.items`) of the `view` root: `group`, its anchored read set as a
  number (equal sets, equal numbers); `static`, no key's write set conflicts with it (§2.5, with
  tag reads); `bake`, for a static hole `write-sets.md` §9.1 bakes, the text the template holds
  verbatim; `where`, its source position. A hole the pass did not see has a group no number
  equals, called by every key.
- **`cx.programCalls(key, group) bool`**: whether `key`'s write set conflicts with read set
  `group`.
- **`cx.programUpdate(block) ?Expr`**: `update` as a function value, evaluated once into `block`,
  when an arm calls it — an `update` of another module, or computed (`withLogging update`) — and
  null when every arm is written in place, in which case `update` is not emitted.
- **`cx.programArm(key, block, params, model, update) Expr`**: key `key`'s arm, its statements
  into `block`, the payload read from `params` and the old model from `model`; returns the new
  model. Where `update` is a function of the calling module or a lambda in the record, its body is
  written in place: when it is a `case` on its message parameter, only the branch the key's first
  step selects, with that constructor's fields bound to the parameters (or read from the one
  parameter, for a deeper key whose own `case` then decides); otherwise the whole body with the
  message bound. Otherwise it is `update(message, model)`.
- **`cx.programViewEnter(block, model)` / `cx.programViewLeave()`**: `view`'s parameter bound to
  `model`, so that `cx.rootValues` evaluates the root's values against it — the root's inputs
  bound as `cx.bindInputs` binds them, in the context of `view`'s own declaration.
- **`cx.programMessage(block, value, payload) Program.Message`**: inside `programViewEnter`, what
  an event's handler value sends — `.key` with a handler's arguments when the value is a
  constructor (applied, or given the payload) whose key a handler has, read when the event fires;
  `.value`, a message value, otherwise.
- **`cx.programDispatch(block, msg, handlers)`**: the dispatcher's body — each key's constructor
  tests along its steps, in key order, and `handlers[k]` called with what it takes; the last key
  untested.
- **`cx.reachesDebug(value) bool`**: whether evaluating a value may call `Debug`, directly or
  through any function it calls, transitively over every module (the development verify mode's
  skip, `browser-direct.md` §8.3). Always true where the build has no such table (`--release`).
- **`Build.fuzz`**: the hidden `--fuzz` flag (`browser-direct.md` §8.3, as amended for S1).

A program built under `--fuzz` also keeps every `case` arm on any constructor, built or not
(`backend.md` §9's dead arms), since a fuzzer sends messages the program never makes, and under
`--release` its message types keep their development representation (`browser-direct.md` §8.3's
contract). `direct` targets 1.7.

**Version 1.8** (*amended 2026-10-09*, additive and gated on nothing; `browser-direct.md` §6,
slice S2): what a program lowering compiles a `For`'s rows with. Valid inside `Lowering.program`
only, as 1.7's calls are.

- **`cx.programList(node) Program.ListFacts`**, for a `For` node of the program's `view`:
  `exact`, its `each` is exactly a path of the model or of an enclosing row's item
  (`browser-direct.md` §6.2); `baked`, the number of rows K3 writes into the template (§6's S2
  amendment), or null.
- **`cx.programEdits(key, node) []const Program.Edit`**: what key `key`'s write set does to that
  `For`'s rows, as edits, each under the enclosing `For`s' rows it is in (`outer`, outermost
  first: one `Program.Index` per enclosing `For`). An edit is a **shape** — the list's edit tag
  (`set`, `append`, `prepend`, `clear`, `insert`, `remove_at`, `swap`, `all` for `kept [*]`,
  `remove_some`, `permute`, `replaced`) and its index symbols — or **rows**: the row groups
  (`HoleFacts.group` numbers) to call on the rows at one index, or on every row, and whether the
  key may change there (`rekey`). The read a row group is called for is `write-sets.md`'s
  *bound* read (its 2026-10-09 amendment for S2): at one index for a read of the row's own
  item, on every row otherwise.
- **`cx.programIndex(key, block, params, model, index) ?Expr`**: an index symbol of key `key`'s
  edits, as an expression of the handler's `params` and the old model `model` — a path read,
  so nothing goes into `block`; null when the handler cannot evaluate it (`?`, every row, or a
  path through a constructor the key does not fix). A lowering evaluates it before `programArm`.
- **`cx.rowValuesOf(block, row, item, index, values)`**: `rowValues` for the named values only,
  as `rootValues` is for a root: the row's item and position bound, its `let`s evaluated, and
  only `values` (each a value of the row's root) after them, in the root's order. An empty
  `values` binds the item and evaluates the `let`s, so a nested row's values that read an
  enclosing row's item read it under the name given.
- **`cx.programRowBake(hole, row) ?[]const u8`**: for a hole of a `For` row that K3 bakes, the
  text the template holds for row `row`, verbatim (escaping is the lowering's), or null.

`direct` targets 1.8.

**Version 1.9** (*amended 2026-10-10*, additive and gated on nothing; `browser-direct.md`'s S3
amendment): what a program lowering writes helpers, components and `Html.map` in place with, and
two more facts of an edit. Valid inside `Lowering.program` only.

- **`Program.Edit.rows`** gains `changed`, a visit of every row whose item changed only (an
  element write at `[*]` of reads bound to the row: the identity walk), never merged with a visit
  of every row; and `selector`, a visit of every row that every read making it is the row's
  selector input's path (`Row.selector`), so the rows keyed by the old and the new probe are all
  it needs.
- **`cx.programCallee(node) ?Program.Callee`**, for an `html` hole or a component node of markup
  the program writes: whether the lowering may write what it calls in place, and what. A
  `Callee` is the markup root written in place — the body of a function of the calling module,
  after its `let`s, or the markup an `Html.map` is applied to — reached through `maps` `Html.map`s
  (outermost first), whether every map's function is a constructor's shape (`composed`), and why
  not where it may not (`refusal`: a function that calls itself on the current path, a component
  with children written between its tags, markup of another module, or any other value). Null:
  the node is not a call.
- **`cx.programInlineArgs(block, node) []const Expr`**: the call's arguments (a component's
  props as one record), evaluated into `block` in the current context — `programViewEnter`'s, a
  row's, or an enclosing call's.
- **`cx.programInlineEnter(block, node, args, made)` / `cx.programInlineLeave()`**: from here to
  the matching leave, the callee's markup root's values are evaluated with its parameters bound to
  `args` (null: the facts below only, nothing bound), in the callee's declaration; with `made`, its
  body's `let`s that its markup does not read are evaluated into `block` first — where the call's
  markup is made. While entered, `programHole`, `programList`, `programEdits` and
  `programRowBake` answer for that call's copy of the callee's holes (`write-sets.md`, *a hole's
  facts per call*), and `programMessage` reads a handler value through to the argument a
  parameter is bound to, and composes it under the call's maps — `.key` when the composed
  message's key is decided at compile time, with the fields of a one-constructor key or the
  composed message for a nested one.

`direct` targets 1.9.

**Version 1.10** (*amended 2026-10-13*, additive and gated on nothing; `browser-direct.md`'s S4
amendment, as built for its value path and controlled inputs, then for its branches and derived
values): the calls a program lowering compiles branches, `Show` and a `view`'s `let`s with,
valid inside `Lowering.program` only, one field of `Program`, one change to what a program
lowering's hook leaves unwritten, and one to `rootValues`.

- **`cx.programBranch(node) ?Program.Branch`**, for an `html` hole of markup the program
  writes: when its value, its `let`s peeled, is an `if` or a `case` — a branch, which
  `browser-direct.md`'s S4 amendment (item 3) compiles in place — rather than markup on the value
  path (item 1), its arms in order, an arm whose body is itself a `case` replaced by that
  `case`'s arms (`else if`). Each `Program.Arm` says what its result is past the arm's `let`s —
  `markup` (a root written in place), `call` (a function of this module whose body after its
  `let`s is markup, under no `Html.map`: the callee's root) or `value` (anything else) — whether
  no value takes it (`dead`: a constructor nothing builds) and whether it has `let`s its result
  does not need (`statements`). Null for any other node. *(Built for item 3, 2026-10-13: this
  entry first said `bool`.)*
- **`cx.programBranchArm(block, node) Expr`**: the number of the arm the branch's value takes
  now — its scrutinee, the decision and the `let`s around it evaluated into `block` where the
  hole's root's values may be, the arms' own `let`s not.
- **`cx.programBranchEnter(block, node, k, made, held) ?Expr`**, left with
  `programInlineLeave`: arm `k` entered. Without a block, only the facts change: `programHole`,
  `programList`, `programEdits` answer for the arm's holes, on the call path the pass walked them
  by (the hole's token added). With one, the hole's value is evaluated into `block` again — the
  scrutinee and the decision up to the arm — with the arm's result made the array of what binds
  its values: the inputs of its markup root, then read under names of their own, or the
  arguments of its call, then bound to the callee's parameters as a call written in place is
  (1.9); with `made`, the arm's `let`s its result does not need run too. It returns that array,
  which a lowering may keep and hand back as `held`: when `held` is not `null` at run time it
  binds them instead and the value is not evaluated — an arm its branch tore down, whose
  variables the value no longer gives.
- **`cx.programBranchValue(block, node, k) Expr`**: arm `k`'s result evaluated into `block` as a
  markup value, where the branch's value takes that arm.
- **`cx.programShowFallback(node) ?Root.Index`**: the markup root a `Show`'s fallback is, when it
  is markup written there whose values can be evaluated apart; and **`cx.programNestedEnter(r)`**,
  left with `programInlineLeave`: the inputs of root `r`, markup nested in a value of the root
  being evaluated, read under the names their locals have there.
- **`Program.view_lets`**: `view` is a function whose body is `let`s around markup written in
  place; `Program.view_root` then names that markup's root, and `view` stays `.function`, so a
  lowering before 1.10 sees what it saw. The `let`s the root takes are its own (`Root.lets`);
  `cx.programViewEnter` evaluates the others but the statements, and
  **`cx.programViewStatements(block) bool`**, inside it, evaluates those — a `let_stmt`, a `_ =` —
  where the page is made, and says whether there were any.
- **`cx.programLet(r, k) Program.HoleFacts`**: the read set of root `r`'s `k`-th `let`, on the
  current call path, numbered as a hole's (`programCalls`): what a derived value is computed
  again for (`browser-direct.md` §5.4). The write-set pass records it for every constant `let`
  the view walk evaluates, once per call path (`write-sets.md` §3.6, as amended for S4).
- **`cx.rootValues` binds a `let` it evaluates.** A `let` of root `r` among `values`
  (`Root.lets`) is read under the name its value was bound to by the values evaluated after it,
  until `r`'s inputs are unbound, as `cx.bindLet` binds one — when `r` is the root whose inputs
  were bound last. Before, a lowering that evaluated a root's `let`s through `rootValues` and
  bound none read an unbound name (`browser/direct/HelperLet`: a helper written in place whose
  markup reads its own `let`).
- **A consumed declaration the hook's code names is written after all.** Version 1.9's rule
  leaves a markup helper that only consumed declarations name unwritten, since the hook writes
  each of its calls in place. A program lowering that puts markup on the value path calls such
  a helper instead (`List.map xs row`, a helper that calls itself, an `Html.map` of one), so a
  consumed declaration whose name the code a lowering wrote asks for is lowered after the
  module's other declarations, in its place, and whatever it names in turn.

With `Lowering.no_markup_values` left unset, a program lowering is handed markup roots that are
values (`Lowering.root`) as any lowering is, and its markup runtime is held to the vocabulary's
primitives (§9.4.5). `direct` targets 1.10, and no longer sets `no_markup_values`.

*Amended 2026-10-13 (S4's review; `browser-direct.md`, *slice S4, review fixes, programs, defects
and the SVG root, as built*)*, additive within 1.10:

- **`cx.programBranchChoose(block, node) Expr`**: the branch's value evaluated **once** — the
  scrutinee, the decision and the taken arm's `let`s but those that are statements — as an array
  `[j, …]`: the arm taken, then what binds that arm's values (its markup root's inputs, or its
  call's arguments), or, for an arm that is a value (`Arm.What.value`), that markup value. A
  lowering keeps it, so nothing of the hole's value runs twice for one choice of arm.
- **`cx.programBranchBind(block, node, k, from, made)`**, left with `programInlineLeave`: arm `k`
  entered as `programBranchEnter` enters it, its locals bound from `from` — what
  `programBranchChoose` returned when it took arm `k` — and nothing evaluated again; with `made`, a
  call arm's callee's `let`s its markup does not read run too.
- **`cx.programBranchStatements(block, node, k)`**: arm `k`'s `let`s that are statements, where its
  markup is made (`browser-direct.md` §8.4) — the hole's value evaluated for them, the arm's other
  `let`s left out but those a statement reads; nothing runs when the value takes another arm.
  `programBranchArm`, `programBranchValue` and `programBranchEnter` with a block stay, unused by
  `direct`.
- **`Program.view_branch`**: `view` is a function whose body past its `let`s is an `if` or a
  `case`. The branch has no markup node: `programBranch` and the calls above take
  `Node.Index.none` for it, `programBranchEnter`/`Bind` extend no call path for it (the pass walked
  its arms on the root's), and `programViewEnter` binds `view`'s parameter and `let`s with no root.
  A `let` of such a `view` that may have an effect is refused (`not_implemented`), as one a root
  does not take is.
- **`Program.Branch.debug`, `.effect`**: whether evaluating the branch's value may call `Debug`,
  or may have another effect — what a branch with no hole value answers in place of
  `reachesDebug` and `Tree.everyRender`.
- **`Program.Callee.debug`**: a component's function may call `Debug`, directly or through what it
  calls — what a verify mode asks before it makes a component's markup again. `true` when not
  known and for a hole's call. `cx.reachesDebug` now also follows the function of each component
  in markup a value makes.

**Version 1.11** (*amended 2026-10-14*, additive, gated on nothing): the compiled
host contract in `browser-direct.md`'s effects amendment. `programStart(block, args)` evaluates
init once with the supplied arguments; `programInit` keeps its unit form. `programField(block,
field, model)` evaluates `subscriptions`, `onUrlRequest`, `onUrlChange` or the document `title`
against the supplied model in the record's declaration context. `programSettles(key)` reports
whether subscription reads conflict with that key's writes, conservatively true for unknown
reads. Effectful init/arm results are their declared model/command pair. Document view shape
facts describe its record's body, which is compiled without a runtime view call.

**Version 1.12** (*amended 2026-10-14*, additive): `Program.document_branch`
marks a document view whose body returns a helper-computed document directly
or from a branch. `programBranchChoose` keeps the complete taken document
at index 1; body and title share it. The view itself is compiled in place,
and helper-returned markup uses the existing value path. See browser-direct.md's
dated document-helper amendment.

**Version 1.13** (*amended 2026-10-15*, additive): parameterised templates
retain their call's analysis context across function/module boundaries.
`templatePlan()` supplies the program's hole identities, call paths and
per-key conflicts; `templateHoles(refs)` supplies a template group's source
identities independently of its callers. `templateCapture(root)` captures the
current substitution path with the template's inputs. `templateScope(active)`
scopes code generation of an outlined template (returning the previous state),
so a reusable body never bakes in the first caller's path. The platform owns
the resulting template instances and runtime protocol; the engine owns source
identity and analysis facts. `templateValue(node, expression, placement)` either retains a producer call's source path or scopes its placement mask. The lowering opts in with `parameterised_templates`;
the engine then emits backend.md's `_direct-plan.json` consumer plan. browser-direct.md and write-sets.md's amendment
of the same date own selection and verification.

**Version 1.14** (*amended 2026-10-17*, additive, gated on nothing; `browser-inline.md`): what a
program lowering needs to compile a program's effects and its placement away.
- `Lowering.constructs`: a program constructor's call is compiled as the mount alone, for a
  platform whose `Program` is the mount.
- `Program.Code.program_shape`: a `programReport` refusal by a language rule (`browser-inline.md` §5, class 3), reported as the `program_shape` code, whose title says no "yet".
- `Lowering.places`: a call of a `first` placement whose first argument is a program constructor's
  call and whose second a string literal is compiled as the program call alone, and the hook is
  handed where the program mounts, `Program.placed`: at that element, at `document.body` when the
  call is `main`'s whole body, or `unknown`.
- `Lowering.effects` names the platform chain's `Sub` and `Cmd` modules. The write-set pass then
  reads the subscription set and each key's command, and `init`'s, through their `none`, `batch`,
  `map`, `on` and `perform`, walking the platform's other functions outside `view` as it walks the
  program's own (`browser-inline.md` §3–§4). `programSubscriptions()` answers the set: its
  declarations — each one's handler key, its fields, the first declaration of an equal key, and
  where its start is written — or that it reads the model, that a tagger gives no key, or that the
  pass could not read it. `programSubscriptionStart(block, i, send)` writes declaration `i`'s start
  applied to `send` and returns what removes it, or reports a limit of the compiler for a start it
  cannot write there. `programCommand(key)` (`null`: `init`'s) answers `none`, `runs`, `suspends`
  with the body's place, or `unknown`, the suspension the checker's answer at the body.
A lowering that sets neither sees what it saw.

**Version 1.15** (*amended 2026-10-17*, additive, gated on nothing; `browser-inline.md` §8): what a
program lowering needs to write each key's arm and another module's markup in place of a message
and a renderer. It lands across the pull requests of `browser-inline`'s S1, each member with the
one that first uses it; a lowering that targets 1.14 sees what it saw.
- **Helper argument evaluation reads** (*added 2026-10-21*, #476/#615).
  `Program.HoleFacts.entry_groups` is an empty-by-default slice of read-group numbers for
  a helper call's argument expressions that are not proven pure and total. These are
  evaluation reads, separate from the callee's demanded leaf reads: forwarding a pure
  model reference does not subscribe to all its fields. A lowering adds these groups
  to the binding that evaluates the call. Guarded preparation includes the same
  argument reads in its selector/visibility and descendant bindings so a selected
  argument is evaluated before any of that preparation's DOM writes. Hidden arms
  remain unevaluated. This is transient lowering metadata, with no cache-format change.
- **Eager branches.** `Program.Arm.eager`: the arm is markup written in place that reads no
  variable the branch binds and no `let` of the arm, so its values can be evaluated whichever arm
  the value takes. `programBranchEager(block, node, k)` enters arm `k` of branch `node` so: its
  markup root's inputs are read under the names their locals have at the hole, nothing of the
  hole's value is evaluated, and the facts (`programHole`) answer on the arm's call path, as
  `programBranchEnter` does. Leave with `programInlineLeave`.
- **A language rule at a node.** `programShape(node, message)` reports `program_shape` at a markup
  node, as `programReport(.., .program_shape, ..)` does at a part of the program's call.
- **Keys.** `Program.Key.fields`: the leaf constructor's arity for every key whose last step names
  a constructor, however deep — the parameters of a handler called with the leaf's fields and no
  message; `params` keeps its 1.7 meaning (one, the message, for a nested key), which
  `browser-direct`'s dispatcher reads. `Program.Key.refusal` — `none`, `opaque_update`,
  `message_read_whole`, `deep_split`, `cap` — says what keeps the key's arm from being written of
  pieces, or (`message_read_whole`) that the handler builds the message; `Program.Key.cap` names
  the cap of the write-set pass that cut the key's writes. `Program.Key.star_kind` says which of
  three a `*` key is: lost precision (a cap cut it, or the pass marked its whole write an
  approximation, `write-sets.md` amended 2026-10-18), an exact inferred whole write of a model
  whose type is a record of several fields, or a model of one value written exactly
  (`browser-inline.md` §5). `Program.Key.lost`, for a `*` key of lost precision, is where the pass
  lost it — the first approximation in source order, its kind (an opaque call, a call of a
  function-valued parameter, of a function a local holds, a record of a type it cannot read), its
  place and text and how many more — and `programReportAt(site, code, message)` reports there, in
  whichever module holds it. `Program.Key.spelled` is the key as the program spells it, its
  constructors, never `(any)`; `Program.Key.cap` names the first cap that cut the key.
- **Arms from fields.** `Lowering.arm_fields`: the lowering's handlers take each key's leaf
  fields. `programMessageFields(block, handler, payload)` is `programMessage` handing a key those
  fields, through constructors of one constructor's type that no `case` splits as well as through
  the steps (`CounterMsg Counter.Inc` gives the `Inc` key none). `programArmFields(key, block,
  fields, model, update)` writes the key's arm from them: `update` in place whatever its shape
  (its body is never copied whole, only the branches the key takes), a local that would hold the
  message or a part of it followed by how far along the leaf's path it is, a function of the
  module that hands it on written in place, a call of another module's function that module's arm
  piece (`browser-inline.md` §8.4), and a read of a part whole built there (D-e). What it cannot
  follow is a limit of the compiler, reported once at the expression it stopped at.
- **Groups, sparse.** `programGroupsOf(key)`: the groups the key's writes reach, sorted — what
  `programCalls` answers one pair at a time, without the groups × keys matrix.
- **Per-path passes.** `programArmTails(key)`: the tails of the key's arm (`write-sets.md`,
  amended 2026-10-17), each with the groups its writes reach; `programCallsAt(key, tail, group)`;
  and `programArmPaths(key, block, params, model, update, tails)`, which writes the arm with the
  model assigned and the lowering's block `tails[t]` placed at each tail `t`.
- **Pieces** (*as built 2026-10-18*). `Lowering.piece`, a hook `piece(cx, tree, request)` run in
  the module that owns a markup root another module's program shows, with `PieceRequest`: the
  root, its declaration's name and ordinal, and `facts` with the arena to write them in. Inside it
  the program's facts answer on the root's call path; `pieceArity` and `pieceViewEnter(block,
  args)` enter the root's function with its parameters bound; `pieceEventCtor(handler, payload)`
  reads an event's handler value as a constructor and its fields; `pieceExport(base, init)`
  writes an exported constant `<Module>$<base>`. `PieceFacts` is `written` and the lowering's
  own record, opaque to the compiler. At the program site, `programPiece(node)` gives an `html`
  hole's facts when the hole is another module's root (or reports why it cannot be, and facts not
  written); `programPieceName(node, base)` imports a piece; `programPieceArgs(block, node)`
  evaluates the call's arguments; `programPieceKey(node, ctor)` names the key a constructor of
  the root's message reaches through the maps, and `programPieceMessage` makes the message below a
  key whose leaf is a map's constructor. The owner is lowered before the program site
  (`browser-inline.md` §8.4, amended 2026-10-18).

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
  one way a lowering could break rule 5 (research 28 §9.3). *Amended 2026-10-15:* `cx.fresh`'s
  counter restarts at 1 for each top-level declaration of the module (`backend.md` §4). The emit workers call it for several
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

*Amended 2026-10-12 (§9.8.16):* `init` is a function the platform calls once per mount — `init :
⊤ → ( model, Cmd msg )` — on every program constructor, and `Storage`, `Http` and `Log` gain the
commands `save`, `send` and `write`, which take the value they store, send or log. *(Amended
2026-10-21: since the browser's `Log` moved into core, the log's command is `Cmd.log`, in `Cmd`;
§9.8.16 (b).)*

`Tea.sandbox` stays `Browser.program`, and a page built on it reaches no byte of `Task` (R45 §7).

#### 9.8.2 The command API and the four policies

```elm
pub type alias Send msg = msg → ⊤
pub type Policy = Restart | Ignore | Queue | Concurrent

pub none : Cmd msg
pub batch : List (Cmd msg) → Cmd msg
pub perform : (Send msg → ⊤) → Cmd msg                        -- a fiber in the program's scope
pub keyed : k, Policy, (Send msg → ⊤) → Cmd msg               where k.compare : k, k → Order
pub cancel : k → Cmd msg                                         where k.compare : k, k → Order
pub cancelAll : Cmd msg                                           -- every keyed body at this path and below
pub map : Cmd a, k, (a → msg) → Cmd msg                         where k.compare : k, k → Order
pub afterRender : (Send msg → ⊤) → Cmd msg                     -- §9.8.6
pub task : (⊤ → a), (a → msg) → Cmd msg                       -- perform λsend -> send (tag (work ()))
pub do : (⊤ → ⊤) → Cmd msg                                    -- perform λ_ -> work ()
pub log : Log.Level, String → Cmd msg                         -- perform λ_ -> Log.log level line (2026-10-20, §9.8.16 (b))
```

*Amended 2026-10-12 (§9.8.16 (b)):* beside these, `Storage.save`, `Http.send` and `Cmd.log` (`Log.write` until 2026-10-20) are
commands that take the value they store, send or log; every constructor above stays, and §9.8.16 (c)
says why each that takes a function does.

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

*Amended 2026-10-02 (`static-dispatch-spike.md` §3.5, the audit of what `==` compares).* **"Built
alike" is about values, not storage.** A `List` is a plain array, a view or a trie (`backend.md` §4,
*Lists are arrays*), and the walk compared those forms' fields, so `[ 1, 2 ]` written as a literal
and the same two numbers as a pattern's `rest` were two keys, and a `Restart` keyed by one let a
body keyed by the other finish (a silent wrong answer). The walk now reads a list in any form as its
elements (`$plain()`, the one fact a reader outside `core/List.js` may use besides `length` and
`Array.isArray`); `browser/tea/ListKeyRestart` pins it. *Amended 2026-10-15:* once
`browser-direct.md`'s S7 lands there is no trie and no `$plain()`, and the walk reads a view through
`$b`/`$o` (`backend.md` §4, *The representation: a plain array*). **One case is still open, and is the same
fingerprint's:** a key whose type compares by its own `compare` rather than by its representation —
a `Dict` or a `Set` (a tree whose shape depends on insertion order), or a program's type with a
hand-written `compare` — is matched by what it stores, so two equal sets built in different orders
are two keys. The key's evidence is the type's own order, but evidence is built afresh at each call
and says nothing of which type it orders, so it cannot be applied to two keys without knowing they
are of one type; with a fingerprint, keys of one type would be ordered by their evidence. Until
then, key a command or a subscription by a value whose type derives its `compare` from canonical
parts (numbers, strings, tuples, records, custom types, lists of them).

*Amended 2026-10-02 (the owner's decision): **a key carries its type's identity, and keys of one
type are ordered by that type's own `compare`.*** This closes both holes above, and replaces the
reflective walk.

- **What a key holds.** `Hosted.key k` is three things: the **identity** of `k`'s type — a string
  the compiler writes at each call, naming the whole type with its arguments
  (`static-dispatch-spike.md` §8.6) — the type's `compare` (the `where` clause's evidence, the
  declaring module's own `pub compare` or the derived one, exactly what `<` on `k` calls), and the
  value. `Hosted.compare` orders two keys **by identity first, then by the evidence of the first
  key applied to the two values**. Two keys of one identity are of one type, so either key's
  evidence orders both.
- **What it guarantees.** Two keys are one key exactly when they are of one type and that type's
  `compare` says `EQ`, including two different values of a program's type with a hand-written
  `compare` that calls them equal; `Alpha.Key 1` and `Beta.Key 1`, and
  `Id User` and `Id Post` over one `Int`, are two. `tests/corpus/browser/tea/ValueKeyRestart` and
  `browser/tea/TypedKeys` pin both, for commands and for subscriptions. The rule of thumb above,
  and the requirement that a library key `Sub.listen` by a type of its own, are withdrawn as
  obligations; keying by a type the library declares is still how it keeps its keys apart from a
  program's.
- **Nothing changes in user code.** `Cmd.keyed`, `Cmd.cancel`, `Cmd.map`, `Sub.listen` and every
  keyed API keep `where k.compare : k, k → Order`; the identity is a hidden argument the compiler
  infers and supplies, never written (`static-dispatch-spike.md` §8.6). A program's function that
  is generic over a key and calls one of them — `restart key name = Cmd.keyed key Cmd.Restart …`,
  annotated with `where k.compare` or not — is handed the identity by its own callers the same
  way. A key type that mentions a type variable its declaration has no requirement on is refused
  with `type_identity_unknown` (§8.6).
- **The order of keys changed for keys of one type**: it is that type's `compare`, so a derived
  one orders constructors by declaration and records by field name, the same in a development and
  a release build (renamed fields and integer tags reach neither the identity nor the evidence).
  `browser/tea/KeyOrder` starts `Zeta` before `Alpha` now, by `Lane`'s declaration order, where
  the walk compared the tags' text. Keys of two types are ordered by their identities' text.
- **The cost.** A program that keys nothing is byte for byte what it was. A keyed call passes one
  string literal more, and a declaration generic over a key one parameter more.

*Amended 2026-10-22 (#294, the owner's decision):* Dict and Set no longer
have `compare`, and neither is a valid command or subscription key. The earlier
examples of equal dictionaries or sets as keys are withdrawn. Passing one to
`Hosted.key`, `Cmd.keyed`, `Cmd.cancel`, `Cmd.map`, `Sub.listen`, or another API
requiring its `compare` is a type error. Its message must explain that **Dict
and Set have no compare because insertion order is part of their value**;
an unexplained missing-method error is insufficient. This also applies when
comparison of an enclosing tuple, list, record or custom type would require
a Dict or Set comparison. A program's explicit comparator on its own type
remains its own policy; it must not request a missing collection comparator.

Tea's tables do not encode these keys as Int or String, and do not store
`Hosted.Key` in Dict. W47's type identity and per-type comparison remain the
contract. The private ordered table specified below preserves them.

**Tea's private ordered tables — added 2026-10-22 (#294, the owner's
decision).** Tea stores jobs and live subscription tables in its own private
sorted array of `(key, value)` pairs. A live or wanted subscription uses
`Hosted.Key`; a jobs entry uses a `List Hosted.Key` path. A binary search finds
the lower bound using `Hosted.compare`, or lexicographic path comparison with
`Hosted.compare` on each segment (a proper prefix sorts first). A matching
entry is exactly a comparison result of `EQ`, including distinct values that
a type's own comparator calls equal. Search must not use JavaScript identity,
string encoding, hashing by representation, or Dict's scalar-key index.

Insertion replaces the value at an equal key, retaining its position and key,
or inserts at the lower bound. Removal closes the gap. Iteration is in sorted
key order, preserving command and subscription lifecycle ordering. These
are internal platform operations, with no new public API. Empty tables are
constructed afresh for each program or diff. The table uses owned array operations; every accepted write edits in place,
and a write ownership cannot prove safe is a compile error. There is no
persistent or copying fallback and no ownership exemption for the table.
Callbacks and subscription bodies retain their existing effect contracts.

All paths with a given prefix form one contiguous range: `cancelAll` finds
its beginning by lower-bound search, scans to the first nonmatching prefix,
cancels those jobs in path order, and removes that range. It does not partition
an insertion-ordered Dict. Subscription lookup, replacement and the live /
wanted diff use the same sorted-table comparison rule. The existing keyed
browser fixtures, including `TupleKeyRestart`, `ListKeyRestart`
and `TypedKeys`, continue unchanged. `ValueKeyRestart` retains its program-type
comparison coverage; its direct Dict and Set key cases become refusal fixtures
under the restriction above. A fixture with two distinct values whose own
`compare` returns `EQ` pins matching for commands and subscriptions.

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

*(Amended 2026-10-17, for `browser-inline` (`browser-inline.md`), which has no fiber kernel and
writes the page synchronously.)* On that platform the program is not a scope and nothing is
spawned, and the contract above reads as follows. A dispatch is one entry into the dispatch
guard. The handler of the message's key runs its arm, which writes the model; then each binding
the key's write set names runs once — the set deduplicated at compile time — and writes the page
if its value changed. That is the **write pass**: one per dispatch, inside the guard, at the end
of the arm, never one per field written and never on a microtask, so `settled` has nothing to
wait for. **A command that cannot suspend runs after the write pass, in the same dispatch**: the
handler appends the command's body to the guard's queue (rule 2's), behind any send already
queued there, and the guard runs it before the dispatch ends. A body that sends while it runs
puts that message on the same queue, so the message is applied after the body returns, in this
dispatch, never re-entrantly; a body that sends nothing ends the dispatch. Rule 4 holds in this
form: the page that shows the message's model is written before any body of that message runs.
`Cmd.none` writes nothing at all, not even an empty call. A command that may suspend is refused
when the program is built, with `browser-inline.md` §5's text. Two events in one task are two
dispatches, each with its own write pass: nothing coalesces them.

#### 9.8.5 Subscriptions (W48)

```elm
pub type Sub msg
pub none : Sub msg
pub batch : List (Sub msg) → Sub msg
pub map : Sub a, (a → msg) → Sub msg
pub listen : k, (Send a → ⊤), (a → msg) → Sub msg          where k.compare : k, k → Order
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

*Amended 2026-10-02 (the owner's decision): **a subscription whose body only listens runs without
a fiber.*** §9.8.11 (b) took commands that cannot wait off fibers; a subscription's body never
could be, because every `each…` direct form parks between events, so one `onUrlChange` reached the
whole fiber kernel — 2 905 of TodoMVC's 9 895 bytes (research 51 §0.2). Now a subscription is one
of two kinds, chosen by the function that makes it:

```elm
pub listen : k, (Send a → ⊤), (a → msg) → Sub msg                   where k.compare : k, k → Order
pub on : k, sync (sync (a → ⊤) → (⊤ → ⊤)), (a → msg) → Sub msg    where k.compare : k, k → Order
```

- **`Sub.listen key body tag`** is unchanged: one fiber runs `body` while `key` is in the set. A
  body that really waits — `Time.every`'s timer loop, a request — is written this way.
- **`Sub.on key start tag`** is a **listener**: `start send` adds the host's listener, which calls
  `send` with a value as each event is dispatched, and returns what removes it. While `key` is in
  the set the listener is added once; it is removed when the key leaves. **No fiber, no `bracket`
  and no park per event.** `start` and the `send` it is handed are `sync`. Every subscription of
  `browser` that only listens is now one — `Browser.Events`' five, `Browser.Navigation`'s
  `onUrlChange` and `onUrlRequest` — over `Listen.on target name read send` (one event name) and
  `Listen.on2` (two, one listener, so one never overtakes the other).
- **The direct forms are derived from the same listener**: `Listen.each start f` adds it when the
  calling fiber starts the call, queues each value it sends until the fiber takes it, calls `f`
  with each in order, and removes it however the call ends — what `Listen.each` did, now over any
  listener. `eachKeyDown f = Listen.each (keys "keydown" _) f` and `onKeyDown tag = Sub.on KeyDown
  (keys "keydown" _) tag`, so the two cannot drift (§9.8.11 (a)).

**The two kinds are indistinguishable to a program**: the listener is run so that every message
lands exactly where a fiber running `Listen.each start send` would have sent it. That is the rule,
and each point below follows from it.

1. **Where it starts.** A fiber spawned by the diff first runs when the scheduler's drain reaches
   it, and only then adds its listener. A listener is added by core's `Task.soon` work queued by the
   diff at that same place (§9.8.11 (b)): an event dispatched between the render that settled the
   set and that turn — by after-render work, say — reaches neither.
2. **Where each value lands.** A parked fiber that is handed a value is queued at the back of the
   ready queue and sends it when the drain reaches it; values that arrive before it runs, or while
   its `send` dispatches, are queued and sent in the same turn, in order, before it parks again. The
   listener does the same with `Task.soon`: the first value queues one delivery at the back of the
   ready queue; values that arrive before it runs, or while it runs, join it; the delivery sends
   them all, in order, and the next value queues a new one. So a message from a listener keeps its
   place among commands' bodies, fibers' resumptions and other subscriptions — a body that pushes
   an address and then sends `Pushed` still has `Pushed` applied before the `UrlChanged` its push
   announced, as before — and the drain's budget of 64 counts a delivery as it counted the
   resumption. A value is read as its event is dispatched in both, so what it carried is never read
   late (and `Browser.Events.onResize` no longer coalesces: every resize is a message with the size
   it fired at, as Elm's is).
3. **Leaving the set.** The relay is closed at once, in the render that saw the key leave (as
   before), so nothing the listener sent and nothing it sends later reaches `update`; and **the
   listener is removed at once**, in that render — a fiber's was removed when the fiber that
   cancels it ran. A key that leaves before its listener was added (both in one task) never adds
   it. Nothing a program can observe differs: a closed relay already dropped every value.
4. **A throw.** `start`, the remover, the `read` and the tagger run as the fiber's would have — the
   first in `soon` work, the second in the diff (the program's `settle`), the third in the host's
   listener, the last in the delivery — and each of those is a guard of §9.8.10 (c), so a throw in
   any of them is a defect by the same path, and nothing catches it (`CLAUDE.md` rule 9). A
   throw out of a host listener is the host's report, as a fiber-path `read`'s was.
5. **A defect's teardown** (§9.8.14). A listener is held by no fiber, so no sweep reaches it.
   Core's **`Task.onShutdown : sync (() → ()) → ()`** registers a function `shutdown` calls once, in
   a microtask queued at the stop — so after the throw has left the guard's cleanup for the host,
   as §9.8.14 (b) requires of anything that can throw, and before the teardown's sweep — and
   `Hosted` registers one, on the first listener it adds, that removes every listener still added.
   A microtask, not the teardown's macrotask: removing a listener runs no program code and waits
   for nothing, so it has no reason to wait for the host's next task. So after a defect every
   listener is gone (`DefectReleasesHost`'s `listeners` steps read 0, as before). *(Amended
   2026-10-02: `macrotask` keeps a queue, not one slot. Two macrotasks were already pending at
   once — a stop posts the teardown and the drain it interrupted posts itself after it — and in a
   browser, where the escape is a `MessageChannel`, the second overwrote the first: the teardown
   never ran and the second message called nothing. `run/MacrotasksPendingTogether`. The queue
   is one array; the release output became 12 bytes smaller.)*

**The architecture.** `Sub`'s list carries `Key × Hosted.Kind × Tap msg`, `type Kind = Waits |
Hears` — the tap built by `Hosted.tap body tag` or `Hosted.hook start tag` — and `Tea`'s live set
keeps `{ relay, stop }` per key, `stop` what the key's leaving runs; the first declaration of a key
decides its kind. Every step that spawns or cancels a fiber is in the `Waits` arm, so a program
whose subscriptions all listen reaches no fiber through them (`backend.md` §9, *A `case` arm on a
constructor nothing builds*). `Hosted.hear relay` runs a listener as 1–3 say, `Hosted.unhear`
closes its relay and removes it; `Hosted.runHeard relay` runs the same listener under
`Listen.each` in a fiber.

**The proof is the existing pages, run both ways.** A development build carries a test hook: when
the page's `globalThis.__beniFiberSubscriptions` is `true` before the program loads, `Tea` runs
every listener subscription in a fiber through `Hosted.runHeard` — the way every subscription ran
before this amendment. A release build has no hook (`Js.development`). The corpus runs every
`browser/` fixture whose development build carries the hook a third time with it set (the driver's
`--fiber-page`), against the same golden, so every subscription page — `WindowEvents`,
`KeyEvents`, `KeyOrder`, `KeySubscription`, `LatestTagger`, `Router`, `NavigatePush`,
`LinkGuard`, `UrlAddress`, `ApiAndRoutes`, `TodoMVC`, the `Defect…` pages and the rest — shows one
transcript under both paths, and their goldens did not change. `browser/tea/ListenerOrder` pins
point 2 against commands and fibers, point 1 against after-render work, and point 3's same-task
arrival and departure (the driver's `flush` takes several selectors, each clicked and flushed in
one task); each of the three fails against a listener that adds itself or sends at once, or that
starts after its key left.

*As built* (`platforms/browser/`: `Listen.beni`, `Hosted.beni`, `Hosted.js`, `Sub.beni`,
`Browser/Events.beni`, `Browser/Navigation.beni`; `platforms/browser-tea/Tea.beni`;
`core/Task.beni`'s `onShutdown`; `tests/browser/driver.mjs`'s `--fiber-page`), as specified.
A page whose subscriptions all wait pays a little for the split (`bench/size.mjs`'s `every`, a
`Time.every` alone, +38 brotli: the kind beside each tap and the stopper per key). Measured
(`--release`, brotli 11): TodoMVC **9 895 → 8 316**; `bench/size.mjs`'s `navigation`, `links` and
`application` pages 5 659 / 5 355 / 5 738 → 4 022 / 3 815 / 4 181, and no page that subscribes
to nothing moves.

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
    { init : sync (Host msg → model)
    , update : sync (Host msg, msg, model → model)
    , settle : sync (Host msg, model → model)
    , view : sync (model → Html msg)
    }
    → Program
pub foreign impure flush : ⊤ → ⊤
pub foreign impure onRendered : Resume ⊤ → (⊤ → ⊤)     -- `Dom.rendered` is `Task.callback` over it
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

*Amended 2026-10-02 (§9.8.5's amendment):* `Hosted` gains `hook : sync ((a → ()) → (() → ())),
sync (a → msg) → Tap msg` (`impure`), a listener's tap; `type Kind = Waits | Hears`, which `Sub`'s
list carries beside each key and tap; `hear : Relay msg → ()`, a listener run with no fiber, and
`unhear`, which closes its relay and removes it; and `runHeard`, the same listener in the calling
fiber (`suspends`), for the test hook `fibered`.

*Amended 2026-10-02 (§9.8.3, the type's identity):* `key` is beni, `keyOf (Js.fingerprint k EQ) k`
over a `pure` `foreign keyOf : String, k → Key where k.compare : k, k → Order`, and a `Key`
compares by identity, then by its type's `compare` — no longer "by value".

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
*(Amended 2026-10-12: `onAnimationFrame`, with `onAnimationFrameDelta` and their direct forms, is
§9.8.18's; `Browser.nextFrame` stays owed, for the reason given there.)*
*(Amended 2026-10-20: `Ws` is §9.11's `WebSocket`, on the page and on the `node` server.)*

#### 9.8.9 The rest of the answers

- **W51, unmount**: not now; the root scope and `Task.closeRoot` are what it would call.
- **W52, handles in a model**: §4.1's "never hold a reference across an effect boundary" is amended
  for a handle every operation of which is total on a closed one — each returns a `Result` — and
  which is declared `equatable foreign type`, so a model holding it keeps its derived `==`. None is
  built yet; `Queue` will be the first. *(Amended 2026-10-20: `equatable` is core's alone, so a platform's handle — `WebSocket.Socket`,
  §9.11 — is a `foreign type` whose module gives it a `pub eq`.)*
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

*Amended 2026-10-13:* **the drag-and-drop events** `onDragStart`, `onDragEnd`, `onDragOver` and
`onDrop` join the vocabulary, `delegated` since all four bubble, each handed the `Event`. They are
added as `onMouseMove` was (§9.9 (c)): for a program that needs them and that Elm writes with
`Html.Events.on "dragstart"` and `preventDefaultOn "dragover"` (the port of rvcas/sternhalma,
research 88). A drop target allows the drop by calling `Html.preventDefault` in its `onDragOver`
handler, as Elm's `preventDefaultOn` returns `True`. Nothing reads the drag's `dataTransfer` yet;
the other drag events (`drag`, `dragenter`, `dragleave`) wait for a use, and Elm's general `on`
stays the open question it is.

`Browser.Events` gains **`onKeyDown`, `onKeyUp`, `onKeyPress : (Html.Event -> msg) -> Sub msg`**,
Elm's three, each taking the function a handler would be (`onKeyDown (λevent -> Pressed
(Html.key event))`, Elm's `onKeyDown (Decode.map Pressed (Decode.field "key" Decode.string))`).
Unlike a resize, **no key is coalesced**: each event is queued as it is dispatched until the body's
fiber takes it, in order, and the function reads it there — the properties it reads do not change
after dispatch, and only `preventDefault` would come too late. The queue is `Listen.each : String,
String, sync (Js.Value -> a), Send a -> ()` — the window's or the document's events of one name,
each `read` as it fires — a module of `browser` for its own modules (`Browser.Navigation` uses it
too), not re-exported by `browser-tea`, as `Hosted` is not. Elm's decoder may fail, sending
nothing; a beni function always makes a message, which `update` may ignore. *(Amended 2026-10-02,
§9.8.5's amendment: `Listen` is `on : String, String, sync (Js.Value → a), sync (a → ()) → (() →
())`, the listener itself, with `on2` for two names and `each : sync ((a → ()) → (() → ())), (a →
()) → ()` for the direct forms; the subscriptions run the listener with no fiber, and a resize is
no longer coalesced.)*

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
  *Amended 2026-10-02:* `Url` is now core's, and `fromString` is the host's WHATWG parser, its
  parts normalised as the browser normalises them (§9.8.13 (a), its amendment).
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
*Superseded 2026-10-02 by §9.8.15 (b):* `Log` moves into core with these three signatures and
their output unchanged, and gains levels, annotations, spans, a minimum and sinks
(`transparent-effects-proposal.md` §17.11).

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

*Amended 2026-10-02 (§9.8.5's amendment):* **(c) a subscription that only listens runs without a
fiber**, by the same rule — the listener's values are delivered by `Task.soon` work where a fiber's
resumption would have landed — but chosen by the function that makes it (`Sub.on` against
`Sub.listen`), not by the inferred bit: a listener's `start` returns at once by its shape, so
there is nothing to infer, and every `each…` direct form of the table in (a) is now `Listen.each`
over that listener. §9.8.5's amendment has the rule, the five points that keep the two paths
indistinguishable, and their proof.

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
its slice lands. *Amended 2026-10-02:* the owner confirmed H1–H5 as recommended.

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
pub header : String, String → Header

pub type Body                  -- opaque
pub emptyBody : Body
pub stringBody : String, String → Body          -- the MIME type, then the text
pub jsonBody : Schema e a, a → Body              -- `Schema.print`, sent as application/json
pub multipartBody : List Part → Body
pub type Part                  -- opaque
pub stringPart : String, String → Part           -- the field's name, then its value

pub type Expect x a            -- opaque: how the answer is read
pub expectString : Expect Error String
pub expectJson : Schema e a → Expect Error a
pub expectWhatever : Expect Error ⊤
pub expectStringResponse : (Response String → Result x a) → Expect x a

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
pub fractionSent : { sent : Int, size : Int } → Float
pub fractionReceived : { received : Int, size : Maybe Int } → Float

pub request :
      { method : String
      , headers : List Header
      , url : String
      , body : Body
      , expect : Expect x a
      , timeout : Maybe Duration          -- `Time.Duration`
      , tracker : Maybe (Progress → ⊤)
      }
    → Result x a                                                       -- suspends
pub riskyRequest : <the same record> -> Result x a                      -- suspends
pub get : { url : String, expect : Expect x a } → Result x a           -- suspends
pub post : { url : String, body : Body, expect : Expect x a } → Result x a   -- suspends
```

*Amended 2026-10-15 (`schema.md` §12.10, A.12; issue #193):* `expectJson` takes no schema. It is
`expectJson : Expect Error a where a.codec : ⊤ → Codec a`, whose schema the compiler derives from
the type the request's answer is used at, as `Json.decode`'s is. The schema-taking form above is
renamed `expectSchema : Schema e a → Expect Error a`; what each reads, sends and fails with is
unchanged. `jsonBody` keeps its schema argument.

`get` is `request` with `"GET"`, no headers, `emptyBody`, no timeout and no tracker; `post` the
same with `"POST"` and its body — Elm's two, and there is no `put` or `delete`, as Elm has none:
those are `request` with their method. **The command form** is `Cmd.task`, `Cmd.keyed` and
`Cmd.cancel` over these (§9.8.2), and Elm's `tracker`-and-`cancel` pair is a key:

```elm
update msg model =
    case msg of
        Search q →
            ( model
            , Cmd.keyed SearchKey Cmd.Restart λsend →
                send (Found (Http.get { url = Url.Builder.absolute [ "api", "search" ] [ Url.Builder.string "q" q ], expect = Http.expectJson results }))
            )
        Leave →
            ( model, Cmd.cancel SearchKey )   -- aborts the request: Elm's `Http.cancel "search"`
```

A body that wants progress passes a tracker that sends: `tracker = Just λp -> send (Progressed p)`
— the progress messages and the answer leave one body in order, so there is no `track`
subscription and no tracker string to match.

*Amended 2026-10-14 (§9.8.19):* the direct form keeps its tracker function. The command forms
`Http.send` and `Http.riskySend` take elm/http 2.0's `tracker : Maybe String`, and the subscription
`Http.track` hears it. A body that calls `request` itself still passes a function.

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

*Amended 2026-10-02, as built:* the first two rows are told apart by the request's own signal,
not by the rejection: when `signal.aborted`, the request aborted itself, and it is `Timeout` when
`signal.reason` is its timer's reason and nothing (a cancellation) otherwise, whatever the
rejection is. An engine may reject a body read cut off by an abort with a `TypeError` rather than
the reason — Chrome does for a body that is a stream — and that rejection is the abort's
consequence, not the network's.

*Amended 2026-10-12 (the owner's decision):* **the step a waiting fiber is resumed with names
exactly the failures this table can produce.** `Http`'s private `wait` resumes its fiber, through
`Task.callback`, with a `Step`: the promise's value, a failure, or a defect. Its failure is a type
of its own with one constructor per row that answers — `TimedOut` for the first, `Unreachable` for
the third — and not a `Response String`, of which only `Timeout_` and `NetworkError_` ever travelled
there. Where the answer is read the failure becomes `Timeout_` or `NetworkError_`, so `Response`,
`Error` and every `Expect` see what they saw before: no behaviour, API or output changes. The
reason is rule 9's: a type that admitted any `Response` let a value from JavaScript stand, to the
ownership checker, for a response whose body or `Problem` reaches the program's decoders
(`ownership-checker.md` §24.11 item 1).

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

*As built, 2026-10-02* (`plans/http-and-routing.md`, the request, multipart and progress slices):

- **A header value holding a character above U+00FF is `InvalidHeader` too** (step 3): `Headers`
  holds byte strings and throws a `TypeError` for one, a failure the standard documents, so it is
  found by testing the value like NUL, CR and LF.
- **`get` checks no method or header and `post` only its body**: their method is a standard one and
  they take no headers, so a program that only gets and posts ships none of step 2's and 3's tests.
- **A multipart body's `size`** is the UTF-8 length of its parts' names and values together.
- **A zero or negative timeout sends nothing**: the request is `Timeout` before `fetch` is called.
- **The JSON pieces of (a) and (b)** — `expectJson`, `jsonBody`, `BadBody`, `UnprintableBody` — are
  not built yet: importing `Schema` into `Http` makes every page that uses `Http` check
  `core/Schema`, and that alone puts each `Http` page fixture over the test budget. Reported as the
  defect to fix (rule 10); the slice waits on the branch `http-json-blocked`.

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
  `Cmd.cancel`, and a tracker function that sends. *(Amended 2026-10-14: the command forms `send`
  and `riskySend` take Elm's `tracker` string, and `track` is a subscription, §9.8.19; `cancel`
  is still a key.)*
- **`expectJson` and `jsonBody` take a schema** (`schema.md`), not a `Json.Decode.Decoder` or a
  `Json.Encode.Value`: schemas are beni's JSON story, and one schema reads the answer and writes the
  request. *Amended 2026-10-15 (`schema.md` §6, *A statically known schema runs compiled*;
  A.11):* the signatures stay, and a statically known schema runs compiled through them.
  `X.schema ⊤`, `Schema.list (X.schema ⊤)` and every composition of compiled makers carry their
  compiled parse and print, and `Schema.parse`/`Schema.print` run those. So
  `Http.jsonBody (X.schema ⊤) v` prints with `X`'s encoding worker and ships no library
  interpreter, and so does `Http.expectJson (X.schema ⊤)`. A developer writes the plain call, with
  no `expectStringResponse` helper over `X.parse` and no `stringBody` over `X.print`.
  `Unprintable issues`, which becomes `BadRequest (UnprintableBody issues)`, and `BadBody issues`
  carry the compiled root's issues, which are the issues the library makes. The API was not
  changed to take compiled functions: that would lose `Schema.list X`, which has no `print` of
  its own, and it would give every program two spellings of one request.
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
`plans/http-and-routing.md`. *Amended 2026-10-02:* the owner confirmed H6–H10 as recommended,
H7 with one change, recorded under (a).

**(a) Where `Url` lives** (H7). `Url`, `Url.Parser`, `Url.Parser.Query` and `Url.Builder` are
pure and use nothing of a page, so they are **core modules**: a library, the `node` platform and a
test can parse and build addresses. `browser`'s `Url` (§9.8.10 (b)) moves to `core/Url.beni`
unchanged, and `browser-tea` stops re-exporting it (every program reaches core). Its
`percentEncode` and `percentDecode` are `Js` over `encodeURIComponent`/`decodeURIComponent`, which
every host has.

*Amended 2026-10-02 (the owner, confirming H7):* `Url` moves to core, but **not unchanged**:
**`Url.fromString` wraps the host's WHATWG URL parser** instead of the hand-written port of Elm's
splitter, so beni sees exactly the address the browser navigates to and `fetch` requests — one
parser for the page, the request and the router, never two that disagree.

- It calls `URL.parse(text)`, which answers `null` for text the URL standard does not parse, so
  nothing is caught. On an engine without `URL.parse` (before Chrome 126, Safari 18, Firefox 126,
  Node 22.1) it calls `new URL(text)` inside a `Js.catchIf` that takes only a `TypeError`, the
  standard's one failure (rule 9).
- **Elm's record and its `Nothing` stay**: a parsed URL whose scheme is not `http:` or `https:`
  is `Nothing`, and so is one with a username or password, which the record has no field for and
  `fetch` refuses. A relative text has no base and does not parse: `Nothing`, as in Elm.
- **The parts are the host's, normalised as the URL standard normalises them**, where Elm's
  splitter kept the text as written: the scheme and host lower-cased (and an international host
  in its ASCII, `xn--` form), `.` and `..` path segments resolved, the scheme's default port
  dropped (`http://a:80/` has `port_ = Nothing`), an empty path written `/`, and the characters
  the standard escapes in a path, a query and a fragment percent-encoded (a space is `%20`,
  `ü` is `%C3%BC`). `host` is `hostname` (an IPv6 address in its brackets, which Elm's splitter
  refused), `port_` is `port` as an `Int` or `Nothing`, `path` is `pathname`, and `query` and
  `fragment` are `search` and `hash` without their `?` and `#` — `Just ""` when the text ends in a
  bare `?` or `#`, as Elm's, which `search` and `hash` alone cannot tell from none.
- `toString` is unchanged, so `toString` of a parsed URL is the host's `href` for every `Url`
  `fromString` gives.

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
pub string : Parser (String → a) a
pub int : Parser (Int → a) a
pub s : String → Parser a a
pub custom : String, (String → Maybe a) → Parser (a → b) b
pub top : Parser a a
pub slash : Parser a b, Parser b c → Parser a c              -- Elm's </>
pub map : Parser a b, a → Parser (b → c) c
pub map2 : Parser (a → b → r) r, (a, b → r) → Parser (r → c) c
pub map3 : Parser (a → b → d → r) r, (a, b, d → r) → Parser (r → c) c
-- … map4 to map8, the same pattern
pub oneOf : List (Parser a b) → Parser a b
pub questionMark : Parser a (query → b), Query.Parser query → Parser a b   -- Elm's <?>
pub query : Query.Parser query → Parser (query → a) a
pub fragment : (Maybe String → fragment) → Parser (fragment → a) a
pub parse : Parser (a → a) a, Url → Maybe a
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

route : Parser (Route → a) a
route =
    Parser.oneOf
        [ Parser.map Parser.top Home
        , Parser.s "blog" ▷ Parser.slash Parser.int ▷ Parser.map Blog
        , Parser.s "user" ▷ Parser.slash Parser.string ▷ Parser.slash (Parser.s "comment") ▷ Parser.slash Parser.int ▷ Parser.map2 Comment
        , Parser.s "search" ▷ Parser.questionMark (Query.string "q") ▷ Parser.map Search
        ]

toRoute : Url → Route
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
pub string : String → Parser (Maybe String)
pub int : String → Parser (Maybe Int)
pub enum : String, Dict String a → Parser (Maybe a)
pub custom : String, (List String → a) → Parser a
pub map : Parser a, (a → b) → Parser b
pub map2 : Parser a, Parser b, (a, b → r) → Parser r
-- … map3 to map8, the same pattern, the function last
```

As Elm's: `string`, `int` and `enum` are `Nothing` unless the key appears exactly once with a
value that converts; `custom` gets every value of the key, in order.

```elm
-- module Url.Builder (core)
pub type Root = Absolute | Relative | CrossOrigin String
pub type QueryParameter                                        -- opaque
pub absolute : List String, List QueryParameter → String
pub relative : List String, List QueryParameter → String
pub crossOrigin : String, List String, List QueryParameter → String
pub custom : Root, List String, List QueryParameter, Maybe String → String
pub string : String, String → QueryParameter
pub int : String, Int → QueryParameter
pub toQuery : List QueryParameter → String
```

Elm's, with one change (H8): **each path segment is percent-encoded** (`Url.percentEncode`), as
query keys and values already are — `absolute [ "tags", "c/c++" ] []` is `/tags/c%2Fc%2B%2B`, where
Elm's is `/tags/c/c++`, a different path. With the parser's decoding, `parse` of a built URL gives
back the segments it was built from. `custom`'s fragment is written as given.

**(c) `Browser.Navigation`: the page's address, changed on purpose.**

*Amended 2026-10-12 (§9.8.17 (b)): elm/browser's names are commands that take values — `pushUrl`,
`replaceUrl`, `back`, `forward`, `load` with a tagger for a refusal, and `reload` — and the direct forms below
are renamed `push`, `replace`, `goBack`, `goForward`, `loadPage` and `reloadPage`. Every rule below is the
direct form's.*

```elm
-- module Browser.Navigation (browser), re-exported by browser-tea
pub type Key                                                    -- opaque, equatable: a model may hold it
pub key : ⊤ → Key                                             -- impure: the page's key
pub type Error = BadUrl String | CrossOrigin String | Throttled

pub pushUrl : Key, String → Result Error ⊤                    -- impure
pub replaceUrl : Key, String → Result Error ⊤                 -- impure
pub back : Key, Int → Result Error ⊤                          -- impure
pub forward : Key, Int → Result Error ⊤                       -- impure
pub load : String → Result Error ⊤                            -- impure
pub reload : ⊤ → ⊤                                           -- impure

-- §9.8.10 (b), kept
pub currentUrl : ⊤ → Maybe Url
pub eachUrlChange : (Url → ⊤) → ⊤                           -- suspends
pub onUrlChange : (Url → msg) → Sub msg
-- new
pub eachUrlRequest : (Browser.UrlRequest → ⊤) → ⊤           -- suspends
pub onUrlRequest : (Browser.UrlRequest → msg) → Sub msg

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
      { init : model × Cmd msg
      , update : msg, model → model × Cmd msg
      , view : model → Document msg
      , subscriptions : model → Sub msg
      }
    → Program

pub application :
      { init : Url, Key → model × Cmd msg
      , update : msg, model → model × Cmd msg
      , view : model → Document msg
      , subscriptions : model → Sub msg
      , onUrlRequest : UrlRequest → msg
      , onUrlChange : Url → msg
      }
    → Program
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
`Browser.mountAt` it still follows the whole document's links, as (c) says. *Amended 2026-10-12*: the example uses the commands of §9.8.17 (b).

```elm
update msg model =
    case msg of
        ClickedLink (Browser.Internal url) →
            ( model, Navigation.pushUrl model.key (Url.toString url) Refused )

        ClickedLink (Browser.External href) →
            ( model, Navigation.load href Refused )

        UrlChanged url →
            ( { model | route = toRoute url }, Cmd.none )

        Refused _ →
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
- **`Url.fromString` is the host's WHATWG parser** (amended 2026-10-02, (a)): its parts are
  normalised as the browser normalises the address it navigates to and fetches, where Elm's
  splitter kept the text as written.
- **`key ()` is public, and every push is announced** (H6): the hole Elm's `Key` fenced is closed
  at the announcement, so the direct form can do what `Tea.application` does.
- **`pushUrl`, `replaceUrl`, `back`, `forward` and `load` return `Result Error ()`** where Elm's
  were `Cmd msg` that crashed on a throttled or cross-origin push. The command form is
  `Cmd.task`/`Cmd.do` over them (H10 asks whether to add command-returning helpers). *Amended 2026-10-12*: the commands are added under Elm's names, each with a
  tagger for its refusal, and these direct forms renamed (§9.8.17 (b)).
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

*(Amended 2026-10-02, §9.8.5's amendment: a listener a subscription added with no fiber is held
by `Hosted`'s set of added listeners, and is removed by the function `Hosted` gave
`Task.onShutdown`, in a microtask queued at the stop, before the sweep.)*

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
pub foreign impure shutdown : Int, sync (Int → ⊤) → ⊤
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
*(Amended 2026-10-02, the size pass: a root scope is listed when it is first given a fiber, not
when `openRoot` makes it, so a build that opens a root and starts no fiber — the empty
`Tea.element` — keeps no registry, and `openRoot` is the one literal it was. A scope never given a
fiber has nothing to close: a fiber started into it once the runtime stops is cancelled before it
runs, closed or not ((d) step 5).)*

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
  *(Amended 2026-10-02: the function only calls `Task.shutdown`. The after-render queue needs no
  emptying: only a flush runs it, and no flush runs once `dead` is set, so what it holds is dropped
  unrun as (a) requires.)*

`deadline` is a constant of the `browser` platform, **1 000 ms** (choice 3 below), as W3's slice
and budget are the platform's.

*Amended 2026-10-22 (#596):* `Task.stopScheduler` is `shutdown` for one scheduler of
`transparent-effects-proposal.md` §17.5's amendment of that date — the same three phases, for the
fibers of that scheduler alone — and `shutdown` itself stops every scheduler made. The `cloudflare`
platform calls it per request and per object (§9.12 (d), (f)).

**(d) The teardown, step by step.** Every step runs in the teardown's macrotask or in the drains
after it; each is deterministic, ordered by creation and by the scheduler's FIFO.

1. **The sweep.** Every root in the registry, in creation order *(amended 2026-10-02: in the
   order each was listed — a root fiber when it starts, a root scope when it is first given a
   fiber (c); for one program's one root scope the same order)*: a root scope is marked closed and
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
programs' roots in the order the programs were started (`Browser.programs`' order). *(Amended
2026-10-02: in the order each program's root first ran a fiber, which is the programs' order
unless a later program starts work before an earlier one; (d) step 1.)* This is the
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
| `run/TaskShutdown` (Node) | `Task.shutdown` called directly, with a deadline of 250 and a `done` that prints its count: releases in the order (e) gives, a `soon` dropped, a new spawn cancelled before it runs, a second call doing nothing |
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

*As built, 2026-10-02* (`core/Task.js`, `core/Task.beni`; `platforms/browser/Rt.beni`,
`Browser.beni`; `tests/browser/driver.mjs`), as specified above, with these precisions:

- **A build with no fiber keeps none of the teardown.** The drain's guard and `shutdown` reach it
  through two hooks the fiber record's constructor sets, so a build that makes no fiber and keeps
  no finaliser outside one — a `Tea.element` whose commands never wait — keeps only the state flag:
  `shutdown` there stops the queue and runs nothing, and never calls `done`, there being nothing to
  end. The registry is still filled by `openRoot`. *(Amended 2026-10-02: no longer; (c)'s
  amendment.)*
- **The drain's guard tears down on its own.** A fiber's throw schedules the teardown whether or
  not a platform calls `shutdown`; with no call there is no deadline. On Node the process ends first
  (`run/TaskDefectOnNode`), as (k) says.
- **`Rt`'s `stop` calls the teardown just before it sets `dead`**, through a separate function that
  reads `dead` first: the teardown reads nothing of the page, and the shape lets a release build
  that knows the teardown is null (a page of `Browser.program`s) keep `stop` the one write it was.
- **A throw that stopped the page on its way to the drain's guard** (a body's `send` whose `update`
  threw, `shutdown` already called) is still the defect: its fiber is the culprit.
- **`Task.soon` queues while stopping**, and the drain drops the entry; `queued` turns `False` when
  it is dropped. A fiber started while stopping is cancelled before it runs.
- The warning is `console.warn("Cleanups cut short while stopping:", n)`; the screen adds the same
  line.
- Driver steps `timers` and `listeners` (`tests/corpus/README.md`); fixtures as (n) lists, plus
  `browser/tea/WindowEvents`' listener counts. `DefectRunsReleases` and `DefectQueuedDropped` pass
  on the kernel alone (a fiber's or `soon` work's throw); the four of the synchronous path were red
  until the wiring. Every page passes `zig build test-browser` in Chrome.

**Against Effect, where it still falls short.** A fiber parked inside an uninterruptible acquire
that never answers keeps the teardown from ending (`done` is never called), as it would keep an
Effect scope from closing. *(Amended 2026-10-02: a second gap, a `bracket` opened inside a
finaliser that the deadline — or a throw, (g) — then cuts short losing its own release, is closed.
The cut discards that finaliser's continuations, and then moves what it had registered and not yet
released — a `bracket`'s release, a nested `scope`'s close — onto the fiber's stack, each above a
boundary of its own, last first, ahead of the finalisers registered before it: what Effect, which
has no deadline, runs when the use is interrupted. Past the deadline each runs to its first wait,
as every finaliser does. `run/TaskShutdownCutBracket`.)*

**Measured** (`bench/size.mjs`, `--release`, brotli 11, against `master` before the slices): the
empty `browser` page **446 → 446** and the empty `Tea.sandbox` **446 → 446**, byte for byte the
same file; the empty `Tea.element` **1 222 → 1 347** (+125: `shutdown`, the state checks, the
registry push in `openRoot`, and `Rt`'s teardown reference and warning — the element still ships no
fiber); `Random.generate` (no fiber) **1 955 → 2 121** (+166); the `Http` + `Time` page **5 306 →
6 012** (+706, against (m)'s estimate of 250–350: the sweep and its resumable guard, the deadline
and its abandonment, finaliser boundaries, the culprit's recovery and the registry). The `bench/ui`
table app is a `Tea.sandbox` and builds to the same bytes; the fiber benchmark (`bench/fiber`,
Node) moved within its run-to-run noise.

**The size pass** (2026-10-02; `bench/size.mjs`'s page lines, `--release`, brotli 11, each change
priced alone). The base is today's compiler with the teardown taken out of `Task.js`, `Rt.beni`
and `Browser.beni` (so the compiler's own gains since are not counted): element **1 211**, `random`
**1 956**, `Http` + `Time` **5 813**. Before the pass, with the cut-finaliser fix above: 1 349,
2 117, 6 526. Each change, as element / `random` / `Http` + `Time`: a root listed at its first
fiber, `openRoot` back to its literal, −25 / −8 / −2; the host's function calling only
`Task.shutdown`, −5 / −13 / −4; the kernel's bindings that shared a name with a property
(`value`, `wait`, `scope`, `interrupt`, …) renamed, so the compactor can shorten them, 0 / −9 / −50;
the deadline's timers as plain globals, 0 / 0 / −8. After: **1 319, 2 087, 6 470** (+108, +131,
+657 against the base); the three other pages that run fibers fell 21–42. No change adds work at
run time. **What the element still carries is the wiring, and while the kernel is a sibling it
cannot go**: `Rt`'s teardown reference and its warning, the host's `onStop` function, and
`shutdown` with its two cells — each reached from code every hosted page runs, where only a
build that makes a fiber needs it. Whole-program specialisation drops exactly that (a `Js.Ref`
nothing writes folds, and the branch behind it goes, as `Browser.program` pages show), but it
sees only beni: the kernel in beni (`plans/core-in-beni.md` K3) is what can let the element's
`stop` read a cell only a fiber writes.

*Amended 2026-10-02, with the kernel in beni:* so it does. **The wiring of (c) is replaced.**
`Rt`'s `stop` calls `Task.shutdown deadline stopped` itself, behind `Rt`'s after-render `phase`
cell — which only a hosted mount sets, so a page of `Browser.program`s never calls it — and a
second call does nothing; the hosted mount takes four arguments again, `Browser.beni`'s `host` hands
nothing over, and `deadline` is `Rt`'s. In the kernel `shutdown` calls two hooks, `closing` (set by
`newFiber`: the teardown) and `quitting` (set by `soon`: the queue stops), so in a build that makes
no fiber and queues no `soon` work both cells fold to null and `stop` is the write it was before the
teardown. The crash screen's `error` listener asks `Task.cleansUp ()` whether a teardown may report
more. Measured as above: the empty `Tea.element` **1 211 = 1 211** (not the same bytes: the beni
`openRoot` is a literal of one key, specialisation having dropped the two nothing reads, and the
file is 45 bytes shorter raw), the `Browser.program` and `Tea.sandbox` pages and `url` byte for byte
the same, `random` **1 989** (+33: `soon`'s work is dropped when the page stops), the `Http` + `Time`
page **6 218** (+405 against the base, against (m)'s 250–350); the other fiber pages 5 530–5 944.

#### 9.8.15 Time, the log and a program that cannot wake, per platform (2026-10-02)

*Added 2026-10-02*, with the owner's adoption of research 48's decisions. The APIs are core's and
their contract is [`transparent-effects-proposal.md`](transparent-effects-proposal.md) §17; this
section records only what each platform changes, so a platform author finds it here.

**(a) Time moves into core** (§17.6). `browser`'s `Time.Duration` becomes an alias of core's
`Duration.Duration`; `Time.millis`, `Time.seconds` and `Time.inMillis` stay, as calls of core's
`Duration.millis`, `seconds` and `toMillis`; `Time.sleep` is `Task.sleep`, which waits on the
calling fiber's clock; `Time.now` reads `Clock.now`. `Http`'s `timeout : Maybe Duration` and every
page's signatures are unchanged, and a page that never calls `Clock.run` still runs on the host's
`setTimeout` and `Date`, so the test driver's virtual clock governs it as before. `node`'s
`Io.sleep : Int → ()` keeps its signature as `Task.sleep (Duration.millis ms)`, and `Io.js`'s
`startTimer` is deleted.

**(b) The log moves into core** (§17.11). `platforms/browser/Log.beni` is removed; core's `Log`
keeps `info`, `warn` and `error : String → ()` with the same output on a page (the default sink is
the console method for the level), adds `trace`, `debug`, `log`, `annotate`, `span`, `minimum` and
`withSink`, and `browser-tea` re-exports it as it re-exported the browser's. A platform replaces the
default sink with `Log.setSink`; **`node`'s `Io.run` installs one that writes a `logfmt` line per
entry to standard error.** §9.8.10 (d) is superseded by this paragraph.

*As built in part, 2026-10-20 (#358).* `core/Log.beni` has the levels, the five direct forms,
`log`, `Entry`, `setSink` and `logfmt`; `node`'s `Io.run` installs the `logfmt` sink. The log
context (`annotate`, `span`, `minimum`, `withSink`) is the next slice. **`platforms/browser/Log.beni`
stays until §9.8.16 (b)'s `Log.write` has a home outside it**: a platform module shadows the core
module of its name for the program and for the platform itself (§9.8.11 (a), §9.1), so a browser
program still imports the browser's `Log`, and a `node` program imports core's. *Second part, the
same day:* the log context (`annotate`, `span`, `minimum`, `withSink`) is built, in the fiber's
log-context slot (§17.5), so a `node` line carries the fiber's spans and annotations. *Third part,
the same day:* `platforms/browser/Log.beni` is removed, so a page program imports core's `Log`, and
the default sink prints what the browser's `Log` printed. `Log.write` is `Cmd.log` (§9.8.16 (b), the
owner's decision). `browser-tea` no longer names `Log` in `"reexports"`: no platform module has the
name now, and a program sees core's modules without a re-export.

**(c) A Node program that can never wake ends, with exit 1** (§17.10; A8's "never a silent exit
0"). `Io.run` sets the exit code to 1 when it starts its fiber, which the fiber's end overwrites as
today (the program's code, or 130). When Node's event loop is about to empty (`beforeExit`) and that
fiber has not ended, `Io.js` writes *"beni: the program cannot go on: every fiber is waiting for
something that can never happen."* to standard error, schedules nothing, runs no finaliser, and the
process exits 1 — the ending §9.8.14 (k) gives Node's defects. **When `Io.run`'s fiber ends,** after
its output and exit code, `Io.js` calls `Task.shutdown` with a deadline of 1 000 ms, so a fiber
still running — a `Task.spawnDetached` one — is cancelled and cleaned up rather than keeping the
process alive. A page is not affected: it is alive while it is open.

**Nothing else moves.** `Tea`'s command table and policies, `Sub.listen`, `Dom.rendered` and the
teardown of §9.8.14 are unchanged; the combinators of §17.7 cancel and wait exactly as
`closeScope` does, so they inherit §9.8.14 (e)'s order and its deadline.

#### 9.8.16 Programs start from `init ⊤`, and commands take values (2026-10-12)

*Added 2026-10-12*, the owner's decisions on [`ownership-checker.md`](ownership-checker.md) §20.11
(thesis Change 4 and proposal O5; `ownership-checker.md` §21). This section is normative for every
program constructor of `browser`, `browser-tea` and `browser-direct`, and for the command
constructors of `browser`'s `Cmd`, `Storage`, `Http` and `Log`. It amends §9.8.1's table, §9.8.2's
API, §9.4.6's `cx.programInit` and §9.8.13's `Tea.application` only where it says so.

**(a) `init` is a function, on every platform.** A program's `init` is a function the platform calls
**once per mount**, when that program mounts, and never where `main` is evaluated:

| Constructor | Package | `init` |
|---|---|---|
| `Browser.program` | `browser` | `sync (⊤ → model)` |
| `Tea.sandbox` | `browser-tea` | `⊤ → model` |
| `Tea.element`, `Tea.document` | `browser-tea` | `⊤ → model × Cmd msg` |
| `Tea.sandbox` | `browser-direct` | `sync (⊤ → model)` |
| `Tea.element`, `Tea.document` | `browser-direct` | `sync (⊤ → model × Cmd msg)` |
| `Tea.application` | both | `Url, Navigation.Key → model × Cmd msg`, unchanged: it already was one |

*Why.* A value `init` puts the same arrays in every mount and every `Reset` arm that returns it, so a
platform that edits a list in place would change what the next mount or reset starts from; a function
builds the model anew each time (thesis Change 4). The checker needs one meaning of `init` on all
three platforms so that one source has one verdict (`ownership-checker.md` §20.2), and the owner took
the API change on the template platforms too, where nothing is written in place yet, rather than let
one source's `init` mean two things. `init` is `sync` where the record's other functions already
were, and `browser-tea`'s `element` calls it inside `Browser.hosted`'s `sync` `init`, so an `init`
that may suspend is refused where it is written (`sync_boundary`, "`Tea.sandbox` hands it to the
platform, which calls it synchronously"), not at `main`.

*What changes for a page.* `Rt`'s mount calls `program.init()` where it read `program.init`, and
`Browser.hosted`'s mount record has an `init` that answers `null` (a hosted program's model is its
architecture's, made in its own `init`). `browser-tea`'s `element` hands `start` the value of
`app.init ⊤`. On `browser-direct`, `cx.programInit` (§9.4.6) evaluates `init ⊤`: a lambda of `⊤`
written in the record, `init = λ⊤ → e`, is lowered as its body `e` in the mount, byte for byte what
the mount wrote for the old `init = e`, so `emit/direct/` does not move; any other function is called,
`init()`, and the binding is kept by `--release` as one that may have an effect (`backend.md` §9).
So **`init` runs at mount on every platform**: a throw in it is a defect of the mount everywhere
(`browser/direct/InitThrows` has one golden now, where it had a `.tea-expected`), and a `Debug.log`
in it prints at mount. `Tea.document`, which hands its record to `element`, passes `app.init` on.

*Migration.* `beni fmt --migrate-init` (`frontend.md` §11.10) writes the `init = e` of every program
record `init = λ⊤ → e`; plain `beni fmt` lays the lambdas out after it. A program that keeps its first
model in a top-level value compiles once migrated, and stays rejected by the ownership checker at its
first in-place edit (T53) until it writes `init ⊤ = …`. Without the migration a value `init` is a type
error naming the field: "The `init` field of this record is not what I expect … it needs to be
`⊤ → model`".

**(b) Commands that persist or send data take the value** (thesis O5). A command constructor that
stores, sends or logs data takes the data — text, a request whose body is already text — computed by
`update` when it makes the command, never a function whose body reads the model when the command runs.
Three are added, each a thin wrapper over the direct form §9.8.11 (a) gives first:

```elm
-- Storage
pub save : Area, String, String, (Error → msg) → Cmd msg
    -- `set` when the command runs; `failed error` is sent only when the write did not happen
-- Http
pub send :
      { method : String, headers : List Header, url : String, body : Body
      , expect : Expect x a, timeout : Maybe Duration }
    , (Result x a → msg)
    → Cmd msg
    -- `Cmd.task` over `request`, `same-origin`, no tracker; elm/http 1.0's `send`
-- Log
pub type Level = Info | Warn | Error
pub write : Level, String → Cmd msg
    -- `info`, `warn` or `error` of the line when the command runs
```

`Storage.save` sends its tag only on failure, by the same `Error` constructors `set` returns: a save
that worked needs no message and costs no dispatch, and one that did not is never silent — the program
names what it does with `QuotaExceeded` and `Unavailable`. `Http.send` has no `tracker`: progress is a
callback that runs while the request does, so a body that tracks progress calls `request` itself; its
`credentials` are `request`'s, and a `riskySend` waits for a program that needs one. `Log.write` lives in
`browser`'s `Log` beside the three direct forms; §9.8.15 (b)'s move of the direct forms into core is
not built, and a command stays a `browser` module's either way, since `Cmd` is one. *(Amended
2026-10-20: the move is built, and the command is `Cmd.log`, below.)* Each body is a
function of its arguments that never waits, so each command is `Now` (§9.8.11 (b)) but `Http.send`'s,
which is `Perform`. Elm has no storage or log commands — a port is its answer — so there is no name to
mirror but elm/http's.

*Decided 2026-10-20 by the owner (Jayson Reis, dashboard `node-log-q1`; #358):* when §9.8.15 (b)
removes `platforms/browser/Log.beni`, `Log.write` becomes **`Cmd.log : Log.Level, String → Cmd msg`**
in `browser`'s `Cmd`: the command form of core's `Log.log`, a body that calls `Log.log level line`
when the command runs. A program writes `Cmd.log Log.Info line`. Core cannot hold the command,
because `Cmd` is a `browser` type, and a `browser` module named `Log` would hide core's (§9.8.11 (a)).
The level is core's `Log.Level`. The other option was a module `Browser.Log` with `write`.
*Amended 2026-10-20 (#547):* a command runs after `update` has returned, so its line has the
default log context: no annotation, no span, and the minimum `Info`. An `annotate` or a `minimum`
around the `update` arm that makes the command does not reach it, and a `Cmd.log Log.Trace` or
`Cmd.log Log.Debug` is not written. A program-wide minimum that would let it be written is the
owner's decision, #551. *Amended 2026-10-21 (#551, the owner's decision):* the default context's
minimum is the program's minimum when the command runs, which `Log.setMinimum` sets (proposal
§17.11), so after `Log.setMinimum Log.Debug` — in `init`, say — a `Cmd.log Log.Debug` is written.
The command reads the minimum when it runs, not when `update` makes it: a `Cmd.log Log.Debug` made
before a `Log.setMinimum Log.Error` in the same `update` is not written. A command still does not
see `update`'s `annotate` or `minimum`; that it should is #597.

*Amended 2026-10-14 (§9.8.19; `plans/queue.md` row 82):* `send`'s record has elm/http 2.0's
`tracker : Maybe String`, and `Http.track` is the subscription that hears it. `riskySend` is `send`
with `credentials: "include"`. A program that tracks progress or sends cookies to another origin no
longer writes a body over `request` or `riskyRequest`. A `send` written before this amendment adds
`tracker = Nothing`.

**(c) The inventory: every constructor that takes a function, and why it stays.** Each constructor of
`browser`, `browser-tea`, `browser-direct` and core that makes a `Cmd`, a `Sub` or a body:

| Constructor | Takes | Verdict |
|---|---|---|
| `Cmd.perform`, `Cmd.keyed`, `Cmd.afterRender` | a body `Send msg → ⊤` | **stays**: a body is effects run later — a request, a timer, a focus — and effects are not data. It is the direct-forms-first form every wrapper is written over (§9.8.11 (a)) |
| `Cmd.task`, `Cmd.do` | work `⊤ → a` | **stays**, for the same reason; the data a body needs is computed before it and captured as a value |
| `Cmd.map`, `Sub.map` | a tag `a → msg` | **stays**: it maps messages; it reads no model |
| `Cmd.none`, `batch`, `cancel`, `cancelAll` | values | already values |
| `Random.generate` | a `Generator` and a tag | **stays**: the generator is a value built at the call (`Random.uniform x model.items` holds the list it was given, as a value does) |
| `Sub.listen`, `Sub.on`, `Time.every`, `Browser.Events.on…`, `Navigation.onUrlRequest`, `onUrlChange` | a body or a listener and a tag | **stays**: a subscription is an effect that runs while its key is live |
| `Storage.set`, `Http.request`, `Http.get`, `Http.post`, `Log.info`, `warn`, `error`, `Navigation.push`, … | values | direct forms, called in a body; they already take values (`Navigation.push` was `pushUrl` until §9.8.17) |
| `Navigation.pushUrl`, `replaceUrl`, `back`, `forward`, `load`, `reload` | values | **new**, §9.8.17 (b): commands over the direct forms |
| `Storage.save`, `Http.send`, `Cmd.log` (`Log.write` until 2026-10-20) | values | **new**, (b) |
| `core/Task`'s `spawn`, `scope`, `bracket`, … | functions | not commands: the fiber runtime a body uses |

*Amended 2026-10-14 (§9.8.19):* `Http.riskySend` takes values, as `send` does, and joins the row of
(b). `Http.track` takes a name and a tag, and joins the row of subscriptions that stay.

No capability is removed: every closure-taking constructor stays, and the three new ones are wrappers a
program could have written as a body. **A closure that stays cannot keep a model list unnoticed**: the
ownership checker treats everything a command holds as escaped at the program constructor's call — a
body that captured `model.items` makes that list escaped at every later dispatch, and an in-place edit
of it is rejected `escaped` (`ownership-checker.md` §20.4 (a), §22.3); a function handed to a `foreign`
escapes what it captured (§18.6). A body that genuinely needs the list later says so with `List.copy`.

**(d) What does not move.** `Browser.hosted`'s `init : sync (Host msg → model)`, `Tea.application`'s
`init`, the command table, the four policies, the dispatch order of §9.8.4 and every direct form.

#### 9.8.17 A send hands its payload over, and navigation is commands (2026-10-12)

*Added 2026-10-12*, the owner's decision on owned sends (thesis Change 7; `ownership-checker.md` §23.1) and the
manager's answer to `ownership-checker.md` §22.7 item 1. Normative for what a send means, for
`Browser.Navigation`, and for every program that changes the page's address. It amends §9.8.13 (c)'s API and its
*Where this departs* list, and §9.8.16 (c)'s inventory, only where it says so.

**(a) What a send means.** A body's `send`, a subscription's tagged value, a tagger's result: each **hands its
payload to `update`**, and the sender gives it up. Nothing changes at run time — no message is copied, the
dispatch order of §9.8.4 is unchanged, a body's send is still dispatched at once (T29) — but the ownership
checker holds the sender to it: a sender that reads a list after sending it, or sends a list the model or
another live value still holds, is rejected at the send (`ownership-checker.md` §23.2), so that `update` may
write any payload it is handed in place. A view event is not a send: its message is built by the runtime from
the markup, and may hold the model's lists (§23.6). What the runtime does with a send — `Hosted.emit`, an
architecture's `send`, the direct platform's dispatch queue — forwards the payload to `update` once and keeps
nothing of it: an obligation on the runtimes, on the checker's trusted surface (§23.9).

**(b) `Browser.Navigation`'s commands.** elm/browser's names are commands that take values; the functions that
change the address at once, which §9.8.13 (c) gave those names, are renamed:

```elm
-- module Browser.Navigation (browser), re-exported by browser-tea
pub pushUrl : Key, String, (Error → msg) → Cmd msg      -- push, when the command runs
pub replaceUrl : Key, String, (Error → msg) → Cmd msg   -- replace
pub back : Key, Int, (Error → msg) → Cmd msg            -- goBack
pub forward : Key, Int, (Error → msg) → Cmd msg         -- goForward
pub load : String, (Error → msg) → Cmd msg              -- loadPage
pub reload : Cmd msg                                    -- reloadPage

-- the direct forms (§9.8.11), as §9.8.13 (c) specified them
pub push : Key, String → Result Error ⊤                 -- impure
pub replace : Key, String → Result Error ⊤              -- impure
pub goBack : Key, Int → Result Error ⊤                  -- impure
pub goForward : Key, Int → Result Error ⊤               -- impure
pub loadPage : String → Result Error ⊤                  -- impure
pub reloadPage : ⊤ → ⊤                                  -- impure
```

Each command is `Cmd.perform` over its direct form, made when the command runs, which never waits (a `Now`
body, §9.8.11 (b)); it sends `refused error` only when the change was refused, as `Storage.save` sends its tag
only on failure (§9.8.16 (b)), and nothing when it was made — `onUrlChange` hears a change, from either form.
`reload` documents no failure and takes no tagger. Every rule of §9.8.13 (c) — resolution against the page, the
announcement to followers, each failure and how it is found — is the direct form's and so the command's.

```elm
update msg model =
    case msg of
        ClickedLink (Browser.Internal url) →
            ( model, Navigation.pushUrl model.key (Url.toString url) Refused )

        ClickedLink (Browser.External href) →
            ( model, Navigation.load href Refused )

        UrlChanged url →
            ( { model | route = toRoute url }, Cmd.none )

        Refused _ →
            ( model, Cmd.none )
```

*Why commands.* An `update` that changed the address wrote `Cmd.task (λ⊤ → Navigation.pushUrl model.key …)`,
a body that reads the model when it runs — Conduit's one capture of its whole model (research 78 §5). The
ownership checker takes everything a command holds to be kept (`ownership-checker.md` §20.4 (a)), so such a body
made every model list unwritable in place. A command that takes the key and the address holds two values and no
list (§23.8). It is thesis O5 (§9.8.16 (b)) applied to the address.

*Where this departs from elm/browser.* **Each command but `reload` takes a tagger for its refusal**, where Elm's
`pushUrl : Key -> String -> Cmd msg` has none: Elm's push crashed on a cross-origin or throttled address, and
beni returns each documented failure as a typed value (CLAUDE.md rule 9) — a command with no tagger would have
nowhere to send it but a crash or silence (`plans/http-and-routing.md` H10's two choices), and a throttled push is
an event of a working page, not a defect. A program that means to ignore a refusal says so with an arm that does
nothing. **The direct forms are renamed**: §9.8.11 keeps Elm's name for the wrapper and gives the direct form
its own (`Random.generate` and `Random.value`), and Elm's names are the commands. `reloadAndSkipCache` stays
unprovided (§9.8.13 (c)).

*Migration.* Conduit, the `browser/tea` pages that route, and `bench/size-apps/ApiAndRoutes` use the commands;
`browser/tea/NavigatePush`, `NavigateErrors` and `ListenerOrder` test the direct forms under their new names, and
`browser/tea/NavigateCommands` the commands. §9.8.16 (c)'s inventory row for the direct forms names `push`,
`replace`, `goBack`, `goForward`, `loadPage` and `reloadPage`; the commands are values (b).

#### 9.8.18 Animation frames (2026-10-12)

*Added 2026-10-12*, closing §9.8.8's owed `onAnimationFrame`. Normative for `Browser.Events`' frame
subscriptions and their direct forms, and for how a frame's messages meet the render loop
(`backend.md` §15.11). elm/browser's `Browser.Events` is the model
(`references/elm-browser/src/Browser/AnimationManager.elm`, `Elm/Kernel/Browser.js`), and every
departure is listed in (e).

**(a) The API.** In `Browser.Events` (`browser`), re-exported by `browser-tea` and `browser-direct`
(which runs no subscription of any kind until its slice S5 compiles `Tea.element`,
`browser-direct.md` §10.1, §14 — nothing here is specific to either architecture):

```elm
pub onAnimationFrame : (Time.Posix → msg) → Sub msg        -- the moment each frame began
pub onAnimationFrameDelta : (Float → msg) → Sub msg        -- the milliseconds since the frame before
pub eachAnimationFrame : (Time.Posix → ⊤) → ⊤              -- the direct forms (§9.8.11 (a))
pub eachAnimationFrameDelta : (Float → ⊤) → ⊤
```

Each subscription is a `Sub.on` listener (§9.8.5's amendment), so it runs with no fiber; the direct
forms are `Listen.each` over the same listener, as every pair of this module is. `Time.Posix` exists
(§9.8.8), and `Browser.nextFrame`, R45's "wait for the next frame", is **not** built: Elm has no such
function, `eachAnimationFrame` is the direct form a fiber that animates needs, and waiting for a
render is `Dom.rendered` (§9.8.6). It stays owed until a program needs it.

**(b) One request per frame.** The page has one frame clock: the listeners every frame subscription
and direct form added, in the order added, and at most one pending `requestAnimationFrame`. The first
listener added while no frame is pending asks for one; each frame asks for the next before it hands
the listeners anything; the last listener removed cancels the pending frame with
`cancelAnimationFrame` **at once**, so a page with no live frame subscription has no frame pending and
asks for none — no idle loop, at any rate. Any number of subscriptions, of either kind, and of one key
or several, share that one request: declarations of one key share one listener (§9.8.5), and the two
keys' listeners share the clock. Elm's effect manager has the same shape, one `rAF` for every
subscriber.

**(c) What a frame sends.** A frame reads the host's `Date.now()` once — the frame's time, as Elm's
kernel does — and hands every listener that time and the clock's previous time: `onAnimationFrame`
sends `Time.fromMillis now`, `onAnimationFrameDelta` sends `toFloat (now − last)`. The previous time
is the last frame's, or, before the clock's first frame, **the time the clock started** — when its
first listener was added — so the first delta of a fresh start is the time from the subscription's
arrival to its first frame, Elm's `oldTime` from `now` at `onEffects`. Each listener sends in the
order the listeners were added, and its declarations' taggers in declaration order (§9.8.5). A frame
hands its time to the listeners added **before it began**: it walks a copy of the set, so a listener
added while the frame's callback runs gets its first frame next time, never this one with the
previous frame's time. One removed while the frame runs may still be handed this frame's time, which
its closed relay drops (§9.8.5 point 3).

**(d) The render loop.** Elm renders on `requestAnimationFrame`; beni renders on a microtask after the
messages of a task (`backend.md` §15.11), so the question is only whether a frame's message can miss
its frame. It cannot: the frame callback runs its listeners under core's `Task.fromHost`, as a
timer's callback does (`browser/tea/TimerTurn`), so the deliveries they queue (§9.8.5 point 2) are
drained before the callback returns, the drain is a turn (`Task.onTurn`), and the turn renders. **A
frame's messages are applied, and the page rendered, inside the frame's callback** — before the
browser's style, layout and paint of that frame, with no extra frame of latency. Three subscriptions
that each send a message are three `update`s and one render. A message that turns the subscriptions
off is rendered in the same callback, whose diff removes the listener and cancels the frame the
clock had just asked for, so an animation that ends leaves nothing pending.

**(e) Where it departs from Elm, and the hidden page.**

- **A hidden page draws no frames.** The host does not call frame callbacks while the document is
  hidden; the pending request waits, nothing is sent, and the first frame after the page is shown
  again carries a delta spanning the hidden spell — as Elm's does. A program that must not jump
  clamps the delta, or turns the subscription off on `onVisibilityChange`.
- **The clock restarts whenever no frame listener is left**, even for an instant: a model that swaps
  `onAnimationFrame` for `onAnimationFrameDelta` in one message removes the one listener (cancelling
  the frame) before the other is added, so the new delta counts from the swap, where Elm's manager,
  which sees one list, keeps its `oldTime`. Keeping the frame pending until the next frame instead
  would leave a page that stopped animating with one callback still asked for, against (b); and the
  diff cannot add first, because a key that left is removed in the render (§9.8.5 point 3) while one
  that arrived is added by work queued where its fiber would first run (point 1) — the order that
  keeps the two subscription kinds indistinguishable. A swap loses at most one frame's delta.
- **No fallback to `setTimeout`.** Elm's kernel uses `setTimeout(…, 1000 / 60)` where
  `requestAnimationFrame` is missing. Every host `browser` targets has it; where it is missing the
  call throws, a defect at the first frame listener's start (§9.8.10 (c)), never a timer pretending
  to be a display (`CLAUDE.md` rule 9: nothing is caught).

**(f) Failures.** `requestAnimationFrame` and `cancelAnimationFrame` document no failure in a window.
A tagger, or `update` on a frame's message, that throws does so inside the frame's drain: a defect, by
§9.8.5 point 4's path, which stops the page; after it, `Task.onShutdown`'s sweep removes the frame
listeners as it removes every listener, and the last removal cancels the pending frame (§9.8.5
point 5).

**(g) The test driver's frames.** `tests/browser/driver.mjs` replaces `requestAnimationFrame` and
`cancelAnimationFrame` before the program loads, in happy-dom and in Chrome alike, so frames are the
script's: `frame <n> [<ms>] [tasks]` draws `n` frames `ms` apart (default 16) on the virtual clock,
moving it as `advance` does, each frame's callbacks in one task, and logs `(frame at <t> ms: <k>
callbacks)`; `frames` logs the callbacks pending (`tests/corpus/README.md`). The count is what proves
(b): a page with three frame subscriptions logs one callback per frame.

*As built, 2026-10-12* (`platforms/browser/Browser/Events.beni`, beni over `Js` with no `foreign`;
`tests/browser/driver.mjs`; `bench/size.mjs`'s `frames` page), as specified. The pages are
`browser/tea/AnimationFrames` — three subscriptions over two keys, one callback a frame, a first
delta from the start, a frame's render inside its task (`frame … tasks`: the view's log comes before
`(the frame's task ended)`, and after it with `Task.fromHost` taken out), no request while off, and a
restarted clock — and `browser/tea/AnimationFrameStops`, whose third frame's message ends the
subscription and leaves no frame pending. Both run as development, release and `--fiber-page` builds
against one golden. **Measured** (`bench/size.mjs`, `--release`, brotli 11): no existing page moved
by a byte, and a page subscribing to `onResize` is byte-identical to before — the frame keys are a
type of their own, so their tags stay out of `Key`'s table; the `frames` page (a `Tea.element` on
`onAnimationFrameDelta`) is 3 451 bytes and reaches no fiber, about 65 more than the same page on
`onResize`, the rest being the listener machinery every `Sub.on` page shares.

#### 9.8.19 Tracked and risky commands: `Http.track` and `Http.riskySend` (2026-10-14)

*Added 2026-10-14.* It closes `plans/queue.md` row 82 (GitHub issue #92) and `ownership-checker.md`
§22.7 item 3. This section is normative for `browser`'s `Http.send`, `Http.riskySend` and
`Http.track`. It amends §9.8.12 (a) and its *Where this departs* list, and §9.8.16 (b) and (c), only
where it says so. The model is elm/http 2.0's `request`, `riskyRequest` and `track` (`Http.elm` and
`Elm/Kernel/Http.js` at `2.0.0`). (f) lists each departure.

**(a) The API.**

```elm
pub send :
      { method : String
      , headers : List Header
      , url : String
      , body : Body
      , expect : Expect x a
      , timeout : Maybe Duration
      , tracker : Maybe String
      }
    , (Result x a → msg)
    → Cmd msg
pub riskySend : <the same record>, (Result x a → msg) → Cmd msg
pub track : String, (Progress → msg) → Sub msg
```

`send`'s record is elm/http 2.0's `request` record: it gains `tracker`. A program that wrote `send`
before this section adds `tracker = Nothing`. `riskySend` is `send` with `credentials: "include"`, as
`riskyRequest` is `request` with it (§9.8.12 (b) step 6). Both are `Cmd.task` over the direct form, so
both are `Perform` (§9.8.11 (b)), and both take values (§9.8.16 (b)).

**(b) What a tracker name does.** With `tracker = Just name`, the request reports its progress to
the page's `track` subscriptions of `name`. The values and their order are §9.8.12 (e)'s: `Sending`
with nothing sent, `Sending` with all of it once the answer's headers arrive, then `Receiving` before
the body and after each chunk. Each `Http.track name tag` subscription that is live when a value is
reported turns the value into a message through `tag`. With `tracker = Nothing`, the request reports
nothing and reads its body as text at once, as before.

- **`track` is a `Sub.on` listener** (§9.8.5's amendment), keyed by the name. Declarations of one
  name share one listener, and each declaration's tagger gets each value, in declaration order
  (§9.8.5). A program that declares no `track` adds no listener.
- **The page keeps one table.** For each name, the table holds the listeners of the live `track`
  subscriptions, in the order they were added. A listener is added when its key arrives (§9.8.5
  point 1) and is removed when its key leaves (point 3). A name with no listener is not in the table.
- **A request reports each value to the listeners of its name at that moment.** A value with no
  listener is dropped. Nothing is kept for a listener that arrives later, as in Elm, whose effect
  manager forwards a progress event to the subscriptions it has when the event arrives.
- The table is the page's, as the frame clock of §9.8.18 (b) is. (f) gives the consequence for a
  page with several programs.

**(c) The order: every value before the answer, and nothing lost to the same `update`.** A tracked
command keeps the order the direct form's tracker function has, where each `Progress` reaches
`update` before the answer. Two waits do it:

1. **Before the request starts**, a tracked command waits for the after-render phase of the flush the
   page has queued, as `Dom.rendered` waits (§9.8.6). Then it yields once (`Task.yieldNow`). That
   flush settles the subscriptions of the `update` that made the command. The work that adds their
   listeners (§9.8.5 point 1) is then ahead of the command in the ready queue. So a `track` that the
   same `update` declares hears the first `Sending`. Both orders occur without the wait. A click's
   `update` renders before its bodies first run (§9.8.4 rule 4), but the listener is added by queued
   work behind the body. An `update` in a drain (the message of another body) renders when the drain
   ends, after the new body has run. In both cases the first `Sending` finds no listener.
2. **After the answer is read**, a tracked command yields once (`Task.yieldNow`), and then it sends
   the answer. A listener delivers its values through queued work (§9.8.5 point 2), so the last
   `Receiving` is still queued when the body has the answer. The yield puts the body behind that
   delivery.

An untracked `send` or `riskySend` does not wait, and its first run and its answer stay where they
were. A tracked command waits on a page that has no `track` of its name too: what the table holds can
change during the wait, so the command does not read it first.

*Amended 2026-10-14 (review of PR #97):* **the wait changes the order in which requests start.** An
untracked command starts its request in its first run. A tracked command starts its request only
after the wait of point 1. So in one `Cmd.batch`, and among the commands of one `update`, an
untracked request starts before a tracked one, whatever their order in the batch. elm/http 2.0
starts the requests of a batch in the batch's order. (f) lists this departure, and
`browser/tea/HttpTrack` (`#batch`) pins it.

**(d) Failures.** The tracker adds no failure. The request fails as §9.8.12 (b) and (c) say. The
answer of a failed request also comes after every value the request reported. `Map` and `Set`, which
hold the table, document no failure for the operations the table uses. A tagger that throws is a
defect, by §9.8.5 point 4's path, and nothing catches it (`CLAUDE.md` rule 9).

**(e) Rungs and cost.** `send` and `riskySend` suspend, as before; `track` is pure. **Under
`--release`**, a program that calls neither `track` nor a `send` with a tracker name ships none of
this section's code. The optimiser inlines the record literal and folds the command's `Just` arm,
and the table, the waits and the chunked read go with it. `emit/release/tea/HttpSendUntracked` pins
it. **A development build ships all of it.** Reachability (`backend.md` §9) keeps a `case` arm whole,
and the program builds `Just` in other places, so the `Just` arm stays. Measured with one compiler,
the platforms before this section against the platforms after it, every `.mjs` of the output, brotli
11 on each file:

| Page | Build | Before (raw / brotli) | After (raw / brotli) |
|---|---|---|---|
| `browser/tea/ValueCommands`, an untracked `send` | development | 80 968 / 19 583 | 87 522 / 20 815 |
| `browser/tea/ValueCommands` | `--release` | 16 986 / 6 437 | 16 992 / 6 457 |
| `emit/release/tea/HttpSendUntracked`, one `send` | development | 68 949 / 16 563 | 75 507 / 17 795 |
| `emit/release/tea/HttpSendUntracked` | `--release` | 12 606 / 4 897 | 12 612 / 4 883 |

So an untracked page grows by about 6.5 kB raw (+8.1% for `ValueCommands`) in a development build.
This section accepts that cost. elm/http 2.0's record carries the tracker, and an arm that a
development build drops needs a second command form. The table is made by the first listener, so a
page that never tracks makes none, in both builds. A value crosses into the table at a type
variable, so tracking pins no tag of `Progress` or `Maybe` (§4, *What JavaScript may read of a beni
value*). `emit/release/tea/HttpSendTracked` pins it: the `Maybe` of `Receiving` keeps integer tags,
and the one string tag is the private key of `track`.

*Corrected 2026-10-14 (review of PR #97):* the first text of (e) said that a page that never tracks
ships none of this code, with no build named. That is true only under `--release`.

**(f) Where this departs from elm/http 2.0, and why.**

- **One table for the page, not one for each program.** Elm keeps the tracker table in its effect
  manager, and each `Elm.Main.init` has its own manager. In beni, `Http` sits below every
  architecture (`browser-tea`, `browser-direct`, any `Browser.hosted` program), and a command body
  has no handle on the program that runs it. A table for each program makes every architecture hand
  its program to every body and every listener: a new obligation, and a cost on every command of
  every program. So two programs on one page (`Browser.programs`) that track one name hear each
  other's requests. A page that mounts one program twice gives each mount its own tracker names.
  *Decided 2026-10-14 (Cesar):* keep one table for the page.
- **No `Http.cancel`.** In elm/http 2.0 the tracker name also cancels the request. In beni,
  cancellation belongs to the fiber (§9.8.12 (d)): a keyed body over `request` and `Cmd.cancel`
  cancel it. `send` stays unkeyed, so nothing cancels a `send` but the program's end.
  *Decided 2026-10-14 (Cesar):* do not add `Http.cancel`. `Cmd.keyed` with `Cmd.cancel` covers the
  need.
- **The command keeps elm/http 1.0's name `send`** (§9.8.16 (b)), and its risky form is `riskySend`.
  The direct forms already have elm/http 2.0's names `request` and `riskyRequest` (§9.8.12 (a)).
- **`track` has no direct form** (§9.8.11 (a)). The direct form of tracking is `request`'s tracker
  function. A fiber that hears the progress of another body's command can be added as `Listen.each`
  over the same listener, when a program needs it.
- **`Sending` is coarse: 0, then all of the body when the answer's headers arrive.** The values are
  §9.8.12 (e)'s. `fetch` reports no upload progress, so there is no value between the two, and
  `fractionSent` is 0 for the whole upload and the server's work, then 1. elm/http 2.0 reads
  `xhr.upload`'s `progress` events, so its `Sending` grows while the body uploads. Decision H4
  (`plans/http-and-routing.md`) chose `fetch` for every request. *Decided 2026-10-14 (Cesar):* this
  section lands with the coarse `Sending`; GitHub issue #100 asks for `XMLHttpRequest` on a tracked
  request, and so reopens H4.
- **An empty body reports `Sending 0/0` twice.** These are the two values of §9.8.12 (e), the same
  for every body, so a program sees one shape for every request. elm/http 2.0 reports no `Sending`
  for a request without a body, because `XMLHttpRequest` fires no upload event then.
  `browser/tea/HttpTrackInit` pins it.
- **A tracked request starts after the untracked requests of its batch** ((c)'s amendment). elm/http
  2.0 starts them in the batch's order.

**(g) The proof.** `browser/tea/HttpTrack` pins (b) and (c): a subscription that the click's
`update` declares, a subscription that an answer's `update` declares (in a drain), two declarations
of one name, a name that hears nothing, an untracked `send`, a name with no subscription, and a failed
request. Each value comes before its answer, a 204's too, whose null body leaves no wait between
the last value and the answer. The page runs as a development, a release and a `--fiber-page` build
against one golden. `browser/tea/HttpRequestShape` pins (a)'s credentials: `send` sends
`same-origin` and `riskySend` sends `include`.

*Amended 2026-10-14 (review of PR #97):* more proofs. `HttpTrack` also pins a `track` that has left
and hears nothing of a later request of its name (`#again`), the order of (c)'s amendment
(`#batch`), and a 404 that reports every value before its `BadStatus` (`#missing`). A closed relay
(§9.8.5) drops a value for a key that has left, so `#again` holds even if the table keeps the old
listener: the table's delete keeps memory bounded, and no transcript sees it.
`browser/tea/HttpTrackInit` pins a tracked command from `init`, an empty body's two `Sending 0/0`,
and a tracked request that times out after its first value. `HttpRequestShape` pins the credentials
of a tracked `send` (`same-origin`) and a tracked `riskySend` (`include`); with `same-origin` in the
`Just` arm, it fails. `emit/release/tea/HttpSendUntracked` and `HttpSendTracked` pin (e)'s release
shapes.

*As built, 2026-10-14* (`platforms/browser/Http.beni`, beni over `Js` with no `foreign`), as
specified. **Each wait is pinned**: with one taken out, `HttpTrack` fails. Without the render wait,
`#chain`'s first `Sending` is lost; without the first yield, `#upload`'s; without both, both; and
without the last yield, the 204's last two values come after its answer. **Measured** (`--release`,
brotli 11, the whole output): `browser/tea/ValueCommands`, whose `send` has no tracker, 16 986 →
16 992 bytes raw and 6 437 → 6 457 brotli — the same code in another module order, and one dead
6-byte binding the release optimiser leaves where it folds the untracked arm. The same page with
`tracker = Just "post"` and an `Http.track` subscription is 20 989 raw and 7 811 brotli: the listener
machinery every `Sub.on` page shares, the chunked read, the table and the waits. Its `Maybe` keeps
integer tags. No page of `bench/size.mjs --pages-only` moved by a byte, dev or release, `browser-tea
http` and `ApiAndRoutes` among them.

#### 9.8.20 Pointer input (2026-10-20)

*Added 2026-10-20* (issue #525). Normative for the pointer events of the `html` vocabulary and for
what a handler reads of them. A browser game steers by the mouse or by a finger, and before this
section a page could not read where the pointer is: `onMouseMove` handed an `Event` with no reader
of its position, and nothing handed a touch.

**(a) Pointer Events, and not mouse and touch events.** One event model serves the mouse, the pen
and the touch screen, in every current browser (Chrome 55, Firefox 59, Safari 13). Each pointer has
an identity, `pointerId`, so two fingers are two pointers, and the browser sends `pointercancel`
when it takes a pointer for itself. Touch events (`touchstart`, `touchmove`, …) hand a list of
touches per event, serve no mouse, and are passive by default on the window, the document, the
document element and the body (DOM, *default passive value*), so a page would need two APIs to do
what one does. The mouse
events stay as they are (§9.9 (c)). **The model**: elm/html has no pointer events, and the package
Elm programs use is mpizenberg/elm-pointer-events (`Html.Events.Extra.Pointer`), whose `onDown`,
`onMove`, `onUp`, `onCancel`, `onEnter` and `onLeave` hand a decoded record with the pointer's id,
type and positions. beni names each event as its vocabulary names every event (`onPointerDown`),
and each reader as the DOM names the property it reads.

**(b) The API.** `Html`, the vocabulary module, gains:

| | Is |
|---|---|
| `onPointerDown`, `onPointerMove`, `onPointerUp`, `onPointerCancel`, `onPointerEnter`, `onPointerLeave` | the DOM event of the lower-cased name, `via pointer : Pointer`, **not** `delegated` |
| `Pointer` | `pub crossing foreign type`: the event, and its position in its handler's element, made by the extractor `pointer`, (d) |
| `pointerId : Pointer → Int` | the pointer's identity, the same from its `pointerdown` to its `pointerup` or `pointercancel` |
| `pointerType : Pointer → String` | `"mouse"`, `"pen"` or `"touch"`; `""` when the browser cannot say |
| `isPrimary : Pointer → Bool` | the mouse, or the first finger of a touch |
| `clientX`, `clientY : Pointer → Float` | the position in the viewport, CSS pixels |
| `localX`, `localY : Pointer → Float` | the position in the handler's element, (c) |
| `pointerEvent : Pointer → Event` | the same event as an `Event`: the modifier readers and `preventDefault` take it |

`pointerover`, `pointerout`, `gotpointercapture` and `lostpointercapture` wait for a use, as the
drag events that no program has needed do (§9.8.10, *amended 2026-10-13*). So do the pen's pressure
and tilt, `getCoalescedEvents()` (the points between two `pointermove`s, which a drawing page needs
and a game that reads one point per frame does not) and `pointerrawupdate` (no Safari).

**(c) The coordinate system.** `localX` and `localY` are CSS pixels from the top-left corner of the
**border box of the element whose handler runs**: the element that carries `onPointerMove`, not the
innermost element under the pointer, such as a dot drawn inside the arena. Each is `clientX −
getBoundingClientRect().left` (and `top`), read while the event is dispatched. So a page whose
arena is laid out at `width: 600px` reads arena coordinates directly. A page that scales its arena
— an SVG `viewBox`, a width in percent — multiplies by its own units per pixel, and can read the
box's size with `Dom.box` (§9.8.6). Under a CSS `transform` other than a translation, the box is
the bounding box of the transformed element, so the point is in that box and not in the element's
own frame. A point outside the box is a value like any other: a touch has implicit capture, so its
moves go to the element where it started, wherever the finger is, and `localX` can be negative.

Two consequences of the border box. An absolutely positioned child is placed from its parent's
**padding** box, so on an arena with a border, a dot drawn at `left: localX` is one border width
off: a page with a bordered arena subtracts the border, or puts the border on a wrapper. And on an
arena that scrolls itself (`overflow: auto`), the point is in the visible box, not in the scrolled
content: the page adds its own scroll offset.

`clientX` and `clientY` are the viewport's coordinates. There is no `offsetX`: the DOM measures it
from the padding edge of the event's target, the innermost element, which is the wrong element for
a surface with children. `pageX`, which adds the scroll, and `screenX` wait for a use.

**(d) Why a `Pointer`, and why the pointer events are not `delegated`.** The position needs the
handler's element. While an event is dispatched, `currentTarget` is that element only when the
listener is on the element itself. The `dom` lowering's delegated listener is on the document
(`backend.md` §15.3, *Events*), so under it `currentTarget` is the document. This section **chooses**
not to delegate the pointer events: `dom` attaches one listener to each element that has a pointer
handler, through the runtime's `listen`, and `browser-inline` attaches every listener to its element
already (its runtime's `on`, `platforms/browser-inline/Inline.beni`). The other choice is Solid 2's:
it delegates `pointerdown`, `pointermove`, `pointerover`, `pointerout` and `pointerup`, and during
its walk redefines `currentTarget` as the walk's node (dom-expressions
`packages/runtime/src/constants.js`, `client.js`). beni's `fire` has that node too.

**A known gap of the choice** (issue #557): each listener of one trusted event is its own turn
(`backend.md` §15.11), so a user's `pointerdown` on an element inside another that also has
`onPointerDown` renders between the two handlers, and the outer one runs with the handler that the
first render wrote. A delegated event's walk is one turn and one render. The `.steps` step sends
untrusted events, which are no turn, so no fixture sees the difference yet. #557 takes Solid's
choice, or specifies the turn per listener.

The position is taken by `pointer`, the events' extractor and a `foreign` of `Html` (§9.3), while
the event is dispatched. After the dispatch `currentTarget` is null and the box can have moved, so
a reader that ran later — in `update`, on a `Pointer` that a message carries — would read nothing,
or a wrong box. **No program can call `pointer`**: on another event, such as a delegated `onClick`
under `dom`, the element would be the document, which has no box. Its type is `pointer : Dispatched
→ Pointer`, and `Dispatched` is a `foreign type` of `Html` that is not `pub`: no event hands one to a
handler and no function returns one. `pointer` itself is `pub` until issue #532 is fixed: today the
lowering finds an extractor in the vocabulary module's interface, which holds only `pub` values, and
a non-`pub` extractor is accepted by the checker and then replaced by the raw event.

**A lowering's obligation.** The pointer events are not `delegated`, so a lowering calls their
extractor **synchronously, in the listener of the element that has the handler, while the event is
dispatched**, and `currentTarget` is that element (§9.3, amended here). `dom` does: `listen`'s
listener calls `fire`, which applies the extractor before it computes the message. `browser-inline`
does on its usual path, but a send made while another send runs is queued with its raw event, and
the extractor would run after the dispatch (issue #559; latent, because a host never dispatches a
pointer event inside a send). **The type is the guarantee**, given that obligation: a `Pointer`
comes only from the listener of a pointer event on its own element, so `localX` of every `Pointer`
is a point in its handler's element, under every lowering and at any time after. The other readers
read properties of the event, which do not change after the dispatch. **The second wall is `Js`**:
`Js.to : Value → a` can make a value of any type, so a package that may import `Js` can make a
`Dispatched` and call `pointer` on any event. A program cannot import `Js` (`js_outside_platform`,
§4.2), so only a platform package can, which is the trust every `foreign` has (rule 6).

The cost is one listener for each element that has a pointer handler, not one for each page: a
`For` of a thousand rows with a pointer handler on each row attaches a thousand listeners. A game
surface is one element. A delegated form waits for a page that needs it and a measurement (rule 8).
The extractor also reads the element's box on every event. **Measured** (2026-10-20, the review of
PR #548: headless Chrome, synthetic `pointermove` on an arena, the median of 5 × 2 000 events, µs per
event):

| arena | layout before the event | read `clientX` only | the extractor | read `offsetX` |
|---|---|---|---|---|
| 20 absolute children | clean | 5.6 | 7.1 | 6.7 |
| 20 absolute children | one child moved | 6.6 | 69 | 65 |
| 1 000 absolute children | clean | 4.2 | 6.3 | 5.1 |
| 1 000 absolute children | one child moved | 6.5 | 1 075 | 1 172 |
| 1 000 in flow | width changed | 5.6 | 886 | 898 |
| 5 000 in flow | one child moved | 8.4 | 6 762 | 6 500 |

On a clean layout the extractor adds 1.5 to 4.5 µs. On a changed layout it forces the layout, as
`offsetX` does: any point in an element's box needs one, so a delegated handler that reads the box,
as Solid's would, pays the same. Chrome dispatches `pointermove` once per frame, before the
`requestAnimationFrame` callbacks, so a steady single pointer reads the layout that the last frame
made. A forced layout comes with a second pointer event in one frame after a render that changed the
layout: a second finger, or a `pointerdown` and then a `pointermove`. On a 1 000-element arena that
is about 1 ms for each such event. The cost is accepted: it is the price of a point that stays right
after the dispatch.

**(e) The browser's own gestures.** A page stops scrolling, pinch zoom and double-tap zoom on its
game surface with CSS: **`touch-action: none`** in the element's `style`, an ordinary attribute
(`language.md` §11.19). That is the Pointer Events standard's way, and the only one that works. The
browser decides on a gesture at the `pointerdown`, from `touch-action`, before any listener can
answer, and `preventDefault` on a pointer event never stops a scroll or a zoom (Pointer Events
§4.1.3.1). One exception is known: on iOS, `touch-action: none` does not stop a double-tap zoom on
an absolutely positioned element (WebKit bug 218015, open). On a `pointerdown`, `preventDefault`
stops the compatibility mouse events `mousedown`, `mousemove` and `mouseup` until that pointer's
`pointerup` or `pointercancel` (Pointer Events §11.2), and never `mouseover`, `mouseout`,
`mouseenter`, `mouseleave`, `click`, `auxclick` or `contextmenu`. `Html.preventDefault
(Html.pointerEvent p)` does it, as for any event. When the browser does take a gesture — on an
element with no `touch-action: none` — it sends `pointercancel`, then `pointerout` and
`pointerleave`, and nothing more of that pointer, so a game ends a pointer's steering on
`onPointerCancel` as on `onPointerUp`, and an `onPointerLeave` hears a leave after each cancel.

The runtimes register their listeners with no options. A browser makes a listener passive by
default only for `touchstart`, `touchmove`, `wheel` and `mousewheel` on the window, the document,
the document element or the body, so a pointer handler's `preventDefault` is never ignored.
`user-select: none`, also CSS, keeps a long press from selecting text; Safari and iOS Safari need
`-webkit-user-select: none` beside it, and iOS needs `-webkit-touch-callout: none` to stop the
long-press menu. **Pointer capture** (`setPointerCapture`) is not exposed: a
touch is captured by the element where it started, which is what a surface needs, and a mouse that
leaves the surface sends `onPointerLeave`. Explicit capture waits for a use; it can throw
`NotFoundError` and `InvalidStateError`, so it will return a `Result` (rule 9).

**(f) Rules 7 and 8.** Nothing is refused: a page can use the mouse events, the pointer events or
both, on any element. A page that does not use the pointer events pays nothing: the vocabulary's
declarations carry no JavaScript (§9.3), and reachability (`backend.md` §9) and the release
minifier's export pruning remove the readers and the extractor when no handler reaches them.

**(g) Proofs.** The `.steps` language gains `pointer`, a pointer event at a point given in an
element's box (`tests/corpus/README.md`). Under happy-dom, which has no layout, every box is at 0,
so only Chrome (`zig build test-browser`) shows the conversion of (c); a step names its point in
the box of the handler's element, so both DOMs print the same transcript. That step is neither a
gate nor a CI job, so today no automatic check sees the conversion (issue #558). `browser/tea/PointerInput`
pins movement, up, cancel, enter and leave, identity and type, `preventDefault`, a handler on an
element with a child (the box is the handler's, not the target's), a `Pointer` read in `update`
after its dispatch, and a handler that the view changes in place. `browser/dom/PointerEvents` pins
the same under `browser`. `browser/tea/PointerSteer` is the demonstration: a dot steered toward the
pointer by animation frames. `check/bad/markup/PointerExtractor` and `PointerExtractorType` pin (d):
a program that hands `pointer` an `Event` is refused, and so is one that names `Dispatched`.

*As built, 2026-10-20* (`platforms/html/Html.beni` and `Html.js`, `tests/browser/driver.mjs`), as
specified, with these findings:

- **The extractor is `pub`**, as (d) says. A non-`pub` `via` is accepted by the checker, and the
  lowering then hands the handler the raw event (issue #532).
- **Measured** (`bench/size.mjs --pages-only`, the compiler before and after this change): every
  release figure is the same, and TodoMVC's release file is the same bytes. Every page that reaches
  no `foreign` of `Html` is the same in development too. TodoMVC and Conduit reach `targetValue`, and
  a development build copies the sibling file whole, with the new export and its comments: 523
  bytes raw more in TodoMVC (measured), and the same file in Conduit. `examples/steer`, the demonstration, is 10 800 bytes raw
  and 4 267 brotli under `--release`.
- **The extractor's key is `ev`, not `e`.** A first version returned `{ e, x, y }`. The release
  minifier keeps the spelling of a name that stands where a property name can, anywhere in the file
  (`src/js/Minify.zig`, *A2*), so the parameter `e` of `targetValue` and `targetChecked` kept its
  name, and TodoMVC's release file changed.
- **`browser-inline`** needed no change. It compiles neither a `style` attribute nor a lambda
  handler yet (`browser-inline.md` §5), so `browser/inline/PointerPoint` has constructors as its
  handlers and no style.
- **`Html.Pointer` is `crossing`**, as `Html.Event` is, and `tests/corpus/ownership/
  trusted-surface.txt` lists it: without the word, `ownership/WordsBrowser`'s summary of `update`
  has the `Pointer` of a message escape.
- The page fuzzer sends no pointer events yet (issue #527). The trusted path of nested handlers
  (#557) and the conversion under the gates (#558) have issues of their own.
- **Reviewed** (PR #548): the facts of (a) and (e) were checked against Pointer Events level 3, the
  DOM Standard and MDN's compatibility data, and four were corrected — the events after a
  `pointercancel`, the mouse events a prevented `pointerdown` stops, Safari's `user-select`, and
  iOS's double-tap zoom.

### 9.9 SVG in the `html` vocabulary (2026-10-12)

*Specified and built 2026-10-12.* The language could mark an element `svg` (`language.md` §11.14) and the
`dom` lowering knew the namespace (`backend.md` §15.3's flag `2`), but no platform declared an SVG element,
so no program could draw. This section is the contract for SVG markup: which module declares it, how its
names meet HTML's, how an element gets its namespace on the page, and what each lowering writes. The house
rule is Elm's API: the vocabulary covers elm/svg's `Svg`, `Svg.Attributes` and `Svg.Events`, everything
ohanhi/bike-wars draws with among them.

**(a) One vocabulary module: `Html`.** The SVG elements, attributes and events are declarations of
`platforms/html/Html.beni`, beside HTML's, and there is no `Svg`, `Svg.Attributes` or `Svg.Events` module.
Four reasons, each sufficient:

1. **A tag resolves in one vocabulary with no import** (`language.md` §11.5, §9.2's `"vocabulary"` key):
   `<rect>` in any view must find its row in the module the manifest names. A second module would make the
   key a list and the checker merge rows across modules — a language change bought for a module name.
2. **beni already folded elm/html's three modules into one**: an element, an attribute and an event are
   declarations, not functions, so `Html.Attributes` and `Html.Events` have nothing to hold. SVG's are the
   same kind of thing.
3. **The two vocabularies nest in each other**: an `<svg>` inside a `<div>`, a `<p>` inside a
   `<foreignObject>`, `onClick` on both. One module types them together.
4. **SVG markup is `Html msg`**, as Elm's `Svg msg` and `Html msg` are both `VirtualDom.Node msg`: a view
   that draws is annotated `Html Msg`, a component that returns a `<circle>` is a component like any other,
   and `Html.map` and `Html.text` work on SVG unchanged. **JSX and the plain-call form produce the same
   type** (rule 8): `<Shapes.dot cx="4" />` and `Shapes.dot { cx = "4" }` are one program (§11.13), and an
   element has no plain-call form for SVG for the reason it has none for HTML — a tag chosen at run time
   waits on `language.md` §11.5's design. Elm's `Svg.node`, `Svg.text_` and `Svg.text` are therefore
   `<…>`, `<text>` and `Html.text`.

**(b) Names are SVG's, spelled as the page spells them.** As HTML's vocabulary declares `tabindex` and not
Elm's `tabindex` function, SVG's declares the markup name: `stroke-width` (Elm's `strokeWidth`),
`viewBox`, `xlink:href`, `<text>` (Elm's `text_`), `<linearGradient>`. **Case is kept and matched exactly**:
`viewbox` is `unknown_attribute` with "did you mean `viewBox`" — exact matching is §11.5's rule, and here it
also buys a guarantee, since `setAttribute("viewbox", …)` on an SVG element writes an attribute no renderer
reads. **Every SVG attribute's value is a `String`**, as every elm/svg attribute takes one: a length may
carry a unit (`"50%"`, `"2px"`), so `width="100%"` on an `<svg>` is a string where HTML's `width` on an
`<img>` stays an `Int`.

**(c) Collisions with HTML, decided one by one.**

| Name | Decision |
|---|---|
| elements `a`, `title`, `style` | **one declaration each, HTML's.** Inside an `<svg>` the page's parser makes the SVG element of the name (d), so `<svg><a href="…"><text>…</text></a></svg>` is SVG's link and `<title>` SVG's tooltip; the attributes are typed against the one row (`a`'s `href` is a `url`, and `xlink:href` is declared on `a` too) |
| `width`, `height` | **a second declaration**, `String`, `on` the SVG elements that have them (`svg`, `rect`, `image`, `foreignObject`, `use`, `pattern`, `mask`, `filter`, `symbol`, the filter primitives), beside HTML's `Int` one on its elements. The `on` sets are disjoint, so no name has two answers (`language.md` §11.14) |
| `class`, `style`, `id`, `tabindex`, `lang` | **HTML's declarations serve SVG**, every lowering writing them as attributes: `class` is `setAttribute("class", …)` — never `className`, which is an `SVGAnimatedString` on an SVG element — and the class and style lists use `classList` and `style.setProperty`, which SVG elements have (`language.md` §11.19) |
| `href` | SVG's is declared `url` on `use`, `image`, `pattern`, the gradients, `textPath`, `mpath`, `feImage`, `filter` and the animation elements; `a` keeps HTML's. **`xlink:href`** is declared `url` on the same elements and `a`, and is written with `setAttributeNS` in the XLink namespace (`backend.md` §15.3's existing row) |
| `type`, `min`, `max`, `method`, `x`, `y`, … | **a declaration `on` the SVG elements that have the attribute**, so `type` on `feColorMatrix` is SVG's and on `input` HTML's; `x` and `y` are SVG's only |
| presentation attributes (`fill`, `stroke`, `stroke-width`, `transform`, `opacity`, `font-size`, …) | **declared for every element**, as every elm/svg attribute may be put on any node. The cost is that `<div fill="red">` checks and writes an attribute nothing reads; no guarantee is at stake (rule 7) — the name is not a typo, the attribute is written, the page shows what it would show — and an `on` list of every SVG element on each of fifty-six attributes would more than double the vocabulary's text. A fact meaning "on every element declared `svg`" would make them exact; it is a change to §11.14's fact set and is left for when a misuse is reported |
| events | **HTML's serve SVG**: elm/svg's `Svg.Events` is `onClick`, `onMouseDown`, `onMouseUp`, `onMouseOver` and `onMouseOut`, and the last two are added to the vocabulary for both, `delegated` since both bubble, with `onMouseMove`, which a drawing needs and Elm writes with `on "mousemove"` |

**(d) The namespace is the parser's, decided by where an element stands.** Every lowering writes markup as
text the page's HTML parser reads — a template's `innerHTML`, a server render — and that parser, not the
name, decides an element's namespace: inside an `<svg>` it is in **foreign content**, where every element
it makes is an SVG element, until an **HTML integration point** (`foreignObject`, `desc`, `title`) whose
content is HTML again. So:

- **Inside one template, nothing is created by name**: no `createElementNS`, no namespace argument; the
  `<svg>` the template holds puts everything under it in its namespace, as dom-expressions relies on.
- **At the top of a template**, an element declared `svg` other than `<svg>` is wrapped in an `<svg>` for
  the parser and taken out of it at clone (`backend.md` §15.3's flag `2`, now also with flag `4`: a value
  of several top-level nodes among which an SVG element stands is wrapped whole and its nodes returned in a
  fragment). A component that returns a `<circle>`, a `For` row that is a `<rect>`, a helper that returns
  `<><line /><text>…</text></>` all draw.
- **The parser table learns foreign content** (§9.3's *Where HTML's parser rules live*;
  `parser_table.zig`'s `Scope.svg`, `misplaced`, `contentIn`). Inside an `<svg>` none of HTML's rules apply —
  no void element, no raw text (`<style>` and `<title>` are SVG's, whose text is ordinary and escaped), no
  `<p>` closing, no table — and an element is **`markup_restructured`** where its namespace would not be
  the one its declaration says: an SVG element outside any `<svg>`, or inside a `<foreignObject>`'s HTML,
  which the parser would make an HTML element that draws nothing; an HTML element inside an `<svg>`, which
  the parser would make an SVG element of the name or, for most of HTML's phrasing and block elements, end
  the `<svg>` before (`a`, `title`, `style` and `script` excepted: names of both); and, in `dom`, an SVG
  element beside an HTML one at the top of one markup value, which one template cannot parse in both
  namespaces. Each was a page that silently differed from the program; Solid's compiler writes them all.
- **What the parser table cannot see**, a markup value placed in a slot at run time, keeps the namespace
  its own template gave it, as an Elm `Svg` node keeps its own: an HTML block in a slot inside an `<svg>`
  is an HTML element there. An `<a>` or `<title>` at the **top** of a markup value is HTML's (its
  declaration's namespace), so a component returning `<a>…</a>` for use inside a drawing writes it inside a
  `<g>`; a namespace taken from the slot a value lands in waits on a use that needs it.

**(e) Attributes are attributes.** No SVG attribute is declared `property`: every value class is written
with `setAttribute` (`removeAttribute` for a `Bool` or `Maybe String` that is absent), `xlink:` and
`xml:` names with `setAttributeNS` — `backend.md` §15.3's table, which needed no change. A constant is
baked into the template as written, the parser restoring the case of a mixed-case name in foreign content
and putting `xlink:href` in its namespace.

**(f) Per lowering.** `dom` (`browser`, and `browser-tea` over it): (d) and (e), no runtime change —
`Rt.template` already unwrapped flags `2` and `2|4`. `ssr` (`node`): the same parser-table rules, an SVG
element at a root written as itself (the string is placed inside the `<svg>` the page's string holds), names
and case as declared, `xlink:href` written as written. `direct` (`browser-direct`): a `For` row whose root
is an SVG element compiles, its template taken from inside the wrapper (`t.content.firstChild.firstChild`);
a `view` whose root is an SVG element other than `<svg>` stays refused until slice S4
(`browser-direct.md` §14) — a page's root is mounted into the page's mount node, an HTML element, where such
an element draws nothing, so S4 needs a mount node that may be an `<svg>` (`Browser.mountAt` on one) before
it is worth compiling.

**(g) What is included, and what is deferred.**

- **Elements** (58): `svg`, `foreignObject`, `circle`, `ellipse`, `image`, `line`, `path`, `polygon`,
  `polyline`, `rect`, `use`, `animate`, `animateMotion`, `animateTransform`, `mpath`, `set`, `desc`,
  `metadata`, `defs`, `g`, `marker`, `mask`, `pattern`, `switch`, `symbol`, `textPath`, `text`, `tspan`,
  `linearGradient`, `radialGradient`, `stop`, every filter primitive and light source elm/svg has
  (`feBlend` … `feTurbulence`, `feDistantLight`, `fePointLight`, `feSpotLight`), `clipPath`, `filter`,
  `view`; and `a`, `title`, `style` through HTML's rows (c).
- **Attributes** (169 declarations): the 56 presentation attributes, and elm/svg's geometry, text, reference, marker, gradient,
  pattern, clip, mask, filter-primitive and animation attributes, each `on` its elements.
- **Events**: `onMouseOver`, `onMouseOut`, `onMouseMove` added; the rest are HTML's.
- **Deferred, each for want of a use, none refused**: what SVG 2 removed and browsers do not draw — fonts
  and glyphs (`font`, `glyph`, `altGlyph*`, `glyphRef`, `tref`, `color-profile`, `cursor` the element) and
  their attributes (`horiz-adv-x`, `unicode`, `glyph-name`, `v-*`, `kerning`, `enable-background`, …),
  `animateColor`, `xlink:` attributes but `href`, `xml:base`/`lang`/`space`, `requiredFeatures`,
  `externalResourcesRequired`, `baseProfile`, `version`, `zoomAndPan`; and `systemLanguage` and
  `requiredExtensions` (a `<switch>` draws its first child without them). elm/svg's `Svg.Events.on`,
  `custom`, `preventDefaultOn` and `stopPropagationOn` are HTML's open question too — a handler takes an
  `Event` and reads it (§9.8.10). MathML stays undeclared: its foreign-content rules are (d)'s, with
  `mi`, `mo`, `mn`, `ms`, `mtext` and `annotation-xml` as its integration points, written when its
  vocabulary is.

**(h) What it costs.** A page without SVG does not move a byte: no runtime changed, and every `emit/`
golden and `run/` record is what it was. A markup program reads a vocabulary of 410 declarations where it
read 180, and **pays for it linearly**. Two quadratic costs were found and removed. The type table gave every
element, attribute and event declaration an entry, as if it were a `foreign type` named `rect` or `onClick`,
and settling each entry scanned its module for a `pub compare` — 410 × 410 in `html`, `Types.build` going
from 2.5 to 8.3 ms with SVG declared; vocabulary declarations now name no type, and it takes 1.4 ms, less
than before SVG. And the duplicate-declaration check of `checker-v2.md` §25.2 compared every pair of
declarations by text; it compares two exact names by their interned symbol. What remains is the larger
module loaded, resolved and digested: about 4 ms of CPU across the worker threads in the ReleaseSafe
compiler on `browser/dom/Events` (minimum of 30 runs, warm cache), mostly in parallel with other modules,
leaving the check's wall time within the noise of the compiler before SVG.

### 9.10 The `node` platform serves HTTP (2026-10-17)

*Added 2026-10-17, for issue #331. Status: normative for the first slice, the basics. The owner
took the three decisions of #331 on 2026-10-17 (dashboard `node-http-q1` to `q3`, recorded in
(i)): a defect in a handler stops the process, the server lives in the `node` platform, and the
API shape below is the contract.* The `node` platform gains one module,
**`Http.Server`** (`platforms/node/Http/Server.beni`, its sibling `Server.js`). It wraps
`node:http`'s server as `Io.readFile` wraps `fs.promises.readFile` (§4.1, `CLAUDE.md` rule 9):
each failure Node documents is one constructor of a typed error, a cancelled fiber releases what
it holds, and any other error is thrown again and is a defect.

**(a) The API.** A program listens on an address and hands the platform one function. The
platform calls it once per request, in a fiber of its own, and writes what it returns.

```elm
module Http.Server

pub type alias Address =
    { host : String      -- what Node's `listen` takes as `host`: "127.0.0.1", "::1", "localhost", "0.0.0.0"
    , port : Int         -- 0 lets the operating system pick one; `address` reports it
    }

pub type ListenError
    = AddressInUse          -- EADDRINUSE
    | PermissionDenied      -- EACCES: a port under 1024 without the privilege
    | AddressNotAvailable   -- EADDRNOTAVAIL: no interface has that address; EAFNOSUPPORT: its family is off
    | HostNotFound          -- ENOTFOUND, EAI_AGAIN, EAI_FAIL: `host` is a name the resolver cannot answer
    | TooManyOpenFiles      -- EMFILE, ENFILE: no file descriptor to spare, as `Io.FileError` names it
    | InvalidPort           -- `port` is not an integer from 0 to 65535; checked in beni, Node is not called

pub type alias Request =
    { method : String                   -- as Node gives it, upper case: "GET", "POST", …
    , path : String                     -- the request target as sent: "/items?limit=3"
    , headers : List (String × String)   -- names in lower case, in the order sent, duplicates kept
    , body : String                     -- the whole body as UTF-8 text; "" when there is none
    }

pub type alias Response =
    { status : Int                      -- an integer from 200 to 999; 204, 205 and 304 take an empty body
    , headers : List (String × String)   -- written in this order, before Node's own
    , body : String                     -- written as UTF-8; the platform writes its `content-length`
    }

pub opaque type Server                  -- a handle; every operation on a closed one is total

pub listen : Address, (Request → Response) → Result ListenError Server   -- suspends until bound or refused
pub address : Server → Address          -- the address Node bound: `port` is the one it picked for 0
pub close : Server → ⊤                  -- stop accepting; returns at once; a second call does nothing
pub wait : Server → ⊤                   -- suspends until the server has closed and every response is written

pub text : Int, String → Response       -- `content-type: text/plain; charset=utf-8`, no other header
pub header : Request, String → Maybe String   -- the first value of that header; the name's case does not matter
```

The canonical program. `Io.run`'s fiber calls `listen`, waits, and ends when the server has
closed. A handler stops the server through a `Deferred`, as any fiber stops another; nothing in
the API is a second way to do it:

```elm
main : Program
main = Io.run λ⊤ →
    stop = Deferred.make ⊤
    case Server.listen { host = "127.0.0.1", port = 8080 } (handle stop _) of
        Err error →
            Node.exitWith (describe error) 1

        Ok server →
            Deferred.wait stop
            Server.close server
            Server.wait server
            Node.print "stopped"


handle : Deferred ⊤, Request → Response
handle stop request =
    case request.path of
        "/stop" →
            _ = Deferred.complete stop ⊤
            Server.text 200 "stopping"

        _ →
            Server.text 404 "no such page"
```

**(b) The lifetime: the fiber that called `listen` owns the server.** `listen` starts the
server's accept loop in a child fiber of the caller (`Task.spawn`), and each request's handler
runs in a fiber of a `Task.scope` that loop holds. So:

- `listen` returns only once the loop's fiber has parked on its first wait, so from the moment
  a program holds the `Server`, a cancellation of the owner, or its end, reaches the loop's
  canceller: a program that returns right after `listen` serves nothing and ends, and never
  leaves a bound socket keeping the process alive (`HttpServerOwnerEndsAtOnce`). A cancellation
  that arrives between the bind's answer and the owner's next run is latched, as every
  interrupt to a ready fiber is (`transparent-effects-proposal.md` §16.4), and delivered at that
  wait, after the loop's fiber — queued first — has parked: no gap is left.
- When the owning fiber ends, or is cancelled, the loop fiber is cancelled with it. The
  cancellation calls the loop's wait canceller, which **destroys every open connection and closes
  the listening socket at once**, then the scope cancels every handler fiber still running and
  waits for its cleanup (§17.1 item 2 of `transparent-effects-proposal.md`). Nothing keeps the
  process alive afterwards. A response a cancelled handler would have written is not written: its
  connection is gone.
- `close` is the graceful path. It stops accepting, closes the connections that are idle, and
  returns at once. A handler that is running finishes and its response is written. **A response
  written after `close` carries `connection: close`**, and the connection ends with it, because
  Node leaves a busy keep-alive connection open after `server.close()` (measured, Node 24.19: the
  connection served a third request after `close`). `wait` returns when Node reports the server
  closed, which is after the last of those responses. A handler may call `close`: it does not wait
  for itself, so there is no deadlock, and its own response is the last on its connection.
- `close` on a closed server does nothing, `wait` on one returns at once, and `address` on one
  returns the address it had. That is the W52 rule for a handle (§9.8.9): every operation is
  total on a closed one, so a program may keep a `Server` anywhere.
- `Io.run` ends the program when its fiber ends (§9.8.15 (c)), and `Task.shutdown` then cancels
  what still runs. A program that returns from `Io.run`'s body right after `listen` therefore
  serves nothing: it must `wait`, or wait on something else.

**(c) A request.** The platform waits for the whole request, headers and body, before it calls
the handler. It builds `Request` from Node's `IncomingMessage`:

- `method` is `req.method`; Node's parser accepts only the methods of `http.METHODS` and answers
  any other with 400 itself, so the string is one of those.
- `path` is `req.url`, the request target as sent. The platform does not parse it; core's `Url`
  does, when the program wants its parts.
- `headers` come from `req.rawHeaders`, two entries at a time, each name lower-cased. Duplicates
  stay separate and in order, so a program sees every `set-cookie`. `header` looks the first one
  up by its lower-cased name.
- `body` is every chunk concatenated and decoded as UTF-8. An invalid sequence decodes to U+FFFD,
  as `TextDecoder` does with `fatal: false`; a body is text in this slice, and a body that is not
  text is a later slice's (streaming and bytes, #335). **A size limit is owed** (#336): one large
  body can exhaust the process today. By rule 7 it will be a setting of the server with a
  default, and a request over it answered with 413 before the handler runs — never a fixed
  refusal.

A request whose body does not arrive whole never reaches the handler: the client closed the
connection first (`req` emits `aborted`, then `error` with `ECONNRESET`). The platform handles
exactly that code on `req` and drops the request. There is no one to answer, and the program
does not see it. A request Node's parser refuses (a malformed line, a header block over
`maxHeaderSize`, a request that took longer than `requestTimeout`) is Node's `clientError`, and
the platform leaves Node's default handling in place: Node answers 400, 431 or 408 and closes the
connection. The program does not see those either. Four events of the server have no listener,
so Node's default stands (measured): a request with `Expect: 100-continue` is answered
`100 Continue` and then reaches the handler whole (`checkContinue`); any other `Expect` is
answered 417 by Node (`checkExpectation`); a `CONNECT` request's socket is destroyed, with
nothing written (`connect`); a request with an `Upgrade` header is an ordinary request, which
reaches the handler with that header (`upgrade`). Node's timeouts keep their defaults
(`headersTimeout` 60 s, `requestTimeout` 300 s, `keepAliveTimeout` 5 s).

**(d) A response.** When the handler returns, the platform writes the status, the program's
headers in order, then `content-length` as the byte length of the UTF-8 body (except on 204, 205
and 304, below), and ends the response with the body. The headers go to `writeHead` as one flat array of names and values, so
**a name given twice is written twice**, in order — two `set-cookie` headers arrive as two
(measured); `setHeader`, which keeps one value per name, is not used. After `close`, a
`connection` header of the program's, in any case, is dropped and the platform's
`connection: close` is written in its place, on a 500 as on any response ((b)): the graceful path
cannot be undone by a handler. Node adds `date` and, where the program set none, its `connection`
and `keep-alive` headers, each after the program's (measured). For a `HEAD` request Node sends the
headers and no body. The platform never streams: one response, one write.

A `Response` the platform cannot write as it is, is **invalid**. Every check runs **before any
header is set and before the first byte is sent**, so a fault leaves nothing behind, and no
`try` wraps the handler's call, `writeHead` or `end`: an error from those is a defect.

| The fault | How it is found |
|---|---|
| `status` is not an integer from 200 to 999 | the sibling's own test, Node's rule for `writeHead` (`ERR_HTTP_INVALID_STATUS_CODE`) less the interim statuses: a handler answers once, and Node resets the connection on a final `100` (measured) |
| `status` is 204, 205 or 304 and `body` is not `""` | the sibling's own test: those statuses carry no body (RFC 9110). Node drops it for 204 and 304 and writes it for 205 (measured), which a client may misparse |
| a header name is not a token | `http.validateHeaderName` throws `ERR_INVALID_HTTP_TOKEN`, a `TypeError`; caught from that call alone |
| a header value holds a character Node refuses (CR, LF, NUL, a control character) | `http.validateHeaderValue` throws `ERR_INVALID_CHAR`, a `TypeError`; caught from that call alone |
| a header named `content-length` or `transfer-encoding`, in any case | checked by name in the sibling; the transport owns both |

The sibling catches exactly those two codes, from those two calls, and nothing else; the
`ERR_HTTP_INVALID_HEADER_VALUE` of `validateHeaderValue` cannot happen with a `String`, and
`ERR_HTTP_HEADERS_SENT` cannot happen with one write. **An invalid response is answered with
`500`, `content-length: 0`, an empty body and no header of the program's**, and the sibling
writes one line to standard error: `beni: Http.Server: the response to GET /x is invalid: status 1000 is not an
integer from 200 to 999`. It is not a defect: the handler returned a value of the right type, the
client gets a well-formed answer, and the server stays up. It is not silent either. The two
headers belong to the transport because a wrong one hangs the client: a `content-length` under
the body's length left the client waiting for the rest, and one over it broke the client's parser
(measured). For 204 and 304 the platform writes no `content-length`, and Node adds none; for 205
it writes `content-length: 0`, because Node would otherwise send an empty chunked body
(measured), which RFC 9110 allows and clients handle less well.

**Why this path is not a defect, against decision 1.** (f) is for a throw the platform did not
anticipate: an unknown error, whose effect on the process is unknown, so the process stops. An
invalid `Response` is a value of the right type that the platform anticipated and refuses before
it writes: the fault is named, its effect is one 500, and the server's state is intact. It is the
documented answer for this slice, taken with decision 3; a later decision may make the fault a
type error instead (an opaque status, a validated header), which (d) does not foreclose, at the
cost of every literal response.

A client that went away before the response is written is not a failure: `res.destroyed` is
true, Node drops the write and throws nothing (measured), and so does the platform. A client that
leaves while the response is being written is the socket's error (`ECONNRESET`, `EPIPE`), which
Node routes to the server's `clientError` and handles by default — the socket is destroyed — and
`res` emits no `error` (measured with a 64 MiB body cut after its first chunk). The handler runs
to its end either way; cancelling it when the client leaves is a later slice.

**(e) Every failure Node documents, and what it becomes.** The table is the contract of rule 9
for this module. "Thrown again" means the error is a defect, and the process ends as §16.5 of
`transparent-effects-proposal.md` says.

| Operation | Node's failure | Becomes |
|---|---|---|
| `listen` | `error` event, `EADDRINUSE` | `Err AddressInUse` |
| `listen` | `error` event, `EACCES` | `Err PermissionDenied` |
| `listen` | `error` event, `EADDRNOTAVAIL` or `EAFNOSUPPORT` | `Err AddressNotAvailable` |
| `listen` | `error` event, `ENOTFOUND`, `EAI_AGAIN` or `EAI_FAIL` (`getaddrinfo`) | `Err HostNotFound` |
| `listen` | `error` event, `EMFILE` or `ENFILE` | `Err TooManyOpenFiles` |
| `listen` | `ERR_SOCKET_BAD_PORT`, thrown synchronously | never reached: `Err InvalidPort` is answered in beni first |
| `listen` | `ERR_SERVER_ALREADY_LISTEN` | cannot happen: each `listen` makes a new `http.Server` |
| `listen` | any other `error` event | thrown again, whether or not a fiber still waits for the bind (`HttpServerCrashOnListenAfterCancel`) |
| the server, once it listens | an `error` event, such as `EMFILE` on an accept | no listener is left on it: Node throws the event, a defect; `listen` has returned, so no one could be answered |
| the body read | `req`'s `error` with `ECONNRESET` | the request is dropped |
| the body read | `req`'s `error` with any other code | thrown again |
| the server | `clientError` | left to Node's default handler: 400, 431 or 408 written while the socket is still writable, then the socket destroyed |
| the server | `checkContinue` (`Expect: 100-continue`) | left to Node: `100 Continue`, then the request reaches the handler |
| the server | `checkExpectation` (any other `Expect`) | left to Node: 417 |
| the server | `connect` (a `CONNECT` request) | left to Node: the socket is destroyed |
| the server | `upgrade` (an `Upgrade` header) | left to Node: an ordinary request, which reaches the handler |
| the response | `ERR_INVALID_HTTP_TOKEN` or `ERR_INVALID_CHAR` from the two validators, a status outside 200 to 999, a body on 204, 205 or 304, a `content-length` or `transfer-encoding` of the program's | an invalid response: 500 and a line on standard error |
| the response | `res.destroyed` before the write | the write is dropped: the client is gone |
| the response | the socket fails during the write (`ECONNRESET`, `EPIPE`) | `clientError`, the same default handler: nothing is writable, so the socket is destroyed |
| the response | any other throw | thrown again |
| `close` | `ERR_SERVER_NOT_RUNNING` (closing a server never started) | cannot happen: `close` runs only on a bound server, and a second `close` is skipped in beni |

**(f) A defect in a handler stops the process** (decision 1 of #331, the owner, 2026-10-17:
rule 9 does not change for a server). A throw in a handler's fiber leaves the scheduler's drain,
Node reports it and the process exits 1 (§16.5 *A defect on Node*; §9.8.14 (k)). Every open
connection is reset by the operating system, and a supervisor restarts the process. The other
choice, a 500 for that request with the defect logged, needs a catch at the handler's boundary,
which rule 9 forbids; it was offered and declined.

**(g) Order and determinism.** One fiber runs at a time (§17.1 item 3). Requests are queued as
each one completes, in that order, and the loop fiber starts one handler fiber per request in
that order. Handlers interleave only at their suspension points. A response is written in the
handler's fiber, when it returns, so on one connection with pipelined requests Node keeps the
responses in request order, and across connections the order is the handlers' completion order.
What a program observes depends on the requests and the scheduler's FIFO, never on a timer or on
the port.

**(h) How the tests drive a server.** A `run/` fixture may carry a `.requests` script
(`_expected.requests` in a project) beside its `.expected`. The case is built as every `run/`
fixture is, twice, development and `--release --allow-debug`, and each build is then run by
`node tests/serve/driver.mjs out/_main.mjs <name>.requests` in the project directory, instead of
by `node out/_main.mjs`; its transcript is the golden. The driver:

1. Starts the program as a child, `node --import tests/serve/preload.mjs out/_main.mjs`, with its
   standard output and error captured and a fourth pipe, file descriptor 3. The preload wraps
   `net.Server.prototype.listen`: on each `listening` event it writes the bound address as one
   JSON line to descriptor 3. The program's own output never carries the port, and **the port
   never appears in the transcript**: fixtures listen on port 0, and the driver reads the port
   from descriptor 3. That is rule 5's requirement for this kind.
2. Runs the script, one JSON object per line, `#` for a comment. A request step
   `{"method": "POST", "path": "/echo", "headers": {"content-type": "text/plain"}, "body": "hi"}`
   is sent to `127.0.0.1` on that port and printed as `> POST /echo`, its headers as `> name:
   value`, then a blank `>` line and the body, one `> ` line each, when there is one. The answer
   is printed as `< 200`, each response header as `< name: value` in the order received, the
   `date` header left out, then a blank `<` line and the body lines. A request the client cannot
   complete prints `< (error ECONNRESET)` with Node's code. A step `{"raw": "GARBAGE\r\n\r\n"}`
   writes those bytes on a new connection and prints the first line of what comes back and
   `(closed by the server)`. A step `{"cut": {...request..., "declared": 10}}` sends the headers
   with that `content-length`, the body given, then resets the connection. A step
   `{"signal": "SIGTERM"}` sends the signal. A step `{"fault": "listen:EPROTO"}` or
   `{"fault": "request:EIO"}` or `{"fault": "server:EMFILE"}`, first in a script, makes the
   preload fail the next `listen` (a list of codes, `listen:EMFILE,ENFILE`, fails the next
   `listen`s in turn), the next request's read, or the server once it listens, with that code,
   shaped as Node shapes the error: the one way to force an error the platform does not name,
   which §4.1's testable form asks a `run/` scenario to do and assert the crash, and the one way
   to reach a code the test host cannot produce. A `{a*20000}` inside a `raw` step's bytes is
   that many of the character, and the transcript keeps the placeholder.
3. After the last step, waits up to 5 s for the program to exit, then prints `--- stdout ---`,
   `--- stderr ---` and `--- exit <code> ---` (or `--- exit signal <name> ---`, or
   `--- exit killed: still running after the last step ---` after a SIGKILL). Standard error is
   printed through one filter, so a crash fixture is deterministic: the project directory's
   absolute path becomes `<project>`, lines that start with `    at ` are dropped, and the
   `Node.js v…` line is dropped.

**The first slice's fixtures**, the one list every fixture this section names is on, by the
rows of (e):

- `listen`: `HttpServerListenErrors` (`AddressInUse`, `AddressNotAvailable` by `EADDRNOTAVAIL`,
  `HostNotFound` by `ENOTFOUND`, `InvalidPort` for 70000, -1 and 65536, all produced by the
  host); `HttpServerListenInjected` (`TooManyOpenFiles` by `EMFILE` and `ENFILE`,
  `AddressNotAvailable` by `EAFNOSUPPORT`, `HostNotFound` by `EAI_AGAIN` and `EAI_FAIL`, each
  injected, since no test host produces them on demand); `HttpServerCrashOnListen` and
  `HttpServerCrashOnListenAfterCancel` (`EPROTO`, injected, with and without a fiber still
  waiting for the bind). `EACCES` has no fixture: a port under 1024 binds as root and on macOS.
- the server once it listens: `HttpServerCrashOnAccept` (`EMFILE`, injected on the server).
- the body read: `HttpServerBadClients` (a body cut short) and `HttpServerCrashOnRequest`
  (`EIO`, injected).
- the server's `clientError`: `HttpServerBadClients` (bytes no parser accepts, 400; a header
  block over `maxHeaderSize`, 431). 408 has no fixture: it needs `requestTimeout`, 300 s.
- the four events Node answers by itself: no fixture; the probe behind (c) settled them.
- the response: `HttpServerInvalidResponse` (status 1000 and 100, a body on 204 and on 205, a
  204 with no body, a 205 with no body, a bad header name, a bad header value, `Content-Length`
  and `transfer-encoding` of the program's); `HttpServerDuplicateHeaders` (two `set-cookie`);
  `HttpServerBadClients` (a client gone before its answer, the write dropped; a client gone
  during a 16 MiB write, the socket's error left to Node); `HttpServerCloseFromHandler` (the
  program's `connection: keep-alive` replaced after `close`) and `HttpServerCloseThenInvalid`
  (the 500 after `close` ends its connection too).
- the response's last row, any other throw: no fixture. The write has no injection point the
  preload offers: `writeHead` and `end` on a live response throw for nothing a program can
  cause, and the preload fails the host's operations, not Node's own functions.
- the lifetime, (b): `HttpServerOwnerEnds` and `HttpServerOwnerEndsAtOnce`.
- the basics, (a) and (c): `HttpServerBasics` (a `GET`, a `POST` with its body, the query kept
  in `path`, a `HEAD` answered with the headers and no body, `header` looked up in another case
  than the one sent); `HttpServerDuplicateHeaders` (a request header given twice reaches the
  handler as two, in order).

*(Amended 2026-10-20: a script also drives WebSocket clients, and the preload fails a socket with
`socket:<code>`, or with `socket:errno=<name>` for an error that carries only the number;
§9.11, *As built, the server*.)*

Each build's verdict is recorded as a run hash (`run_hash.lineWith`, as `browser/` records its
page): the digest covers what a `run/` one covers — the output tree, the golden, the Node version
— and the driver's bytes, the preload's bytes and the script, so a verified build runs no Node. Every case stays under the
budget of 4 300 million instructions: a case costs two builds, two driver processes and two
program processes, and no fixture sleeps for real.

**(i) The owner's three decisions**, taken on the dashboard on 2026-10-17 at 23:54 CEST, and the
slice's scope, which is Jayson's instruction. The PR's
review (2026-10-17) found five gaps in (d) and (e); each is settled above with a probe or a
stated crash. Its second pass and the owner's two findings (2026-10-18, 00:01 CEST) added the events Node
answers by itself, duplicate headers, `connection` after `close`, 205, the size limit owed, and
why an invalid response is not a defect; each is settled above. Its third pass (2026-10-18)
added the 500 after `close`, 205's `content-length: 0`, and the wording of (e), (h) and (j); its
fourth made (h) the one list of fixtures, with the rows that have none and why.

- Decision 1, a defect in a handler (`node-http-q1`): **stop the process**. Rule 9 does not
  change; (f) has the rule.
- Decision 2, where the code lives (`node-http-q2`): **extend the `node` platform**.
  `Http.Server` is `platforms/node/Http/Server.beni` with its sibling `Server.js`, beside `Io`;
  one platform for command-line and server programs.
- Decision 3, the API shape (`node-http-q3`): **accept the shape** of (a)–(d). The choices it
  settles: `method` is a `String` and not a union, since Node fixes the set and a program matches
  on text; `path` is the raw target, parsed by core's `Url` when wanted; `headers` is a list of
  pairs and not a `Dict`, so duplicates and order survive; `body` is text; an invalid `Response`
  answers 500 with a line on standard error; a handler stops the server through core's
  `Deferred`, not through a second API.
- Decision 4, the first slice: an HTTP server only, text bodies, as Jayson instructed on
  2026-10-17.

**(j) Not in this slice.** Each has an issue: streaming request and response bodies, and bodies
as bytes (#335); a request body size limit (#336); cancelling a handler when its client leaves
(#337); signals, so `SIGTERM` closes the server gracefully (#338); outbound HTTP on `node` (#339);
TLS, HTTP/2, an API for WebSocket and `upgrade` and for `100-continue` (today Node answers both
by itself, (c)), trailers, a Unix socket address and configuring Node's timeouts (#340). Raw `node:net`, routing, command-line arguments, environment
variables and file writes are #331's later slices. *(Amended 2026-10-20: the WebSocket part of #340 — `upgrade`, and an API
for a WebSocket — is §9.11.)*

### 9.11 WebSocket, in a page and on the `node` server (2026-10-20)

*Added 2026-10-20, for issues #524 (the page) and #340 (its WebSocket part). Status: proposed. The
shape of the API is the owner's decision; (n) lists the two questions on the dashboard
(`ws-q1`, `ws-q2`) and the recommendation each section follows until they are answered.* One
design covers both sides of a connection, so a text message and a close mean the same thing in a
page and on a server. The page side is a module of `browser`, re-exported by `browser-tea`; the
server side is a module of `node` and an addition to `Http.Server` (§9.10). The external
`snake-arena` game is the first user: its server sends a state message to each player 20 to 30
times per second and receives small input messages ((m)).

The model is the host's own API (the WHATWG `WebSocket` interface, RFC 6455) and Effect v4's
`Socket` (`references/effect`, `packages/effect/src/unstable/socket/Socket.ts` at the pinned
commit), not an Elm package: elm-lang/websocket was withdrawn in 0.19. Its names (`send`,
`listen`) are kept for the command and the subscription, as §9.8.17 (b) keeps Elm's names for
the wrappers. Research 45 §4.3 sketched this API, and W52 (§9.8.9) settled its one question: a
model may hold the socket, because every operation on a closed socket is total.

**(a) The common surface.** Both platforms have a module named `WebSocket` with these
declarations, with the same names, types and meaning. A module that imports `WebSocket` and uses
only these declarations checks under `browser`, `browser-tea` and `node`, so a full-stack program
can share one protocol module between its page and its server.

```elm
-- module WebSocket (browser, re-exported by browser-tea; and node)

pub foreign type Socket
pub eq : Socket, Socket → Bool         -- identity: one connection is equal only to itself

pub type alias Close =
    { code : Int       -- 1000 normal, 1001 going away, 1005 no code, 1006 no close frame, …
    , reason : String  -- "" when there is none
    }

pub type WriteError
    = NotOpen          -- the connection is not open: it is still connecting, closing or closed

pub type CloseError
    = InvalidCode Int  -- a code this side may not send, (c) step 4 and (f)
    | ReasonTooLong    -- a reason longer than 123 bytes of UTF-8

pub read : Socket → Result Close String           -- suspends until a message, or the end
pub write : Socket, String → Result WriteError ⊤  -- impure, never waits
pub close : Socket, Close → Result CloseError ⊤   -- impure, never waits
pub buffered : Socket → Int                        -- impure: bytes written and not yet sent
pub protocol : Socket → String                     -- impure: the subprotocol in use, "" for none
```

- **`read socket`** answers the oldest text message that no one has read: `Ok text`. When the
  connection has ended and every message received before the end has been read, it answers
  `Err close`, and it answers the same `Err close` to every later call. While no message waits
  and the connection is open, it suspends. Fibers that read one socket at the same time get the
  messages in the order they began to wait. A cancelled reader leaves the list of waiters, and
  no message is lost (`transparent-effects-proposal.md` §17.1 item 1).
- **`write socket text`** sends `text` as one text message and answers `Ok ⊤`. It never waits:
  the message joins the host's send buffer. When the connection is not open, it sends nothing and
  answers `Err NotOpen`. The host sends a lone surrogate of `text` as U+FFFD, on both sides (the
  `USVString` conversion of the browser, and `Buffer.from(text, "utf8")` on Node).
- **`close socket { code, reason }`** starts the closing handshake: it sends a close frame with
  that code and reason, and from that moment `write` answers `Err NotOpen`. A code this side may
  not send is `Err (InvalidCode code)`, and a reason longer than 123 bytes of UTF-8 is
  `Err ReasonTooLong`; both are found by a test of the value before the host is called. A
  connection that is closing or closed already is not changed, and the answer is `Ok ⊤`.
- **`buffered socket`** is the number of bytes that `write` accepted and the host did not send
  yet: the browser's `bufferedAmount`, and Node's `socket.writableLength`. It is how a program
  sees back-pressure ((h)).
- **`protocol socket`** is the subprotocol the server chose in the handshake, or `""`.
- **`eq`** compares two sockets by identity. So `==` works on a model that holds a
  `Maybe Socket`, and `model.socket == Nothing` checks. `static-dispatch-spike.md` §3.5 lists
  handles with no `eq` "since nothing needs it"; a model that holds a socket needs it.

**What `Close` says.** `Close` tells why a connection ended, by these rules, in this order:

1. The peer sent a close frame first: its code and its reason. A close frame with no code is
   1005 and `""` (RFC 6455 §7.1.5).
2. This side sent a close frame first (`close`, the end of its owner, `Server.close`): the code
   and the reason of the close frame that the peer sent in answer. A peer usually repeats the
   code it received. This is what the browser's `close` event reports.
3. This side failed the connection because the peer broke a rule ((f), (j)): the code that this
   side sent, and `""`. The server sends 1002, 1003, 1007 or 1009. The page fails a connection
   only for a binary message, and reports 1003 for it, though the host does not let it send that
   code ((j)).
4. The connection ended with no close frame from the peer, or the closing handshake timed out:
   1006 and `""`.

The meaning of every code is RFC 6455 §7.4 and the IANA registry. A program matches on the
codes it knows; 4000–4999 are the application's own.

**(b) The page: the API.** `browser`'s `WebSocket` has the common surface and these:

```elm
pub type ConnectError
    = BadUrl String       -- the URL does not parse relative to the page, has another scheme, or a fragment
    | BadProtocol String  -- a subprotocol that is not a token, or that is given twice
    | Blocked             -- the host refused the connection at once (`SecurityError`)
    | Unreachable         -- the connection failed before it opened

-- the direct form (§9.8.11 (a))
pub connect : String, List String, (Socket → a) → Result ConnectError a    -- suspends

-- The Elm Architecture's forms
pub type Event
    = Opened Socket
    | Received String
    | Closed Close
    | Failed ConnectError

pub listen : String, List String, (Event → msg) → Sub msg
pub send : Socket, String, (WriteError → msg) → Cmd msg
pub disconnect : Socket, Close, (CloseError → msg) → Cmd msg
```

**`connect url protocols use`** opens a connection, waits until it is open, calls
`use socket`, and answers `Ok` with what `use` answers. The socket belongs to the call: when
`use` returns, or when the calling fiber is cancelled, the platform closes an open socket with
1000 and `""`, and stops a socket that is still connecting. `connect` does not wait for the
closing handshake; the host finishes it. A connection that fails before it opens is
`Err Unreachable`, and `use` is not called. A program that needs a time limit on the open
writes `Task.timeout` around the call.

**`listen url protocols tag`** is the subscription. While its key — the URL as written and the
protocols — is in the set, the platform holds one connection, and every declaration of that key
gets each event through its own tagger (§9.8.5). The events of one connection are, in order:

- `Opened socket`, once, when the connection opens. From then on `write` works on `socket`, so
  `update` keeps it in the model and gives it to `send`.
- `Received text`, once for each text message, in the order the server sent them.
- At the end, exactly one of `Closed close` (the connection opened first) or `Failed error` (it
  never opened). Nothing comes after it.

A declaration that joins a key that is live already gets the events from then on: `Opened` is
not sent again, so the declaration that holds the socket in the model is the one that was there
when the connection opened.

A subscription only listens, so it is a `Sub.on` listener and needs no fiber (§9.8.5's
amendment): a page that uses `listen` and `send` reaches no fiber runtime through them. When the
key leaves the set, the listener is removed at once, and the platform closes an open socket with
1000 and `""` (or stops a connecting one). After a defect, `Hosted`'s `Task.onShutdown` function
removes the listener in the same way (§9.8.14 (a)). Every message of a socket that `listen`
opened goes to the subscription, so `read` on that socket answers only the end.

**`send socket text failed`** is `write` when the command runs, and **`disconnect socket close
failed`** is `close` when the command runs. Each sends `failed error` only when the operation
failed, as `Storage.save` does (§9.8.16 (b)), and each is a `Now` command, with no fiber
(§9.8.11 (b)). They take values (§9.8.16 (b)): the socket and the text, never a function that
reads the model.

**Reconnecting** is the program's decision, as Effect leaves it to `Effect.retry`. The platform
never opens a second connection for a key by itself. A program that sees `Closed` or
`Failed Unreachable` removes the key from its subscriptions, waits, and puts the key back:

```elm
subscriptions model =
    case model.link of
        Waiting _ →
            Sub.none

        _ →
            WebSocket.listen "/arena" [] Socket


update msg model =
    case msg of
        Socket (WebSocket.Opened socket) →
            ( { model | link = Up socket }, Cmd.none )

        Socket (WebSocket.Received text) →
            ( { model | arena = Protocol.decode text model.arena }, Cmd.none )

        Socket (WebSocket.Closed _) →
            ( { model | link = Waiting 1 }, retryAfter 1 )

        Socket (WebSocket.Failed _) →
            ( { model | link = Waiting (next model.link) }, retryAfter (next model.link) )

        Retry →
            ( { model | link = Connecting }, Cmd.none )

        Turn direction →
            case model.link of
                Up socket →
                    ( model, WebSocket.send socket (Protocol.turn direction) Unsent )

                _ →
                    ( model, Cmd.none )

        Unsent _ →
            ( model, Cmd.none )


retryAfter : Int → Cmd Msg
retryAfter attempt = Cmd.perform λsend →
    Time.sleep (Time.millis (500 * attempt))
    send Retry
```

The key must be out of the set for one render, so that the next render starts a new
connection: the set is computed once per render (§9.8.5). A wait does that, since the message
that ends it arrives in a later task. A program that reconnects at once without a wait changes
the key instead: `"/arena?attempt=${n}"`.

**(c) The page: what each operation does, and every failure.** Each failure that the WHATWG
standard documents is one constructor. Each is found by a test of the value before the host is
called, except `SecurityError`, which only the constructor can report (rule 9; `Http`'s steps
1–4 in §9.8.12 (b) are the model).

1. **The URL** is parsed by `new URL(url, document.baseURI)` inside `Js.catchIf`, which takes
   only a `TypeError`: `Err (BadUrl url)`. A relative URL is therefore allowed, as the current
   standard allows it, also in a host that is older than that change. The scheme `http:` becomes
   `ws:` and `https:` becomes `wss:`. Any other scheme than those four is `BadUrl url`, and so is
   a URL with a fragment (the constructor's `SyntaxError` for both).
2. **Each protocol** must be an HTTP token (RFC 9110's `tchar`), and no protocol may appear twice
   (compared as written): else `Err (BadProtocol protocol)`, the constructor's `SyntaxError`.
3. **The constructor**, `new WebSocket(href, protocols)`, runs inside `Js.catchIf`, which takes
   only a `DOMException` named `SecurityError`: `Err Blocked`. A browser throws it for a socket
   that the page may not open, for example an insecure `ws:` socket from an `https:` page.
   Anything else that the constructor throws is a defect. `binaryType` is set to
   `"arraybuffer"`, so that a binary message needs no `Blob` read ((j)).
4. **`close`** may send the code 1000 or a code from 3000 to 4999; any other code is
   `Err (InvalidCode code)`, which the host reports as `InvalidAccessError`. The reason is
   measured in UTF-8 bytes after the `USVString` conversion.
5. **`write`** calls `send` only when `readyState` is `OPEN`. In `CONNECTING` the host throws
   `InvalidStateError`, and in `CLOSING` or `CLOSED` it drops the message with no error; both are
   `Err NotOpen` here, so a message is never dropped without an answer.

| The host's event | Is |
|---|---|
| `open` | `Opened socket`; `connect` calls `use` |
| `message` with a string | `Received text`, or a message for `read` |
| `message` with an `ArrayBuffer` | (j): the platform fails the connection |
| `error` | nothing: the standard always fires `close` after it, and `close` carries the result. The host gives a page no detail of a failure, on purpose, so a refused handshake, a server that is down, a TLS failure and a blocked port are all one failure |
| `close` before `open` | `Failed Unreachable`, or `Err Unreachable` from `connect` |
| `close` after `open` | `Closed { code, reason }` from the event, or the end for `read` |

**(d) The page: who owns a socket.** A socket belongs to the call of `connect` that opened it, or
to the key of `listen` that opened it, and it lives as long as its owner:

| The owner stops | What the platform does |
|---|---|
| `use` returns | closes an open socket with 1000 and `""` |
| the fiber that called `connect` is cancelled (`Restart`, `Cmd.cancel`, a scope's end, a defect's teardown) | the same: `connect` is a `Task.bracket`, and its release closes the socket (§9.8.14 (a)) |
| the key of `listen` leaves the set | removes the listener and closes the socket, in that render |
| a defect stops the page | `Hosted`'s `onShutdown` function removes the listener and closes the socket |

A socket that is still connecting is stopped with `close()`, with no code, which the standard
allows. After the owner stops, no event of that socket reaches the program, and the model may
keep the socket: every operation on it is total.

**(e) The server: the upgrade.** `Http.Server` (§9.10) gains a second way to listen:

```elm
-- module Http.Server (node), additions
pub type alias Handlers =
    { request : Request → Response   -- every request that is not a WebSocket upgrade
    , upgrade : Request → Upgrade    -- every request that asks for a WebSocket
    }

pub listenWith : Address, Handlers → Result ListenError Server

pub type Upgrade                     -- opaque: the answer to a request for a WebSocket
pub accept : (Socket → ⊤) → Upgrade
pub acceptWith : { protocol : Maybe String, maxMessage : Int }, (Socket → ⊤) → Upgrade
pub refuse : Response → Upgrade

pub protocols : Request → List String   -- the subprotocols the client offered, in order
```

`Socket` is `WebSocket.Socket`. `listen address handler` does not change: it has no upgrade
handler, so a request for a WebSocket is an ordinary request, as today (§9.10 (c)).

```elm
main : Program
main = Io.run λ⊤ →
    arena = Arena.make ⊤
    _ = Task.spawn λ⊤ → Arena.tick arena
    case Server.listenWith { host = "127.0.0.1", port = 8080 } { request = page, upgrade = join arena _ } of
        Err error →
            Node.exitWith (describe error) 1

        Ok server →
            Server.wait server


join : Arena, Request → Upgrade
join arena request =
    if request.path ≠ "/arena" then
        Server.refuse (Server.text 404 "no such socket")
    else if Server.header request "origin" ≠ Just "https://snake.example" then
        Server.refuse (Server.text 403 "not from this site")
    else
        Server.accept (play arena _)


play : Arena, Socket → ⊤
play arena socket =
    id = Arena.add arena socket
    Task.onExit (λ⊤ → inputs arena id socket) λ_ → Arena.remove arena id


inputs : Arena, Int, Socket → ⊤
inputs arena id socket =
    case WebSocket.read socket of
        Ok text →
            Arena.input arena id text
            inputs arena id socket

        Err _ →
            ⊤
```

**Which requests are upgrades.** Node 24's `shouldUpgradeCallback` routes a request to
`upgrade` only when the program gave `listenWith` and the request's `upgrade` header is
`websocket`, without case. Every other request, with another `upgrade` header too, reaches
`request` as an ordinary request. The platform then checks the handshake (RFC 6455 §4.2.1):
the method is `GET`, `connection` holds the token `upgrade`, `sec-websocket-key` is the base64
of 16 bytes, and `sec-websocket-version` is `13`. A handshake that fails a check never reaches
the program: the platform answers 400, or 426 with `sec-websocket-version: 13` for another
version, and ends the connection.

**The answer.** The platform calls `upgrade request` in a fiber of the server's scope, as it
calls a request handler.

- `refuse response` writes `response` as an HTTP/1.1 answer on the connection, with
  `connection: close`, and ends the connection. The rules of §9.10 (d) apply: an invalid
  response is a 500 with a line on standard error.
- `accept session` answers `101 Switching Protocols` with `sec-websocket-accept` and no
  subprotocol, then calls `session socket` in the same fiber. `acceptWith { protocol, maxMessage }`
  also names the subprotocol, which must be one of `protocols request`, and sets the largest
  message the session accepts, in bytes ((f)). `accept` is `acceptWith { protocol = Nothing,
  maxMessage = 1048576 }`. A protocol that the client did not offer is an invalid answer: 500,
  and a line on standard error, as in §9.10 (d), since a browser fails such a handshake.

The platform negotiates no extension: it ignores `sec-websocket-extensions`, so no message is
compressed. Bytes that the client sent after its handshake, in the same packet (Node's `head`),
are the first bytes of the connection.

**(f) The server: a session, and the protocol rules.** A session is `session socket`, in the
fiber of the upgrade. The common surface works on `socket` as (a) says; the codes that the
server may send with `close` are 1000 to 1003, 1007 to 1014 *(amended: no 1010, item 3 below)* and 3000 to 4999 (RFC 6455 §7.4 and
the IANA registry), and `close` with any other code is `Err (InvalidCode code)`. The platform
reads and writes RFC 6455 frames itself in `WebSocket.js`, a sibling of `node`'s `WebSocket`
module, with `node:crypto` for the handshake and no package:

- It sends each message as one unmasked frame. It joins a fragmented message from the client
  before `read` sees it, and it answers each ping with a pong that carries the ping's data.
  Control frames between fragments are allowed. A pong is ignored. The program sees no control
  frame.
- It **fails the connection with 1002** (a protocol error) for a frame that is not masked, a set
  RSV bit, a reserved opcode, a control frame longer than 125 bytes or not final, a continuation
  with no message to continue, a new message before the last one is final, a 64-bit length with
  its high bit set, a close frame of one byte, and a close code that RFC 6455 does not allow on
  the wire (below 1000, 1004 to 1006, 1015 to 2999, 5000 and above).
- It **fails the connection with 1007** for a text message, or a close reason, that is not valid
  UTF-8 (`buffer.isUtf8`, so nothing is caught).
- It **fails the connection with 1009** for a message longer than `maxMessage`, as soon as the
  frame headers show it: the platform does not keep the bytes.
- It **fails the connection with 1003** for a binary message ((j)).

To fail the connection, the platform sends a close frame with that code and ends the TCP
connection without reading more (RFC 6455 §7.1.7). `read` answers the messages that arrived
before the fault, then `Err { code, reason = "" }` with that code ((a), rule 3).

**The closing handshake.** When the client sends a close frame first, the platform answers with
a close frame with the same code (none when the client sent none), ends the TCP connection, and
`read` answers `Err` with the client's code and reason. When the server sends one first, the
platform waits for the client's answer, then ends the TCP connection. When no answer arrives
within 5 seconds, the platform destroys the connection and `read` answers 1006.

**(g) The server: lifetimes.** A WebSocket connection belongs to its session, and the session
belongs to the server's scope, as a request handler does (§9.10 (b)):

| When | The connection |
|---|---|
| `session` returns | an open connection is closed with 1000 and `""`; the platform finishes the handshake on its own, within the 5 seconds |
| the server's owner ends, or is cancelled | the session fibers are cancelled and every connection is destroyed at once, with no close frame, as every HTTP connection is (§9.10 (b)). Nothing keeps the process alive |
| `Server.close` | the server stops accepting, and each open WebSocket connection is closed with 1001 and `""` (going away). A session sees the client's answer as the end of `read`. A session that `accept`s after `close` gets a connection that the platform closes with 1001 at once |
| `Server.wait` | returns when the server has closed, every response is written and every WebSocket connection has ended |

Node's `closeAllConnections` does not reach an upgraded socket, and Node's `close` callback
waits for one (measured, Node 24.19), so the platform keeps its own set of open WebSocket
connections and destroys them itself on cancellation.

**(h) Back-pressure.** `write` never waits, on either side, because the browser has no way to
wait for its send buffer. A sender that can go faster than its peer reads sees it in
`buffered`: the game's tick skips a player whose `buffered socket` is over a limit, and the next
tick sends the newer state. The server has one more operation, which the page cannot have:

```elm
pub drain : Socket → ⊤      -- node only: suspends until the writes so far are flushed, or the end (amendment item 14)
```

`drain` waits for Node's `drain` event of the socket *(withdrawn: item 14 of the amendment
below)*. A sender of many messages writes and then
drains. The other direction is the platform's: when the messages that the server received and
`read` did not take hold more than 64 KiB, the platform stops reading the TCP connection, and it
reads again when `read` takes them. A slow session therefore slows its client through TCP, and
the memory that the server holds for one connection stays bounded, at about `maxMessage` and
64 KiB more. A session that
never calls `read` sees no close from its client until a `write` fails: the connection ends with
1006.

**(i) The server: every failure that Node documents.**

| Operation | Node's failure | Becomes |
|---|---|---|
| the handshake | a request that fails a check of (e) | 400, or 426 for another version; the program is not called |
| the handshake | a protocol in `acceptWith` that the client did not offer | 500 and a line on standard error |
| the handshake | the client went away before the 101 is written | the session does not start: `upgrade`'s answer is dropped |
| the connection | `error` with `ECONNRESET`, `EPIPE` or `ETIMEDOUT` | the connection ended with no close frame: `read` answers 1006 |
| the connection | `error` with any other code | thrown again: a defect, which stops the process (§9.10 (f)) |
| a frame | a fault of (f) | the connection fails with 1002, 1003, 1007 or 1009 |
| `write` | the connection is not open (`socket.writable` is false, or a close frame was sent or received) | `Err NotOpen`, tested before Node is called |
| `close` | a code or a reason this side may not send | `Err (InvalidCode code)` or `Err ReasonTooLong`, tested before Node is called |

A defect in `upgrade` or in a session stops the process, as a defect in a handler does (§9.10
(f)).

*As built, 2026-10-20, the server* (`platforms/node/WebSocket.beni` and its sibling
`WebSocket.js`; `Http/Server.beni` and `Server.js`; `tests/serve/driver.mjs` and `preload.mjs`),
as (e)–(i) and the amendment's items 14–28 say, with these readings:

- **The two siblings meet by value** (item 26). `Server.js` makes the upgrade's record —
  `{ handle, req, socket, head, waiting, goAway, request }` — when the `upgrade` event comes, adds
  its `error` listener (`waiting`) and checks the handshake there, and queues it for the accept
  loop as it queues a request. `Server.beni` calls the program's `upgrade` in a fiber of the
  server's scope, and for an accept calls `WebSocket.upgraded`, a `pub` function that takes the
  record as a `Js.Value` (a program has no `Js.Value` to give it) and answers the socket and the
  function the session's end calls. `WebSocket.js` takes the socket over: it checks first that
  the socket is alive, and a socket that is not keeps `waiting` and starts no session; then it
  removes `waiting`, writes the 101, and sets `goAway`, which `Server.close` calls for the 1001.
- **A refusal is written by hand** on a socket that Node gave up: the status line with Node's
  reason phrase, `date`, the program's headers less `connection`, `content-length` (none on 204
  and 304), and `connection: close`, then the end of the connection. The checks of §9.10 (d) run
  first, and an invalid response is a 500 with a line on standard error. That line quotes a
  protocol the client did not offer with `JSON.stringify`, so the program's text cannot add a
  line.
- **Frames.** One allocation and one write per text frame; one cache of the last text and its
  frame for the whole process (item 27). Unmasking runs in place over the received bytes. The
  receive side keeps a list of chunks and copies only a frame that spans two of them.
- **`drain`** counts the writes and the callbacks of each, and answers when the callback of the
  last write made before it was called flushed (item 14). The pong of item 25 waits for Node's
  `drain` event, which comes, since a write over the high-water mark returned `false`.
- **Fixtures** (`tests/corpus/run/`): `WebSocketEcho` (routing; `accept`, `acceptWith`, `refuse`;
  each side's close; 1010 refused; an offer that is not a token dropped), `WebSocketFaults` (the
  handshake's checks, an `upgrade` list, each frame fault — among them a 64-bit length with its
  highest bit, the control opcode 11, and the close codes 1005, 1016 and 2999 — 1009 for two
  fragments that are over `maxMessage` only together, `maxMessage` below 0),
  `WebSocketLifetime` (a FIN and a reset with no close frame; a protocol not offered, also one
  with a newline in it, and an invalid refusal; an accept after `Server.close`, which the
  program makes only after `/b`'s session has ended, so the two 1001 lines keep one order),
  `WebSocketOwnerEnds`, `WebSocketBackPressure` (`buffered` and `drain` against a client that does
  not read; five pings while more than 1 MiB waits, answered with one pong for the latest, item
  25; 300 messages read late, in order), `WebSocketDrain` (`drain` after a write too small for
  Node's `drain` event, which fails on a `drain` that waits for that event; a close while
  reading is paused), `WebSocketArena` (three players, inputs, a broadcast tick, a player who
  leaves), `WebSocketNetworkFault` (`EHOSTUNREACH` ends one connection, the server goes on; a
  reset before the 101), `WebSocketNetworkReset` (an error that carries only `ENETRESET`'s number
  ends one connection, the server goes on) and `WebSocketCrashOnSocket` (`EIO`, which no rule
  names: exit 1).
- **`ENETRESET` is matched by its number** (`errno === -os.constants.errno.ENETRESET`), since libuv
  has no name for it and Node's `code` is not `ENETRESET` but `Unknown system error -<n>` (the
  amendment's item 15). Only macOS and the BSDs report it; the preload's `socket:errno=ENETRESET`
  gives a Linux run the same error, so `WebSocketNetworkReset` pins the rule on every host.
- **Measured** (`bench/websocket/`: the arena server of `server/Main.beni`, `--release`, and
  `load.mjs`, with 100 players on Node 24's own `WebSocket` client, each sending 5 inputs a
  second, for 10 seconds, on 127.0.0.1): 29.8 ticks a second, 2 980 states and 500 inputs a
  second; the server process used 3.8% of one core, 10.9 µs of CPU and 17 414 user-space
  instructions per message; between the first and the last player to get a tick, 1.18 ms at the
  median and 3.2 ms at the 99th percentile. The state of about 2.5 KiB is encoded once per tick,
  for all 100 players (item 27).
- **Not pinned by a fixture**, since each needs real time or a race: the 5-second closing timer,
  TCP keep-alive, and a client that leaves while the program decides and whose end the server
  sees only after the accept. `WebSocketDrain`'s close while reading is paused passes with or
  without item 18, because the session's `read` resumes reading; the case item 18 settles — a
  session that closes and never reads — differs only in when the connection ends.

**(j) Binary messages are a later slice.** beni has no `Bytes` type yet (§9.8.12's *Where this
departs*, #335). Binary messages arrive with it, under the same API: `read` and `Received` stay
text, and a binary form is added beside them. Until then a binary message is a message this side
cannot accept, which RFC 6455 §7.4.1 names 1003. The server fails the connection with 1003. The
page cannot send 1003 (the host allows only 1000 and 3000–4999), so it closes the socket with no
code, and the program sees `Closed { code = 1003, reason = "" }` at once, by rule 3 of (a); no
later event of that socket reaches it. On both sides the platform writes one line: to standard
error on the server, and with `console.warn` in the page, in both builds.

**(k) Order and determinism.** One fiber runs at a time (§17.1 item 3). The messages of one
connection reach `read`, or the subscription, in the order the peer sent them. The page delivers
a subscription's events where a fiber's resumption would land (§9.8.5's amendment, point 2), so
an event keeps its place among commands, fibers and other subscriptions. The server starts a
session per accepted upgrade in the order the upgrades arrive, as it starts request handlers
(§9.10 (g)).

**(l) How the tests drive it.**

- **The page.** The page driver scripts the page's `WebSocket` as it scripts `fetch`, in both
  DOMs. Each `new WebSocket` is logged as it is made, `(socket <n>: <url> <protocols>)`, and stays
  connecting until a step answers it. The steps: `socket <n> open ["<protocol>"]`, `socket <n>
  message "<text>"`, `socket <n> binary <bytes>`, `socket <n> close <code> "<reason>"` (the
  server's close frame: the event, clean) and `socket <n> fail` (`error`, then `close` with 1006,
  not clean). The page's own calls are logged: `(socket <n> sent: "<text>")` and
  `(socket <n> close: <code> "<reason>")`. The fixtures are in `tests/corpus/browser/tea/`.
- **The server.** A `run/` fixture's `.requests` script (§9.10 (h)) gains WebSocket steps that
  the driver's own small RFC 6455 client runs: open a socket by name on a path, send a text
  message, read the next message or the close, send a close frame, send a raw frame for each
  fault of (f), stop reading, and drop the TCP connection. Each is printed in the transcript as a
  request is.
- **Both together** — the demonstration of #524: a server program and a page program in one
  fixture, the page loaded under the page driver with the host's real `WebSocket`, connected to
  the server the serve driver started. Its kind and its steps are specified with its slice
  (*Amended 2026-10-21*, below).

*Amended 2026-10-21, the page and the server together* ((l)'s last item; #524's demonstration;
#571). A page and a server that are both beni talk through a real WebSocket in one test:

- **The example.** `examples/chat/` holds three directories, as `examples/todo/` does: `shared/`,
  `server/` (`node`) and `page/` (`browser-tea`). `shared/Chat.beni` is the protocol: the events and
  their lines, and `tell`, which writes an event with `WebSocket.write`. It names only the handle
  operations that every platform shares (the amendment's item 1), so the page's build and the
  server's build check it, each on its own platform. The server serves the page's build and
  accepts sockets at `/chat`, and refuses one whose `origin` is another site's (item 21). It tells
  each page's events to every other page. The page holds its socket in a `listen` subscription,
  shows what the room says, and connects again after a wait when the connection ends. The wait
  is a second longer after each failure in a row, 30 seconds at most.
- **The page driver's `--server=127.0.0.1:<port>`** (happy-dom only) opens the page at
  `http://127.0.0.1:<port>/_page.html`, so a socket the page opens to `/chat` reaches the server
  on that port. The page's `WebSocket` is then happy-dom's own, which wraps the `ws` library, not
  the scripted one: it is the independent client of item 30. Item 30 named Node 24's own
  `WebSocket` (undici), which cannot run in the page: it calls `unref` on what `setTimeout`
  returns, and the page's virtual clock returns a number, as a browser's does. undici drives the
  server in `bench/websocket/load.mjs`. Each socket is still numbered and logged, and the scripted
  `socket` steps are refused. What the host's socket does (`open`, `message`, `error`, `close`) is
  held, in the order it happened, and reaches the page only in a step `socket <n> wait <k>`,
  `wait open` or `wait closed`. That step gives the page the held events one at a time, each in
  a task of its own, until the socket has received `k` messages in all, opened, or closed, and
  waits for the next event in real time, 5 seconds at most; then the page settles as after any
  step. So a snapshot depends on the script, and never on when the server answered. The socket's
  `protocol` is the one of the `open` the page was given; its `bufferedAmount` is still the
  host's at the time the page reads it (#632). In this mode the driver writes the line of each
  step it has run to file descriptor 3. `--wait-handshakes` tests the hold: after each step, the
  driver waits until the host has answered every socket's handshake, and lets the page settle
  again before the snapshot.
- **The serve driver's page steps.** `{"page": "<entry>", "steps": "<file>"}` runs a page under the
  page driver with `--server` set to the program's port and prints its transcript, each line
  `| …`. With `"wait": false` it runs beside the next steps. `{"page-wait": "<step>"}` waits until
  the page has run that step (the line on file descriptor 3), 5 seconds at most, and uses the
  lines up to it, so a second wait for the same step waits for the next one. `{"page-end": true}`
  waits for the page to end, 20 seconds at most, then stops it, and prints its transcript. So a
  script orders what the page and the driver's own clients do. With the page driver's hold, the
  order of the transcript depends on no timing. The time limits only stop a fixture that fails,
  and the driver ends after every script.
- **The test** is `tests/blackbox/chat_example_test.zig`. It builds the example as its README says,
  with a `Config` that listens on port 0, and runs the server under the serve driver. In its script
  the driver's own client and the page talk: the page connects, says a line, and hears the
  client's answer; the client hears the page join and speak; a socket from another site is
  refused; `/` is the page's shell and `/.env` is 404; the server shuts down and closes both
  sockets with 1001. The page then connects again after 1 s on its virtual clock, that attempt
  fails, and the next one starts 2 s later. The page runs with `--wait-handshakes`. Its last step
  fails, and the script's last waits find no step and no page, so the same script pins the serve
  driver's waits and its end.
- **The scripted `open` follows the handshake** (#571). `socket <n> open "<protocol>"` fails the
  step when the page did not offer that protocol, and `socket <n> open` with no protocol fails it
  when the page offered some: a host fails both handshakes (RFC 6455 §4.1, the Fetch standard's
  "establish a WebSocket connection"), so no golden shows a state that no browser reaches.
- **The owner's decisions** ((n); the owner, 2026-10-21, each as recommended). `ws-q1`: the
  wrappers take Elm's names — the command is `send` and the subscription `listen` — and the
  direct forms are `read`, `write` and `close` on every platform; Workers uses `write` too. So
  (a)–(d) stand as written. `ws-q3`: each host keeps its own reading style. `node` reads with the
  pull `read` session of (e)–(h), with read back-pressure; Cloudflare delivers events to
  handlers, so that an object can hibernate. Programs share the handle operations of item 1 and
  their logic as plain functions, as `examples/chat/shared/Chat.beni` does. Item 1's "until it is
  answered" is spent: (e)–(h) stay as written for `node`.

**(m) The game's load, measured.** The slices measure what the game does: a server with 100
players, each sent a 1 KiB state 30 times per second while it sends 5 small inputs per second;
the server's CPU time per message sent, and the time from a tick to the last client's read. In
the page, the cost of one received message from the host's event to `update` (happy-dom in Node,
as §9.8.11's commands are measured), and the page's bytes (`bench/size.mjs`, `--release`,
brotli). A cost that a profile shows — a copy of a message, an encoding per player — is fixed or
reported with its number.

**(n) The owner's decisions.**

- **`ws-q1`, the API of (a)–(d).** *Decided 2026-10-21 as recommended* (the amendment of
  2026-10-21, *the page and the server together*). *Recommended*: as written, which keeps §9.8.17's rule: the
  wrappers take Elm's names (`send`, `listen`), and the direct forms take other names (`read`,
  `write`, Effect's and the WHATWG `WebSocketStream`'s), so the names that a shared module uses
  are the same on both sides. *The other choice*: the direct forms take the host's names
  (`send`, `receive`), and the command takes a new name.
- **`ws-q2`, the server's upgrade of (e)** *(replaced by `ws-q3`, the server's reading style, on
  2026-10-20; item 1 of the amendment below)*. *Recommended*: a second handler in `listenWith`,
  which answers `accept session` or `refuse response`. `Request`, `Response` and `listen` do not
  change. *The other choice*: a request handler accepts the upgrade itself, which needs a field
  in `Request` that names the connection, and so changes the record that #331 settled.

*Amended 2026-10-20, after the two reviews of #531* (the review agent's findings H1–H4, M1–M10 and
L1–L13, and the bot's 19 points; their evidence is in the PR that adds this amendment). Each item
settles one finding. Where an item contradicts the text above, the item wins. No section is
renumbered.

**The shared surface (H1, M3, M10).**

1. **The surface splits in two.** The *handle operations* — `write`, `close`, `protocol`, `eq`,
   and the types `Close`, `WriteError` and `CloseError` — are shared by every platform that serves
   or opens a WebSocket. The *reading style* is the platform's: `browser` and `node` read with a
   pull `read`; a host that delivers events to handlers, such as a hibernating Durable Object
   (#526), cannot keep a fiber waiting in `read`, since its memory is reset between events. Which
   reading style a server uses on `node` and on Cloudflare is the owner's question `ws-q3`, which
   replaces `ws-q2` and `cf-workers-q2`; until it is answered, (e)–(h) stay as written for `node`.
   In either answer, programs share the handle operations and their logic as plain functions,
   not the code that reads: its types differ by platform.
2. **`buffered` and `drain` are not shared.** Cloudflare's `WebSocket` has no `bufferedAmount` and
   no back-pressure signal (workerd `v1.20260518.1`: `src/workerd/api/web-socket.h:360-393`, and
   `send` queues into an unbounded table, `web-socket.c++:617-618`), and an answer of 0 there is a
   wrong answer. On `browser` and `node`, `buffered` is a back-pressure signal, not one unit: the
   page answers the host's `bufferedAmount`, the UTF-8 bytes of the text of messages not yet sent,
   with no frame headers, a count that changes only between tasks — and answers 0 itself once the
   connection has ended, where `bufferedAmount` keeps counting; the server counts the bytes in Node's queue for the socket,
   frame headers included, and **not the kernel's send buffer**, which Linux lets grow to 4 MiB
   first (`tcp_wmem`; measured: 3 927 040 bytes on loopback before Node queued one byte). So a
   tick that skips a player whose `buffered` is over a limit skips only after that much backlog,
   about two minutes of 1 KiB states at 30 a second. A game that needs a shorter bound uses its
   own acknowledgements, or the input timeout of item 20. On both sides `buffered` is 0 once the
   connection has ended: nothing more is sent.
3. **The codes that `close` may send are the side's.** The page: 1000 and 3000–4999 (the WHATWG
   standard). The `node` server: 1000–1003, 1007–1009, 1011–1014 and 3000–4999; 1010 is a
   client's code (RFC 6455 §7.4.1), so the server's set has no 1010. Workers: the same set as the
   `node` server, as §9.12 (g) (PR #533) says, less any code the host refuses; the host itself
   takes 1000–4999 less 1004, 1005, 1006 and 1015 (workerd `v1.20260518.1`,
   `src/workerd/api/web-socket.c++:642-643`), so it
   refuses none of the set. A shared module that needs one answer on every side sends 1000 or a
   code from 3000 to 4999.

**The page (H4, M1, M2, M7, L1, L2, L4, L5, L10, L12).**

4. **An `error` alone ends the connection.** The standard fires `close` after every `error`, but
   WebKit fires `error` with no `close` when a connection fails (`failAsynchronously`,
   `didReceiveMessageError`), and Chrome fires `close` 1006 with no `error` when the network drops.
   So the page takes whichever comes first: an `error` ends a connection that is open with 1006
   (rule 4 of (a)), and one that never opened with `Failed Unreachable` (`Err Unreachable` from
   `connect`). A `close` that follows finds the connection ended and adds nothing. The page driver
   gets a step, `socket <n> error-only`, that fails a socket as WebKit does.
5. **A fragment is any `#` in the serialised URL.** `new URL("ws://a/#").hash` is `""`, but the
   fragment is not null and the constructor throws. Step 1 of (c) therefore tests the URL's `href`
   for `#`.
6. **`Blocked` is what a browser reports at once, and browsers differ.** The current standard
   throws no `SecurityError` (whatwg/html removed it in 2016): mixed content, a bad port and a CSP
   refusal are network errors, and so `Unreachable`. Chrome still throws `SecurityError` for an
   insecure `ws:` socket from an `https:` page, and Safari for a socket that the page's CSP
   forbids; Firefox throws for a CSP refusal too, with a name not yet verified (#542). The catch
   takes `SecurityError` only, so a browser that throws another name stops the page: #542 owes
   that check in a real Firefox.
7. **`Task.timeout` around `connect` limits the whole session, not the open**, because `connect`
   calls `use` inside itself. (b)'s sentence about it is withdrawn. A time limit on the open alone
   is #544.
8. **The page cannot pause a socket**, so the messages of a `connect` socket that no one reads are
   kept with no bound, as the host keeps its events. A program that connects reads.
9. **A declaration that joins a live `listen` key gets no `Opened`.** That is intended: the socket
   lives in the model of the program that held the key when it opened, and a component gets it
   from there. Two components that need two connections use two keys.
10. **What the server sees of the page's 1003.** The page cannot send 1003 ((j)), so it closes with
    no code, and the server sees 1005. The page reports 1003 to its own program. For a binary
    message, the two sides therefore do not report one code: a shared module's arm for it is 1003
    on the page and 1005 on the server.
11. **`connect`'s acquire does not wait.** `Task.bracket`'s acquire is uninterruptible
    (`core/Task.beni`), so `connect` makes the socket in the acquire and waits for the open in the
    use, where a cancellation reaches the wait.
12. **`Ok` from `write` means queued, not delivered.** The host can still fail the connection
    later (a buffer that is full, a network that drops), which the program sees as the end.
13. **`Unreachable` is not `Http.NetworkError`** because a refused handshake is also `Unreachable`:
    the server answered, but not with a WebSocket.

**The server (H2, H3, M4–M6, M8, M9, L3, L7, L9).**

14. **`drain` does not wait for Node's `drain` event.** Node emits `drain` only after a `write()`
    that returned `false`, so a program that wrote less than the high-water mark and then calls
    `drain` waits forever. `drain` answers at once when the socket holds nothing to send, or the
    connection has ended. Otherwise it waits for the callback of the last write, which Node calls
    when that chunk is flushed (callbacks run in order), or for the socket's `close`. A callback
    that gets an error — any code of item 15 (a peer's reset gives `ECONNRESET` to every pending
    write), `ECANCELED` for a write pending at `destroy()`, or `ERR_STREAM_DESTROYED` — ends the
    wait. The connection itself ends through the socket's `error` event, or its `close`.
15. **One client's network failure ends that connection, never the process.** On an
    established socket, Linux keeps the error of each ICMP message it gets (`tcp_v4_err`,
    `tcp_ipv6.c`), and when the retransmissions time out the socket ends with that error, or with
    `ETIMEDOUT` when there is none (`tcp_timer.c`). The errors come from two kernel tables:
    `icmp_err_convert` (IPv4) and `icmpv6_err_convert` (IPv6, which adds `EACCES` for a firewall's
    "administratively prohibited"). So a socket's `error` with any of these codes, by the names
    that Node gives them, ends that connection with 1006: `ECONNRESET`, `EPIPE`, `ETIMEDOUT`,
    `ENETUNREACH`, `EHOSTUNREACH`, `EHOSTDOWN`, `ENONET`, `ENOPROTOOPT`, `ECONNREFUSED`, `ENOTSUP`
    (libuv's name for errno 95, which the kernel calls `EOPNOTSUPP`), `EPROTO`, `EACCES`,
    `ECONNABORTED` and `ENETDOWN`, and `ENETRESET`, which macOS and the BSDs report for a
    connection that a network reset broke. libuv has no name for `ENETRESET`, so Node's `code`
    for it is not `ENETRESET`: the platform matches it by its number, an `errno` of
    `-os.constants.errno.ENETRESET`. Any other code is a defect, as (i) says: `ENOBUFS`,
    for one, is the machine's lack of buffers, not one client's failure. `ENOTCONN` is not in the
    list: Node ignores it at shutdown (`net.js:684`), so a socket never emits it. A `write` to a
    socket that Node has ended or destroyed would fail with `ERR_STREAM_WRITE_AFTER_END` or
    `ERR_STREAM_DESTROYED`; the platform tests the socket first, so the program gets
    `Err NotOpen` and Node is not called.
16. **The platform adds its `error` listener in the `upgrade` event itself**, before it checks the
    handshake or calls the program's handler. An upgraded socket arrives with none, so a reset
    while the handler decides is otherwise an uncaught exception. The upgrade's request has no
    body to read, and the platform adds no listener to it: an `error` on it is a defect.
17. **A client that ends TCP with no close frame ends the session.** An upgraded socket is half
    open (`allowHalfOpen: true`): after the client's FIN only `end` fires, and the socket stays
    writable. On `end`, the platform ends the connection with 1006, unless a close frame was
    already received (then the end is that frame's), and ends the socket with `destroySoon`, so a
    close frame this side is still writing is flushed first. Messages that arrived before the FIN
    are still read before the end.
18. **After a close frame is sent or received, reading goes on and data frames are dropped.** A
    paused socket sees no close frame, FIN or RST: without this rule, every such close ends at
    the 5-second limit with 1006. Messages that arrive after this side sent its close frame are
    dropped on both sides: the page's host drops them, and the server does the same.
19. **The memory of a paused connection.** `socket.pause()` does not stop Node at once: it reads
    on until its own buffer holds 64 KiB. So a connection holds about `maxMessage` and 128 KiB,
    and the kernel's buffer, not `maxMessage` and 64 KiB as (h) says.
20. **The server turns TCP keep-alive on** for each upgraded socket:
    `setKeepAlive(true, 30000, 10000, 3)`, a first probe after 30 seconds idle, then one every 10
    seconds, and the end after 3 unanswered (Node 24.19 sets all three). So an idle connection
    whose client vanished ends with 1006 in about a minute. **This does not cover a server that
    sends all the time**: Linux sends no keep-alive probe while data is in flight
    (`tcp_keepalive_timer`, `tcp_timer.c`), so the snake arena, which writes 30 states a second
    to each player, finds a vanished player only at the retransmission timeout (about 15 minutes
    with Linux's default `tcp_retries2`), and then with a code of item 15. Such a server finds a
    dead client through its own timeout: a live player sends inputs 5 times a second, so the
    session reads with `Task.timeout` around `read` and closes the connection when no input came
    for a few seconds. Pings that the server sends are #536.
21. **`Origin` is the program's.** `accept` checks nothing. A server whose clients use cookies
    checks `Server.header request "origin"` and answers `refuse` to a stranger (RFC 6455 §10.2):
    without the check, any page can open a socket with the user's cookies. (e)'s example now does.
22. **What the handshake checks.** Node sends a request to `upgrade` only when `connection` holds
    the token `upgrade` and an `upgrade` header exists; a request with `upgrade: websocket` and no
    `connection: upgrade` is an ordinary request. Node does not check the method, the version of
    HTTP or the `host` header, so the platform does (RFC 6455 §4.2.1): `GET`, HTTP/1.1 or later,
    a `host` header, `sec-websocket-version: 13` (else 426 with `sec-websocket-version: 13`), and a
    `sec-websocket-key` that is the base64 of 16 bytes: exactly 24 characters, 22 of the base64
    alphabet, the last of them `A`, `Q`, `g` or `w`, then `==`. The test is on the text, since
    `Buffer.from(…, "base64")` skips other characters and accepts bad padding; two keys arrive
    joined with `", "` and fail it. Any other fault is 400. `upgrade` is a
    comma list matched without case: a request reaches the `upgrade` handler when one of its tokens
    is `websocket`.
23. **`protocols request`** splits each `sec-websocket-protocol` value at its commas, trims each
    entry, and drops an empty entry or one that is not a token, in the client's order.
    `acceptWith`'s protocol must be one of them, so it is a token and cannot split the response.
24. **`maxMessage` below 0 is 0**, only empty messages, and **above 2³² − 1 is 2³² − 1**, the
    nearest meanings (`transparent-effects-proposal.md` §17.1 item 4). So a frame's length past
    2³² is over every `maxMessage`: the codec tests the high 32 bits first and never depends on a
    double's precision.
25. **A ping flood is bounded.** While more than 64 KiB wait to be sent, the server answers no
    ping at once: it keeps only the latest ping's data, drops the earlier ones, and answers the
    latest when its buffer drains, as RFC 6455 §5.5.3 allows.
26. **The siblings meet by value.** `Server.js` and `WebSocket.js` cannot import each other
    (`backend.md` §2): the upgrade's record, which `Server.js` makes and `WebSocket.js` takes,
    carries the socket, the `head` bytes and the functions each side gives the other, as
    `Browser.js` reaches the render loop (§9.8.7).
27. **One state, one encoding.** A server frame is not masked, so one state sent to every player
    is the same bytes. The platform keeps one cache for the whole process, not one per socket: the
    last text that `write` framed, and its frame. A `write` of the same text to any socket reuses
    the frame, so a broadcast encodes once.
28. **Smaller points.** UTF-8 is checked per whole message, not per fragment. An upgraded socket
    has no timer (`server.timeout` is 0, and the parser's timeouts end with the upgrade), so the
    platform sets none. A client that leaves while `upgrade` runs does not stop that handler
    (#337); its answer is dropped. An upgrade accepted after `Server.close` stays 101 and then
    1001, so its session runs as every other one does. The 5-second closing timer starts when this
    side sends its close frame (the 1001 for `Server.close`), and it is `unref`'d.

**The rest (L6, L8, L11, L13).**

29. **W52 (§9.8.9)** asked for an `equatable foreign type`; `equatable` is core's alone, so a
    platform gives its handle a `pub eq` instead (`static-dispatch-spike.md` §3.5's audit gains
    the row with this amendment). §9.10 (c)'s and (e)'s `upgrade` rows describe `listen`, which
    has no upgrade handler; with `listenWith`, (e) of this section applies.
30. **Tests.** A shared module that checks under `browser-tea` and `node` is slice (d)'s fixture.
    The serve driver keeps its own RFC 6455 client, which prints the handshake and sends the
    frames that no conforming client sends; slice (d) also drives the server with Node 24's own
    `WebSocket` (undici), an independent client. An Autobahn run is #540.
31. **Every item of (o) has an issue**, listed there now.

**(o) Not in this slice.** Each has an issue: binary messages (j), #535; the
`permessage-deflate` extension, #539; pings that the server sends to find a client that is gone,
#536; settings for the 5-second closing time and the 64 KiB read buffer, #537; a WebSocket client
on `node` (Node 24 has the WHATWG `WebSocket`, so `browser`'s module could serve it), #538; the
`browser-inline` platform, which has no fibers, though `listen` needs none, #543; a time limit on
the page's open, #544; a check of Firefox's and WebKit's failures in real browsers, #542; and the
Cloudflare Workers platform (#526), which shares the handle operations (item 1 of the amendment
above).

*As built, 2026-10-20, the page* (`platforms/browser/WebSocket.beni`, written over `Js` with no
sibling; `browser-tea` re-exports it; `tests/browser/driver.mjs`'s scripted socket), as (b)–(d)
and (j) say, with these readings:

- **A socket is one object** that both forms share: the host's socket, the messages no one has
  read, the fibers waiting in `read`, the open's waiter, the end, and the subscription's send.
  `listen` hands every message to its subscription and none to `read`; `connect` queues them for
  `read`. Its host listeners are added once, when it is made.
- **An `error` ends the connection by itself**: 1006 once open, `Unreachable` before. The
  standard fires `close` after every `error`, but WebKit fires `error` alone when a connection
  fails, and a `connect` or a `read` that waited for `close` would wait forever. A `close` that
  follows finds the connection ended and reports nothing more. The driver's `socket <n>
  error-only` step fails a socket so, and `WebSocketChat` uses it before and after the open.
- **A fragment is any `#` in the serialised URL**, so `"/chat#"`, whose `hash` is `""`, is
  `BadUrl` too; the constructor's `SyntaxError` for it is never reached.
- **`Blocked` is what a host reports at once**: Chrome's `SecurityError` for an insecure socket
  from an `https:` page, and Safari's for one the page's CSP forbids. Firefox and Safari fail an
  insecure socket later, which is `Unreachable`. Whether Firefox's refusal of a socket its CSP
  forbids is a `SecurityError` is not checked yet (#542).
- **`buffered` is 0 once the connection has ended**, though the host's `bufferedAmount` keeps
  what was never sent: nothing more will be.
- **The console's line for a binary message names the URL as the program wrote it**, not the
  resolved one, so the line is the same on every host and port.
- **The scripted socket** checks what the standard checks (the URL, its scheme and fragment, each
  protocol; the codes and the reason of `close`; `send` while connecting), so a platform that
  hands the host what it refuses meets the host's own exception. Its steps are `socket <n> open
  ["<protocol>"]`, `message "<text>"`, `binary <bytes>`, `close <code> "<reason>"`, `fail`,
  `error-only` and `buffered <bytes>`, then `socket blocked` (the next constructor throws `SecurityError`) and
  `sockets` (those made and not closed); `tests/corpus/README.md` has them.
- **The URL is parsed with `URL.parse`**, which answers null for what does not parse, so no
  catch is needed; `new URL` inside `Js.catchIf` that takes only a `TypeError` is for an engine
  with no `URL.parse`, as step 1 of (c) says.
- **Fixtures** (`tests/corpus/browser/tea/`): `WebSocketChat`, `WebSocketDirect` (with a defect
  while `connect` holds a socket), `WebSocketFailures` (with the empty fragment `"/chat#"`),
  `WebSocketLifetime` and `WebSocketEquality` (a socket compared with itself and with another by
  `==`, `≠`, `Basics.eq` by name and as a value, in a record and in a `Maybe`), each also run with
  its listeners in fibers (`--fiber-page`), against the same golden.
- **Measured** (`--release`, one file, brotli 11): a `Tea.element` page that uses `listen` and
  `send` is 4 679 bytes, against 3 789 for a page with another `Sub.on` listener
  (`Navigation.onUrlRequest`) and 1 152 for the empty `Tea.element`: the module costs about 890
  bytes. One received message, each in a task of its own and each a new state of 936 bytes,
  costs about 4.3 µs from the host's `message` event to `update` and the render (happy-dom in
  Node, 20 000 of each, `bench/websocket/page.mjs`); the same page written by hand in JavaScript
  costs 6 to 7 µs in that benchmark, and 4.2 to 4.6 µs in the review's own version of it: beni
  costs what hand-written JavaScript costs. A click on the same page costs about 7.5 µs. The
  event's string reaches `update` as it is, with no copy. A constant state is cheaper, about 3.5
  µs, only because the view then has no text to write.

### 9.12 The `cloudflare` platform: Workers and Durable Objects (2026-10-20)

*Added 2026-10-20, for issue #526. Status: specified, not built. Three decisions are the owner's
and are asked on the dashboard (`cf-workers-q1` to `q3`): the platform's name, the shape of a
Durable Object in beni, and how the object classes reach the entry file. The text below assumes the
recommended answer to each — `cloudflare`, direct handlers over an explicit state, a list in the
app's manifest — and (l) records the answers as they come. *Every question is answered
(2026-10-21)*: (e) and (f) are rewritten to the owner's design for the object (handlers that may
suspend, one event at a time, one fiber runtime per object), (d) to his design for the Worker
(q7: an ordinary handler with a scheduler and a scope per request), and the rest reads as decided. Every statement about the host cites
Cloudflare's documentation as read on 2026-10-20; a statement marked* measured *was checked under
`workerd` (version 1.20260518.1, the one nixpkgs' `wrangler` 4.93.0 bundles; a source line cites
that tag), and one marked* owed *has not been. Amended 2026-10-20 after the review of this
section (`cf-workers-review`, its H1–H6, M1–M12 and L1–L7): each amendment is marked* amended
2026-10-20 *where it stands.*

**(a) The host, in beni's terms.** A Worker is an ES module whose default export has a `fetch`
handler, called once per request with the request, the bindings (`env`) and an execution context
([the `fetch` handler](https://developers.cloudflare.com/workers/runtime-apis/handlers/fetch/)).
Timers and `fetch` "are only available inside of the Request Context"
([web standards](https://developers.cloudflare.com/workers/runtime-apis/web-standards/)), so what
the entry file runs at module evaluation — `run(main)` — may start nothing: it builds the handler
table and returns it. A Durable Object is a class the Worker's main module exports, named in the
Wrangler configuration; one instance per id, and the host delivers its events — a request, a
WebSocket message, a close, an error, an alarm — to one method each
([the base class](https://developers.cloudflare.com/durable-objects/api/base/)), in series except
where a method waits for I/O that is not storage ((e), *Order*; an alarm "can run concurrently with
another request", the state page). "When hibernated,
the in-memory state is discarded", and a hibernated object's WebSockets "stay connected"; the
object hibernates "after 10 seconds of no incoming request or event" when no timer is set, no
promise is pending and no request is in flight, and after 70 to 140 seconds of inactivity it is
evicted; an incoming request or event while it is hibernated runs the `constructor()` again
([lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)).
*Amended 2026-10-20 (M4):* what keeps an object from hibernating, by the same page, is a set
timer, unfinished I/O or a promise given to `waitUntil`, an open outbound connection, a socket
accepted with the standard `accept()` and its listeners, or an event in progress; a parked beni
fiber is none of these, (g). A code deploy disconnects every WebSocket.
A WebSocket accepted with `ctx.acceptWebSocket` is delivered to the class's `webSocketMessage`,
`webSocketClose` and `webSocketError` methods and may hibernate; `serializeAttachment` keeps up to
16 384 bytes with the socket across hibernation
([WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/),
[`ctx`](https://developers.cloudflare.com/durable-objects/api/state/)). An object schedules one
alarm at a time, delivered to `alarm()` at least once, and retried on an uncaught exception
([alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)). A SQLite-backed object
has a synchronous key-value store, `ctx.storage.kv`
([storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)); its key and
value together may hold 2 MB ([limits](https://developers.cloudflare.com/durable-objects/platform/limits/)).
Each of these is one piece of the API below, and nothing else of the host is reached.

**(b) The package.** `platforms/cloudflare/`, embedded like `node` (§5.3): a fifth platform in
the binary, beside §9.1's four (*amended 2026-10-20, L5*; §5.1 and §9.1 carry a dated line each).
Its manifest:

```json
{
  "platform": true,
  "name": "cloudflare",
  "program": "Worker.Program",
  "runtime": "runtime.js",
  "entry": "_worker.mjs",
  "exports": "program"
}
```

It depends on no platform and declares no markup: a Worker that renders HTML wants the `ssr`
lowering, which is (j)'s. Four modules, each the host's own words (`WebSocket`'s are §9.11's):

| Module | Holds |
|---|---|
| `Worker` | the host types a Worker and an object share — `Program`, `Request`, `Response`, `Env`, `Context` (a request's), `Namespace msg`, `Ref msg`, `Service`, `Definition` — with `program`, the request and response operations, the bindings, `forward`, `callService` and their errors. It imports no module of the platform. *Amended 2026-10-21 (q7, q8): `Stub` became `Ref msg`; the object's `Context msg` moved to `Worker.Object`* |
| `WebSocket` | the server WebSocket: the handle operations §9.11's amendment (item 1) shares, `id`, `tags`, the attachment. It imports `Worker` |
| `Worker.Object` | `define`, `Context msg`, the handlers over `Worker.Definition`, `self`, `post`, `ask`, `reply`, `accept` and `autoReply` for sockets, `tick`, alarms, the attached sockets. It imports `Worker` and `WebSocket` |
| `Worker.Storage` | the object's key-value store, through schemas. It imports `Worker` and `Worker.Object` |

*Amended 2026-10-20 (H1); 2026-10-21 (q8).* The modules form no cycle (`fast-compiler.md` §3.1
forbids one): `Worker` holds the shared host types and imports nothing; `WebSocket` imports
`Worker` for `Request` and `Response` and knows no object; `Worker.Object` imports both, takes
`WebSocket.Socket` and `WebSocket.Close` in its handlers, and holds `accept` and `autoReply`,
which need its `Context msg`; `Worker.Storage` takes `Worker.Object.Context msg`.
`Worker.Object.define` answers a `Worker.Definition`, the type `Worker.program`'s `objects` lists.

`runtime.js` is the one file that defines a JavaScript class: the Durable Object classes the
entry file exports, one per `Worker.Object.define`, each a subclass of `DurableObject` from
`cloudflare:workers` whose methods hand every event to beni. Everything else is beni over `Js`
and siblings of §4's shape. A sibling reaches `Response`, `WebSocketPair` and the other host
globals that §5.1's common set does not list through `globalThis`, as `platforms/browser/Dom.js`
reaches `document`; check 3 is lexical and that is the edge it makes visible.

**(c) The entry file, and the `"exports"` output key** (a compiler change, the one §5.1's "not a
compiler change" did not foresee: ES module exports are static, and a Durable Object class is found
by its export name — `class_name` in the binding, and the key of the `exports` field, of the
Wrangler configuration ([configuration](https://developers.cloudflare.com/workers/wrangler/configuration/#durable-objects)) —
so the names must be known when the entry file is written). §5.2's amendment of this date adds the
key; this is its whole contract.

- **The platform manifest** declares `"exports": "program"`. Any other string, or a list, is
  `unknown_exports_mode`, reported against the manifest at `1:1` with no excerpt, as
  `invalid_entry_file` is; a value of another JSON type is the manifest's exit-2 failure, as any
  key of the wrong JSON type is (*amended 2026-10-21, P599-5*). Inherited first-found down the
  chain like every output key (§9.1).
- **The app's `beni.json`** lists the names: `"exports": ["Arena"]` (`frontend.md` §10.1). Each
  is an ASCII identifier name — letters, digits, `_` and `$`, not beginning with a digit; the
  check is ASCII only because the name is printed into the entry file without escaping, as the
  entry name's is — not `default`, not `flush`, and no name is listed twice (*amended 2026-10-21,
  P599-1 and P599-3: the hoisted release file re-exports the runtime's `flush` when the build
  keeps it, `backend.md` §15.11, and a module that exports one name twice does not load, measured
  in Node 24 as `SyntaxError: Duplicate export of 'flush'`; the refusal is static, the same in
  both builds, where a test of the runtime's exports would follow reachability and differ between
  them; `stop` is not refused, because only a runtime module supplies it and this key refuses a
  runtime module*); otherwise
  `invalid_entry_export`, a diagnostic of the build reported during emit against the app's
  manifest at `1:1`, naming the entry, as `invalid_entry_file` is (exit 1; a `"exports"` that is
  not a list of strings is the manifest's exit-2 failure, as any key of the wrong JSON type is,
  `frontend.md` §10.1). No reserved-word rule is needed (*amended 2026-10-20, M7*): a name is
  written only as an export name, never as a binding. With the key absent, the list is empty. A
  list on an app built for a chain that declares no `"exports"` does nothing, and a list that does
  nothing is almost always a mistake, so it is the warning `exports_ignored` (rule 7), naming the
  platform. Two `define`s of one name are `exports`'s to refuse at load, like a name defined by
  none ((e)).
- **The entry file** is, in a development build (being built in slice (b), with the fixture
  `run/EntryExports` and a paragraph of `backend.md` §2),

  ```js
  // Generated by `beni build` (docs/design/boundary.md §5.2): the entry file
  // the platform's output shape asks for.
  import { run as $run } from "./_platform/runtime.foreign.mjs";
  import { Main$main as $main } from "./Main.mjs";

  const $beniProgram = $run($main);
  export default $beniProgram.default;
  const $beniExport0 = $beniProgram.exports("Arena");
  export { $beniExport0 as Arena };
  ```

  *Amended 2026-10-20 (M7); 2026-10-21, the names.* The entry's own bindings begin with `$`,
  which a listed name may hold too (*2026-10-21, P599-3: an export name is a namespace of its own
  that no binding meets — measured in Node 24, a module that binds `$beniProgram` and writes
  `export { $beniExport1 as $beniProgram }` loads*); `$beniProgram` and `$beniExport<N>` are longer than any short
  name the release renamer spells (`src/js/Rename.zig`: eight characters at most, from an alphabet
  that holds `$` and `_`, so a short `$p` is possible and `$beniProgram` is not), which matters in
  the hoisted release file where they stand among short names, while `$run` and `$main` are safe
  because the development entry file holds no short name at all; a listed name is written only in an
  `export { … as Name }` clause, where any identifier name is legal — a reserved word included —
  so no name can collide with `run`, `program`, `start`, `flush`, `stop`, the imported `main` or a
  release build's short name (measured: `run`, `program` and `Main$main` as plain `export const`
  names broke the file). The hoisted `--release` file writes the same bindings at its end.

  and under `--release` the same statements with the header and the whitespace gone, `Main$main`
  spelled as the exporting module spells it (§9 item 2 of `backend.md`). The names come in the
  manifest's order, one `const` and one `export { … as Name }` each, so the file is a function of the program and the
  manifest alone (rule 5). `--library` writes no entry file and ignores the list.
- **What `run` returns** when the chain declares the key: an object with `default`, the value of
  the default export, and `exports`, a function called once per listed name at load, whose answer
  is that name's export. A name the program defines nothing for is `exports`'s to refuse: it throws
  an `Error` whose message names the export and the manifest key, so the Worker fails to load with
  that message rather than exporting `undefined` and failing in Wrangler's words. Without the key,
  `run`'s result is not read, as today.

**(d) `Worker`: the program and the request handler.**

*Amended 2026-10-21, twice. First Jayson's answer to `cf-workers-q4` ((l)): a `sync` `fetch` that
answers an `Answer` value the host runs — the form `respond | forward … (StubError → Response) |
serve …`, whose constructors carried the `sync` mark in their signatures, since the marker is
legal only in a top-level or `foreign` signature (§4; `src/parse/Parse.zig`). Then Cesar's
answer to `cf-workers-q7` (12:17 UTC), **B, the final design, which replaces q4's form**: the
Worker's `fetch` is an ordinary beni function, as an object's handlers are ((e.1)).*

```elm
module Worker   -- the one live declaration of the module (R6-1)

pub foreign type Program
pub program : { fetch : Context, Request → Response, objects : List Definition } → Program

pub foreign type Context                 -- a request's: its bindings, its scope, `waitUntil`
pub env : Context → Env
pub foreign type Definition              -- a Durable Object class, made by `Worker.Object.define`
pub foreign type Ref msg                 -- a typed reference to an object of protocol `msg`: `Object.self`, or one from a `Namespace msg` ((e.10))

pub foreign type Request                 -- the host's `Request`, read through these
pub method : Request → String            -- upper case, as the host gives it
pub url : Request → String               -- the full URL as the host gives it: "https://h/arena/x/ws?k=v"
pub path : Request → String              -- its `pathname`, "/arena/x/ws"
pub header : Request, String → Maybe String    -- the header's value, the name in any case; the host joins repeats with ", "
pub headers : Request → List (String × String) -- names lower-cased, sorted by name as the host keeps them; repeats joined with ", "
-- A Worker's `fetch` reads no body in this slice ((j)): the stream is the host's, forwarded whole.

pub opaque type Response
pub text : Int, String → Response        -- `content-type: text/plain; charset=utf-8`
pub html : Int, String → Response        -- `content-type: text/html; charset=utf-8`
pub empty : Int → Response               -- no body
pub withHeader : Response, String, String → Response   -- appended; a repeated name is written twice; an `x-beni-` name is an invalid response (R6-7)
pub redirect : Request, String, Int → Response   -- `location`: the target resolved against the request's URL; 301, 302, 303, 307 or 308

pub foreign type Env
pub objects : Env, String, Schema e msg → Maybe (Namespace msg)   -- the Durable Object binding of that name, as objects of that protocol ((e.10))
pub service : Env, String → Maybe Service      -- a service or assets binding: anything with `fetch`
pub var : Env, String → Maybe String           -- a plain-text variable or secret

pub foreign type Namespace msg
pub byName : Namespace msg, String → Ref msg   -- `getByName`: the one object of that name
pub unique : Namespace msg → Ref msg           -- `newUniqueId`, then `get`: a fresh object; its id is `refId`
pub byId : Namespace msg, String → Result IdError (Ref msg)   -- `idFromString`: the id a `unique` ref reported through `refId`
pub refId : Ref msg → String                   -- 64 hex digits
pub refName : Ref msg → Maybe String           -- the name `byName` was given; `Nothing` otherwise

pub type IdError = InvalidId                   -- the host's `TypeError`, "Invalid Durable Object ID"

pub forward : Ref msg, Request → Result StubError Response        -- waits; the host's Response, body stream untouched
pub type StubError
    = Overloaded                               -- the error's `overloaded` is true: send fewer, or spread the load
    | Reset                                    -- `durableObjectReset` is true: the host reset the object; the call may be made again
    | Transient                                -- `retryable` is true and neither of the above: the connection, a shutdown; the call may be made again
    | Cycle                                    -- the call's chain already holds a handler parked in the object called ((e.3)); the call is refused at once

pub foreign type Service
pub callService : Service, Request → Result ServiceError Response  -- waits; an assets or service binding
pub type ServiceError = Unavailable            -- `retryable` is true: the call may be made again
```

- **`fetch` is an ordinary handler, and its effects are inferred.** It may wait — on `forward`,
  `callService`, an `Object.ask` ((e.10)), `Task.sleep`, a `Task.join` — and a `fetch` that never
  waits runs to its end inside the host's handler at the cost of a plain call. No marker.
- **The form q4 took, as the record** (replaced by q7, above): a `sync` `fetch : Env, Request →
  Answer`, where `Answer` was an opaque value built by `respond`, `forward` and `serve`, each
  carrying a `sync` recovery (`StubError → Response`) in its top-level signature, since the
  marker is legal only there; the runtime returned the host's promise itself and no fiber ran in
  a Worker. It is prose here and no declaration, so the module is declared once.
- **One scheduler and one scope per request.** Each request runs on its own scheduler
  (`Task.withScheduler`, #596) and in its own scope, so a fiber never resumes in another request's
  I/O context — the measured hazard below cannot arise — and a defect fails only its own request:
  the throw leaves the request's drain, the host answers the client with 1101, the request's scope
  is closed (its fibers cancelled, their finalisers run), and no other request is touched. **The
  Worker slice therefore depends on #596** before it can be built.
- **`forward ref request` waits** and returns the host's `Response` with its body stream
  untouched, so the 101 of an upgrade and a streamed body pass through; it carries the chain id
  ((e.3)) — a fresh one, after stripping every `x-beni-` header the client sent (*amended
  2026-10-22, P723-1*: not the chain alone — the ask id and the origin mark of (e.10) too — and a
  path that holds `/__beni/` is answered 404 by `forward` itself, never sent, since the platform's
  paths are no page of the program's; a `--test-hooks` build lets its two hooks through). Its failures are
  *What a stub's failure becomes* below. **Typed asks to an `Object.Ref msg` are ordinary waits**
  ((e.10)), under the same cycle rule. *Two names differ from the owners' words (R6-6): the owners
  wrote `Object.Ref msg`, and the type is `Worker.Ref msg`, because `Worker.forward` takes a ref
  and `Worker` imports no other module of the platform (H1) — `Worker.Object` declares `pub type
  alias Ref msg = Worker.Ref msg`, so `Object.Ref msg` names the same type (*R7-4*: importing a
  type is not a re-export); and the owner wrote
  `Worker.forward stub req`, where this text writes `ref`, because q8 replaced stubs with typed
  refs.*
- **Fibers that outlive the response** — spawned in the request's scope and still running when
  `fetch` returns — run under `ctx.waitUntil`, with the host's 30-second cap after the response
  ([context](https://developers.cloudflare.com/workers/runtime-apis/context/): work may run "for
  up to 30 seconds after the response is sent or the client disconnects", and "if any Promises
  have not settled after 30 seconds, they are canceled"): what they do is delivered at most once.
  **The platform's deadline** (R6-3): the host says nothing of code after its cap, and
  continuations of an ended request context are dropped, so the platform itself closes the
  request's scope **5 seconds before the cap** — at 25 seconds after the response, a value #600's
  measurement settles — with §9.8.14's teardown under the `cloudflare` platform's `deadline`,
  1 000 ms, as `browser`'s (§9.8.14, choice 3) and `node`'s shutdown, and holds the teardown's
  promise in the same `waitUntil`; a finaliser therefore runs if it finishes within that
  deadline, and a fiber the platform
  cancels there has its finalisers run before the host's cap (*wording, 2026-10-21, R7-6*). That the host honours the held teardown is a fact to
  establish (#600, (k)).
- **A client disconnect interrupts the request's scope**, so finalisers run: the platform listens
  to `request.signal` where the host provides it (`enable_request_signal`, (i)), and the abort
  starts the same teardown, held in `waitUntil` — the host gives it the same 30 seconds "after
  … the client disconnects" — under the same `deadline`. That the hold works after an
  abort is #600's second half.
- *Amended 2026-10-22 (the Worker slice, as built).* **The scheduler per request, as built**
  (`platforms/cloudflare/Worker.beni`, `handle`): the host's `fetch` makes a scheduler with
  `Task.schedulerWith`, whose `run` queues each drain through a promise made in the request's own
  context and re-armed from inside its reaction — a reaction registered in a request's context runs
  there whoever resolves the promise (*measured*, above) — and starts the handler with
  `Task.spawnDetached` from inside `Task.withScheduler` outside any fiber, so the handler's first
  step is already the scheduler's. The fiber resolves the host's promise with the response; a throw
  leaves the drain, the scheduler stops, its hook stops the scheduler with §9.8.14's deadline and
  holds the teardown's promise in `waitUntil`, and the throw reaches the host's promise through the
  trampoline's chain (`then(null, reject)`: handed on unchanged, nothing caught), so the host
  answers 1101 with it. **A fiber that outlives the response is one `fetch` started with
  `Task.spawnDetached`**; a `Task.spawn` child ends with `fetch`'s fiber, as everywhere. After the
  answer, the platform asks `Task.schedulerBusy`: with no fiber running the scheduler is stopped at
  once, so it leaves the kernel's list (*P705-1*); otherwise a promise is held in `waitUntil` that
  `Task.onSchedulerIdle` settles when the last fiber ends, stopping the scheduler then, or the
  deadline's timer settles by stopping it. A throw out of a drain after the answer is thrown
  again from the trampoline's chain, where it is an unhandled rejection the host reports: never
  dropped in silence (*P705-2*, rule 9). The scheduler's continuation after 64 resumptions is a
  timer of zero in the request's context (`schedulerWith`'s `more`, §17.5), so a request that
  keeps yielding starves no other request of the isolate (*P705-5*). One path keeps a scheduler
  listed: a request that never answers — one the host cancels as hung — reaches neither the
  answer, nor a defect, nor an abort, nor the deadline, which starts after the answer; its
  scheduler stays in the list with the request's objects (*R2-6*, an edge; #707). **A Worker's `forward` starts a fresh
  chain per call** (`crypto.randomUUID()`), since a Worker parks in no object and so begins no
  cycle; an object's `forward` passes its chain on ((e.3), the object slice). **Two requests do not
  wait on each other through memory** (*measured* under workerd): a request parked on a wait that
  no host operation of its own will answer — a `Deferred` another request completes — is cancelled
  by the host as hung ("the Workers runtime canceled this request because it detected that your
  Worker's code had hung"); coordination between requests goes through a Durable Object, and two
  requests need not share an isolate in production. The per-request scheduler is for a request's
  own I/O: two requests parked on their own timers each answer in their own context (the fixture
  `workers/CrossRequest`).

The example of (i) becomes:

```elm
route : Worker.Context, Request → Response
route ctx request =
    case ( Worker.objects (Worker.env ctx) "ARENAS" arenaMessage, arenaOf (Worker.path request) ) of
        ( Just arenas, Just name ) →
            case Worker.forward (Worker.byName arenas name) request of
                Ok response → response
                Err _ → Worker.text 503 "the arena is not available"

        _ →
            Worker.text 404 "no such page"
```

*The bullets below are the record of the first text and its amendments; where one disagrees
with the block above, the block holds.*

- **`fetch` runs in a fiber of its own per request** *(the record; (d)'s amendment above says how,
  with a scheduler and a scope per request)*, started with `Task.start` from the host's
  `fetch` handler, which returns a promise resolved with the `Response` the fiber ends with. The
    handler may suspend: `forward`, `callService` and `Task.sleep` park it.
  The host may cancel the request's tasks when the client disconnects or the response is complete
  ([limits](https://developers.cloudflare.com/workers/platform/limits/)); the fiber is not told, and
  ends `Done` or not at all. A fiber that throws is a defect: the promise rejects with the throw,
  and the host answers the client with its error 1101 "Worker threw a JavaScript exception"
  ([errors](https://developers.cloudflare.com/workers/observability/errors/)). *Amended 2026-10-20
  (H6):* that is not the end of it. A throw out of core's drain moves the scheduler to its stopped
  phase (`core/Task.beni`, §9.8.14 (b)), after which every fiber started later is cancelled before
  it runs; and one isolate serves many requests and every Durable Object of the Worker. So under
  this form one defect in one request ends every later request of the isolate with `Cancelled`,
    which the runtime would have to answer — a 500 — until the host makes a new isolate. The
  per-request scheduler of (d)'s amendment (q7, #596) confines the stop to the one request.
- **A fiber resumes in the request context it belongs to — and today it would not** (*measured
  2026-10-20 under workerd, Miniflare 4.20260518.0; the probe becomes a fixture of the first code
  slice, (k)*). The host refuses to
  perform I/O "on behalf of a different request"
  ([errors](https://developers.cloudflare.com/workers/observability/errors/)): an object the host
  owns — a `Request`, a `Response`, a stub, a socket — may be used only while its request's
  handler, or a continuation of it, runs. Core's scheduler drains every ready fiber in one
  microtask (`core/Task.beni`), so a fiber woken by request A's reply can run in the microtask
  request B's reply queued. Measured: a continuation of request B run from A's microtask could
  not read B's body, and could not build a `new Response` at all; resolving B's own promise from
  A's microtask with a `Response` built in B worked, and a promise made in B and resolved from A
  ran its `.then` in B's context (the host's `handle_cross_request_promise_resolution`). So the
  hazard is real, and a per-request trampoline through a promise is a way out. **Decided**: q4 took
  the `sync` form, and q7 replaced it with fibers per request through the `scheduler` slot
  (`Task.withScheduler`, #596), as (d)'s amendment says; the probe becomes a fixture of the Worker
  slice.
- **A `Response` is the host's object**, built when the constructor is called, and a 101 answer
  carries the host's `webSocket` — the one value that cannot be plain data, which is why `Response`
  is opaque where `Http.Server`'s is a record (§9.10). `Request` is opaque for the same reason: the
  object the Worker forwards to a stub must be the one the host made, body stream and `Upgrade`
  header included.
- **A `Response` is validated in beni before the host is called** (*amended 2026-10-20, H4; it
  used to say the host checks the status*). The constructors take any `Int` and `String`, and the
  host throws on ordinary values (measured, workerd v1.20260518.1): a `TypeError` for a relative
  redirect target ("Unable to parse URL: /login"), for a header name that is not a token, for a
  header value with a control character, and for a body on 204, 205 or 304; a `RangeError` for a
  status outside 200 to 599; and `Response.redirect`'s headers are immutable, so `withHeader` on
  one would throw. So the platform builds every response with `new Response(body, { status,
  headers })` and checks first, as §9.10 (d) does on `node`: the status is an integer from 200 to
  599; 204, 205 and 304 take an empty body; a header name is a token and a value holds no CR, LF
  or NUL; and `redirect`'s target is resolved against the request's URL in beni (`new URL(target,
  base)`, whose `TypeError` is caught from that call alone and is the fault). **An invalid
  response is a 500 with an empty body and no header of the program's, and one `console.error`
  line names the fault**, in both builds; it is not a defect, for §9.10 (d)'s reason, and a
  `withHeader` on it leaves it as it is (*amended 2026-10-22, P705-7*). `withHeader` appends to
  a response the platform built; a response from `forward` or `callService` is the host's, whose
  headers are immutable (*measured*, "Can't modify immutable headers"), so `withHeader` copies it
  once before the first append — `new Response(body, response)`, the copy the platform's from
  then on — and a 101, whose socket no copy keeps, is an invalid response under `withHeader`
  (*amended 2026-10-22, P705-4*). `Worker.header` with a name that is not a token answers
  `Nothing`, since no request has such a header and the host would throw (*P705-3*).
- **The log** keeps core's default sink, the console method of each level: the host's logs collect
  what `console` writes. `node`'s `logfmt` line on standard error has no equivalent here.
- **Bindings are read by name and answer `Maybe`**: a binding the configuration does not declare
  is `undefined` on `env`, which is not an error the host throws but a mismatch between two files
  the program's author owns, so it is a value the program decides about — a 500, say — and never a
  crash. `objects`, `service` and `var` read `env[name]` and test its shape. *Amended 2026-10-20
  (M11):* a service binding and a stub answer every property name since the compatibility date
  2024-04-03 (the host's wildcard properties), so a namespace is told apart by what it lacks: an
  object whose `idFromName` is a function and whose `fetch` is `undefined`; a service is an object
  whose `fetch` is a function; a variable is a string.
- **What a stub's failure becomes** (*amended 2026-10-20, M3; 2026-10-21, R5-5: `Cycle`*). The texts the documentation
  quotes ("Durable Object is overloaded", "Network connection lost", …) are the edge's, and workerd
  carries none of them; what both set are four properties of the error, `overloaded`,
  `retryable`, `remote` and `durableObjectReset` (workerd v1.20260518.1, `src/workerd/jsg/util.c++`).
    `forward` and `callService` sort by them, in this order:
  first a **refused cycle** ((e.3)), which is not an error of the host but an answer the refusing
    object wrote — status `508 Loop Detected` (RFC 5842) with the header `x-beni-cycle: 1` — and
  which `forward` and `ask` recognise by that status and that header together and answer `Err Cycle`
  (nothing is caught: it is a `Response` read by its fields; a 508 a program wrote itself has no
  such header, because `withHeader` refuses every name that begins with `x-beni-` in any case
  (`X-Beni-Cycle` sets the same header, R7-5) as an invalid response — a 500 and a `console.error` line, (d)'s validation rule — and the Worker strips
  `x-beni-chain` on entry, so the `x-beni-` names are the platform's alone, R6-7); then
  `overloaded` is `Overloaded`; `durableObjectReset` is `Reset`; `retryable`
  is `Transient`; **anything else is thrown again**:
  an application error of the object — the object's own throw, which reaches the stub's caller
  unchanged with `remote` true and no `durableObjectReset`, since (f)'s abort comes after it
  (*amended 2026-10-21, R2-1*), so the Worker's request is a defect too — CPU or memory exceeded,
  an internal error. After a stub has failed, the host asks that it be made again; a
  program calls `byName` again for the next request, which it does by writing `route` as (i)
  shows.

**(e) `Worker.Object`: a Durable Object.** *Rewritten 2026-10-21 to the owner's design for
`cf-workers-q2` and `q5` (Cesar Canassa, on PR #533; (l)), which replaces the 2026-10-20 text and
its amendments: handlers that may suspend, run one event at a time, over one fiber runtime per
object.* An object is a name, a function that restores its state, and the handlers it answers
events with.

**(e.1) Handlers are ordinary beni functions, and their effects are inferred.** A handler carries
no `sync` marker, as transparent effects require (no surface syntax); the marker is legal only in
a top-level or `foreign` signature, and inside a `type alias` it would be a type variable named
`sync` (the defect of the 2026-10-20 text; `src/parse/Parse.zig:187-193`, `:1976-1982`). A
handler that never waits runs to its end inside the host's method, at the cost of a plain call; a
handler that waits runs as a fiber. The program's text is the same either way.

```elm
module Worker.Object

-- `Definition` and `Ref msg` are `Worker`'s (b); this module imports `Worker` (qualified for `Ref`:
-- `import Worker exposing (Ref)` plus the alias is `shadows_import`, measured, R8-3) and names the ref:
pub type alias Ref msg = Worker.Ref msg  -- the same type, named here (R7-4: an import is no re-export)


-- *Amended 2026-10-21 (q8, (e.10)): `define` takes the protocol's schema, `Context msg` carries the
-- protocol, and the owner's `send` is `post` on a `Ref msg`. `Context msg` is this module's,
-- `Worker.Context` the request's (d).*
pub foreign type Context msg             -- an object of protocol `msg`: its id, storage, sockets, alarm, timer and mailbox
pub define : String, Schema e msg, (Context msg → state), Handlers state msg → Worker.Definition


pub type alias Handlers state msg =
    { request : Context msg, state, Request → state × Response
    , message : Context msg, state, Socket, String → state
    , closed : Context msg, state, Socket, Close → state      -- `Close` is `WebSocket.Close`, §9.11 (a)
    , failed : Context msg, state, Socket, String → state
    , alarm : Context msg, state → state
    , received : Context msg, state, msg → state              -- every message, from this object or another, (e.10)
    , tick : state → Maybe Duration                           -- reads the state; it may not wait, (e.5)
    , ticked : Context msg, state → state
    }

pub none : Handlers state msg            -- every handler leaves the state as it is; `request` answers 404; `tick` is `Nothing`

pub foreign type Reply a                 -- the one-shot reply channel an `ask` carries, (e.10)
pub self : Context msg → Ref msg         -- this object's own typed reference, (e.10)
pub post : Ref msg, msg → ⊤              -- fire-and-forget, (e.10)
pub ask : Ref msg, Schema e a, (Reply a → msg) → Result AskError a   -- post and wait for the reply, (e.10)
pub reply : Reply a, a → ⊤               -- answer an `ask`, once, from `received` or a fiber it spawned (e.10)
pub body : Request → String              -- the whole body as UTF-8 text, read by the platform before `request` runs; "" when there is none
pub id : Context msg → String            -- `ctx.id.toString()`
pub name : Context msg → Maybe String    -- `ctx.id.name`, when the object was reached by name; `Nothing` in an alarm's retried instance (measured), so `restore` never depends on it
pub sockets : Context msg → List Socket  -- every accepted socket still open, `ctx.getWebSockets()`
pub socketsTagged : Context msg, String → List Socket

pub alarmAt : Context msg, Int → ⊤       -- `setAlarm(ms since the epoch)`; replaces the one set
pub alarmIn : Context msg, Duration → ⊤  -- `alarmAt` of `Clock.now ⊤` plus the duration
pub cancelAlarm : Context msg → ⊤        -- `deleteAlarm`

-- The socket operations that need the object ((g) has their meaning):
pub accept : Context msg, Request, List String → Result AcceptError (Socket × Response)
pub acceptWith : Context msg, Request, { protocol : Maybe String, tags : List String } → Result AcceptError (Socket × Response)
pub autoReply : Context msg, String, String → ⊤   -- `setWebSocketAutoResponse`: answered without waking the object
```

The program is written as `Worker.program`'s `objects` entry:

```elm
arena : Worker.Definition
arena =
    Object.define "Arena" arenaMessage restore
        { Object.none
            | request = join
            , message = input
            , closed = leave
            , received = scored
            , tick = λstate → if List.isEmpty state.players then Nothing else Just (Duration.millis 50)
            , ticked = step
        }
```

- **The name** is the class the entry file exports — `"Arena"` must be in the app's `"exports"`
  list, and `exports("Arena")` of (c) answers this definition's class. A name listed and not
  defined fails the load as (c) says; a name defined and not listed is a definition no export
  reaches, which the host never instantiates, and `run` reports nothing: the configuration is the
  author's, and (i)'s table says what to write.
- **`restore` runs before the first event of each start.** The host runs the constructor on
  creation, on every wake from hibernation and after every eviction or restart, and the in-memory
  state is gone each time ((a)). The platform calls `restore ctx` once per instance, as the first
  work of the first event — `restore` may wait, as a handler may, and the first event waits behind
  it — and holds the state it returns; a program rebuilds it from `Storage` and from `sockets` with
  their attachments. Nothing else of the previous life is visible, (e.6).
- **The state is the platform's to hold** between events; a handler is handed it and returns it.
  Nothing a handler returns is written anywhere by itself: what must survive a restart goes through
  `Storage`, incrementally, as the host recommends (no shutdown hook exists).
- **`send`'s message type** (*R5-1*) was that, as the owner first wrote it, `Context` carried no
  type parameter, so `msg` was free at each call. The owner settled it the same day
  (`cf-workers-q8`, (e.10)): `Context msg` carries the protocol, and a message travels only
  through a `Ref msg`.
- **`define`'s shape** (*R5-6*): the owner's signature — `restore` positional, `Handlers` an alias
  — is what slice (b) builds. The ownership row of (e.7) does not need another shape: the checker
  change that q5 asks for gives `restore` the `init` role by its position and the alias's fields
  their roles by name, reading through the alias, so the owner's signature stands. If the checker
  cannot read through the alias, the question goes back to the owner with the alternative,
  `define` over one record written out.

**(e.2) One event at a time, with the state passed from one to the next.** Every event of an
object goes into **one mailbox**: a request, a socket message, a close, an error, an alarm, a
tick, an own message. A handler takes the state, may wait, and returns the new state; **the next
event starts only after it returns**. Within a handler there is no interleaving and no lost
update, and waiting on another service before answering is written top to bottom:

```elm
join ctx state request =
    case Auth.check (Object.body request) of    -- waits; the object's other events queue
        Ok player →
            case WebSocket.accept ctx request [ player.id ] of
                Ok ( socket, response ) → ( addPlayer state player socket, response )
                Err _ → ( state, Worker.text 400 "not a WebSocket upgrade" )

        Err _ →
            ( state, Worker.empty 401 )
```

The host delivers an object's methods in series and interleaves them only where one waits for
I/O that is not storage ((a); measured, M6); the mailbox is what turns that into one handler at a
time, whatever the host interleaves: the class's `fetch` reads a request's body, then puts the
event in the mailbox, and the mailbox's one consumer runs the handlers in the order the events
became ready. What a program observes depends on the events and the state, never on a host
timer's resolution — a fixture drives time as (k) says.

**(e.3) A cycle between objects is a typed error, not a deadlock.** A strict mailbox deadlocks
when A calls B and B calls A back, as Orleans and Restate both document. The platform's stub
wrapper carries a **call-chain id** on every call between objects: the header `x-beni-chain` on
`stub.fetch`, and the same id through an RPC stub when RPC comes ((j)). The id is unguessable
(`crypto.randomUUID()`); a Worker's `forward` strips any `x-beni-chain` a client sent and starts
a fresh chain, and an object's `forward` or `ask` passes its current chain on; a fiber inherits the
chain of the handler that spawned it and keeps it after that handler returned (*amended 2026-10-21,
R7-3*: safe, because once the handler has returned no handler with that chain is parked, so no
false `Cycle` occurs). An incoming event — a `forward`, an `ask` — whose chain
holds a handler already parked in this object is refused at once: the object answers `508 Loop
Detected` with `x-beni-cycle: 1` and runs no handler, and the caller's `forward` or `ask` answers `Err Cycle`
((d)'s sorting); nothing hangs, and nothing is caught broadly (rule 9). That the id travels
through both kinds of stub is a fact to establish (#594, (k)).

**(e.4) Work that must not hold the object: spawn, then send.** To keep serving while slow work
runs — so that an upstream call does not freeze the ticks — a handler spawns the work and sends
the object its result, which arrives as an event of `received` in the mailbox's order: Akka's
`pipeToSelf`, LiveView's `start_async`.

```elm
input ctx state socket text =
    _ = Task.spawn λ⊤ → Object.post (Object.self ctx) (Scored socket (Leaderboard.submit text))
    state
```

Holding the object or spawning is the program's choice, and both are safe (rule 7). A `post` to
`self` from outside a handler — from a spawned fiber, as here — queues the message; one from
inside a handler queues it behind the events already waiting ((e.10)).

**(e.5) Each object gets its own fiber runtime.**

- **Its own scheduler.** Every object instance gets its own scheduler through the `scheduler`
  fiber slot `transparent-effects-proposal.md` §17.5 reserves (`Task.withScheduler`, a change to
  `core/Task.beni`: #596, coordinated with #358 and #550). All events of one object share one
  IoContext in workerd (`src/workerd/io/io-context.h`, `io-context.c++:657-660`), so I/O across
  requests is not a hazard inside an object; objects that share an isolate refuse each other's
  I/O — "Cannot perform I/O on behalf of a different Durable Object" (`io-context.c++:1539-1546`)
  — and core's single drain per isolate is what would cross that line. A per-object scheduler
  also confines a defect to its own object ((f); H6). That two objects in one isolate stay
  isolated is a fact to establish (#595, (k)).
- **Its own scope.** It is opened when the instance starts, and every handler that waits and
  every spawned fiber lives in it. A handler that never waits lives in no fiber.
- **A live fiber keeps the object in memory**, as a set timer does: while the scope has a live
  fiber, the platform holds a host timer. Hibernation happens only when the mailbox is empty and
  the scope has no live fiber, so it never strands a parked fiber. That the timer prevents
  hibernation reliably is a fact to establish (#593, (k)).
- **`tick` may not wait.** It reads the state and names the timer; the platform calls it after
  `restore` and after every handler, outside any fiber. The owner wrote "checked to be sync". A
  marker cannot stand on an alias field, so the check is at `define`, with `Js.maySuspend` on the
  record's `tick` — the checker's answer for that field's function — and a `tick` that may
  suspend is a defect at load, naming the object. Whether `Js.maySuspend` answers for a field of
  a record argument, or conservatively, is *owed* (a probe before slice (c)); if it is
  conservative, the compile-time form is `tick` in `define`'s own signature as `sync (state →
  Maybe Duration)`, which changes the owner's signature and goes back to him (R5-6). *Measured
  2026-10-22: it is conservative, and the form is the owner's (`cf-workers-q9`). Until the answer,
  what is built is this: no check, and a `tick` that waits parks the object until it answers, its
  other events waiting in the mailbox.* `Just d` keeps one host timer of `d` armed — re-armed
  from the moment it fires, the same `d` not re-arming it — and `ticked` is an event of the
  mailbox; a different `d` re-arms from now; `Nothing` clears it. A set timer keeps the object
  from hibernating ((a)), which is what an active arena wants, and `Nothing` is how the program
  lets it sleep: "the game will stop its tick when the arena is idle" (#526). A timer keeps the
  object from **eviction** only from the compatibility date 2026-10-01, for up to 15 minutes per
  timer (the changelog of that date), and a timer does not reset the object's CPU allowance,
  which each request or WebSocket message resets to 30 seconds; whether a hibernatable socket
  counts as a connected client in that rule's sense is *owed* (no page says it). After an
  eviction or a restart there is no timer until an event arrives; the alarm is the durable timer.
- **A defect closes the scope, then aborts** ((f)).
- **Eviction is a process kill.** A deploy, a reset and the 15-minute cap on pending operations
  kill the instance with no code run, as SIGKILL does on Node. The guarantees hold while the
  instance lives.

**(e.6) What survives what.**

| | Hibernation | Eviction, or a defect |
|---|---|---|
| the state | rebuilt by `restore` | rebuilt by `restore` |
| sockets and their attachments | yes | yes, except after `abort` (1006, (f)) and after a deploy, which disconnects them all |
| fibers in flight, own messages | cannot happen while they are live ((e.5)) | lost; delivery of an own message is **at most once** |
| storage and the alarm | yes | writes flushed before the defect, yes; the failing event's own writes are discarded with the abort (measured) |

Durable work follows one pattern: write the intent to `Storage`, then finish it in `restore` or
in `alarm`. *The table corrects the owner's in two cells (R5-7): sockets do not survive an
`abort` or a deploy, and storage keeps only what was flushed before a defect.*

**(e.7) The ownership row** (`cf-workers-q5`, decided 2026-10-21: *owned, like `update`*). The
state passed between handlers has the row §9.12 proposed: `restore` is like `init`, its result
owned by the platform; each handler is like `update`: the state it is handed is owned, so a
handler may edit a list of the state in place, and the state it returns is owned by the
platform; `tick` is like `view`: it borrows the state and edits nothing; a `Response` and every
socket are escaped values. A spawned fiber's closure that captures the state makes that value
escape, so an in-place edit after the spawn is refused and the error offers `List.copy`. The
runtime keeps P1–P4 and P7 by holding one state at a time: after a handler returns, nothing of
the runtime reads the state it was handed, the timer's closure included. The row needs new field
roles in the ownership checker, which reads them through the `Handlers` alias and gives the
positional `restore` the `init` role, so the owner's `define` signature stands ((e.1), R5-6;
`ownership-checker.md` §30.3 gains the rows); until that lands, an in-place edit in a handler is
`pending` and `List.copy` is the way round it.

**(e.9) What a handler waits on, in this slice** (*R5-2*). An object's handler may park on:
`Object.ask` ((e.10)) and `Worker.forward ref request` ((d)), which carry the
call-chain id ((e.3));
`Worker.callService service request`; `Task.sleep`; `Task.join` of a fiber it or an earlier
handler spawned; and nothing else — an upstream `fetch` is (j)'s, and a body read happens before
the handler ((e.2)). Every wait keeps the object awake ((e.5)).

**(e.10) Messages from anywhere: the protocol, refs, `post` and `ask`** (*added 2026-10-21, the
owner's answer to `cf-workers-q8`; (l)*). The object's message type is its **protocol**, typed
from anywhere: `define` takes it with a schema for it, `Context msg` carries it, and a reference
to an object is typed by it.

```elm
-- The typed reach to an object is `Worker`'s: `objects env name schema`, `byName`, `unique`,
-- `byId`, `refId`, `refName` ((d)). `self`, `post`, `ask`, `reply` are `Worker.Object`'s (e.1).

pub replySchema : Schema e a → Schema String (Reply a)   -- a `Reply a` on the wire is a correlation id; the argument is the reply's own schema, kept for `reply` (R6-2, R7-2)

pub type AskError
    = Overloaded | Reset | Transient | Cycle   -- the host's, as `StubError` sorts them ((d))
    | NoReply                                  -- the `received` call that got the `Reply` returned, every fiber it spawned ended, and no message to `self` carries it (e.10)
    | Unprintable (List Schema.Issue)          -- the message does not print by the protocol's schema
    | Unreadable (List Schema.Issue)           -- the reply does not parse by the asker's schema, or the message did not parse by the receiver's (its 422, (e.10))
```

- **`received` is the one entry point for messages**, from this object or from any other;
  `request` stays for HTTP — upgrades, browsers, a Worker's `forward` of a client's request. A message from another
  object arrives as the protocol's value, parsed by the schema, in the mailbox's order ((e.2)).
- **A ref is typed by the protocol.** `self ctx` is this object's; a Worker or another object gets
  one from a `Namespace msg`, which `objects` makes from the binding and the protocol's schema
  — the same schema `define` took, so the type is the program's claim and the schema is what
  checks it on the wire. A name or an id reaches the object as before. A ref of the wrong
  protocol is a program error the schema finds: a message that does not parse at the receiver is
  refused (below), never delivered as another type.
- **`post` is fire-and-forget.** To `self`, the message goes straight into the mailbox and is
  delivered exactly once, in order with the events before it, while the instance lives ((e.6)).
  To another object, the platform prints the message by the schema and sends it through the
  ref's `stub.fetch` with the chain id ((e.3)); `post` waits for nothing and answers nothing.
  Across isolates — and the platform cannot tell whether the other object shares the isolate, so
  for every ref but `self` — the message is encoded through the schema; a value that does not
  print is dropped and one `Log.warn` line names it, since a `post` has no result to carry it.
- **`ask` posts and waits for the reply**, like any other host I/O: the message carries a `Reply
  a`, the receiver answers through `reply`, once, and the asking handler parks until the reply
  comes back. **How a `Reply a` crosses the wire** (R6-2): the protocol's schema places it with
  `replySchema aSchema`, so the receiver's schema knows the reply's shape; on the wire a `Reply a`
  is a correlation id, and when the receiver calls `reply handle value` the platform prints
  `value` with the schema `replySchema` captured as it parsed the message, and answers the asker's
  waiting request with it. `ask`'s own `Schema e a` is the asker's side of the same shape: it
  parses the reply back, and a mismatch between the two is the program's claim the schemas find
  (`Unreadable`). **A reply may come later**: `received` may reply before it returns, or hand the
  `Reply` to a fiber it spawns ((e.4)) which replies when its work is done; the asker waits until
  the reply, until the asked instance ends (the host's error, as (d) sorts it), or until its own
  `Task.timeout`. `NoReply` is answered when nothing can reply any more, a condition the platform
  checks (*amended 2026-10-21, R8-2*): the `received` call that got the `Reply` has returned
  without replying, every fiber that call spawned — directly, or through its fibers — has ended,
  and no message posted to `self` by that call or those fibers still waits to run (a `Reply` in
  such a message is not printed, so the `Unprintable` rule does not reach it; the queued message
  holds the `Reply` until its own `received` returns, which lets a `Reply` pass within the object).
  The platform tracks that set of fibers and messages; it cannot see which fiber captured a
  `Reply`, so a test over the whole scope was not checkable. **An `ask` to `self` from a handler is `Err Cycle` at once**: the message
  would wait in the mailbox behind the asking handler, so no stub and no chain is consulted. It
  is subject to (e.3)'s cycle rule across objects, and every failure is a typed result: the host's
  four ((d)'s sorting), `NoReply`, and the two schema failures. A second `reply` on the same
  `Reply` is ignored; a `Reply` is one-shot. *Amended 2026-10-21 (R7-1; a choice the owners can
  overturn, taken because q8 says "nothing hangs"): a `Reply` is valid only in the instance that
  parsed it, and only while the `received` call that got it, a fiber that call spawned (directly
  or through its fibers), or a message those posted to `self` can still reach it — the holders
  the `NoReply` rule above counts. A `Reply` kept in the state is held by none of them, so the
  asker gets `NoReply` as soon as the last of them ends, and a
  `reply` that comes after `NoReply` was answered — from a later handler, or through a `Reply` kept
  in the state — is not dropped in silence: the platform writes one `Log.warn` line naming the
  object and the message. Printing a `Reply` into a message for any ref but `self` is
  `Unprintable`: the correlation id names a request pending in this instance alone, and at another
  object its `reply` would reach no one. The lobby that holds an asker until a second player comes
  spawns a fiber from `received` that waits for the match and then replies ((e.4)); it does not
  keep the `Reply` in the state. The other way — an ask that stays open until the reply or the end
  of the instance — left an asker with no `Task.timeout` waiting on a dropped `Reply`. One shape
  the self-cycle rule does not reach (R7-3): a handler that joins a fiber it spawned while that
  fiber `ask`s `self` — the fiber's message waits behind the handler, and the handler waits for the
  fiber. It is a hazard, bounded by `Task.timeout` on the join or on the ask, as (e.5)'s owed
  checks are.*
- **Delivery across objects is at most once.** The host confirms nothing beyond its own errors:
  a `post` the host could not deliver — overloaded, reset, connection lost — is lost, and the
  sender is not told; a program that must know asks instead, and gets the host's error as a typed
  `Err`. Within the receiving object a delivered message runs `received` once, under the
  mailbox's order; a receiver that is evicted mid-handler loses it ((e.6)'s table). Durable work
  therefore follows (e.6)'s pattern: write the intent to `Storage`, then finish it in `restore`
  or `alarm`, with the message as the trigger and never as the record.
- **A message comes only from the platform's own stub** (*amended 2026-10-22, P723-1*). The
  object's `/__beni/post` and `/__beni/ask` are the stubs' own: a `post` or `ask` sends them with
  the header `x-beni-origin: platform`, and the object runs `received` only with that mark, else
  answers 404. A client cannot forge the mark through a Worker, because `forward` strips every
  `x-beni-` header a client sent and answers 404 itself to a path that holds `/__beni/`, never
  sending it ((d)); so a request a Worker forwards reaches `request` alone. `ObjectCounter` posts
  and asks through `forward` and the count stays.
- **Refused messages.** A message that does not parse by the receiver's schema — a ref of the
  wrong protocol, an older deploy's shape —   is answered with `422 Unprocessable Content` and the
  header `x-beni-message: unparsed`, which the sender's `ask` reads as `Err (Unreadable issues)`
  for its own reply and the platform logs for a `post`; `received` does not run. The header is
  the platform's alone, as every `x-beni-` name is ((d)'s `withHeader`). Nothing is
  caught (rule 9): the refusal is a response read by its fields, as the cycle's is.

*As built (2026-10-22, the object slice; `platforms/cloudflare/Worker/Object.beni`, fixtures
`workers/ObjectCounter`, `ObjectAsk`, `ObjectHolders`, `ObjectIsolation`, `ObjectStorage`).*
- **The signature stands** ((e.1), R5-6): `define name schema restore handlers` with `Handlers` the
  alias above. One name is added, **`env : Context msg → Worker.Env`**: the owner's `Context msg`
  listed no bindings, and (e.3)'s B-calls-A-back needs a namespace from inside an object.
- **The mailbox** ((e.2)): the class's `fetch` reads the body, then sorts the request — a test hook,
  a refused cycle (508), `/__beni/post` or `/__beni/ask` parsed by the protocol's schema, or a
  `request` event — and wakes the consumer: one detached fiber under the object's scheduler,
  started where `restore`'s and the handlers' effects are known. *Measured* (`ObjectIsolation`): a
  handler read back through `Js.to` is called in its sync form, so a `Task.sleep` in it answered
  `TypeError … (reading 'a')`; the typed `restore` and `Handlers` are threaded from `define` to the
  consumer instead.
- **The chain id travels through `stub.fetch`** ((e.3), #594's first half, *measured*):
  `ObjectAsk`'s `/lobby/back` — the Lobby asks the Scorer, whose `received` asks the Lobby back with
  the same chain — answers `Ok Err Cycle`: the Lobby refused with 508 and `x-beni-cycle: 1`, the
  Scorer saw `Err Cycle` and replied with it, and neither object hung. The RPC half waits for (j).
- **Fibers in an object** ((e.4), (e.5), (e.9); #550, its option 2): a handler's fibers live under
  the object's scheduler, where `Task.schedulerFibers` counts them and the defect's teardown
  cancels them. `ObjectIsolation` shows spawn-then-`post` to `self` with the `bracket` release
  running when the fiber ends, a later handler joining a fiber an earlier one spawned, and two
  instances of one class each resuming a parked handler in its own context (#595, *measured*).
- **The live-fiber timer** ((e.5)) is built: one host `setTimeout`, of the longest delay the
  host takes, held while the scheduler runs any fiber beside the consumer and cleared when the
  count falls to the consumer alone. The count is read after `restore` and after each handler
  returns — the kernel reports an end, never a start, so the first fiber a handler spawns is seen
  there — and at each end through `onSchedulerCount`. `ObjectIsolation` reads it through the
  `--test-hooks` path `/__beni/hold` (`held` or `free`). That the timer prevents hibernation is
  #593's probe, still owed, so #550 stays open until it settles.
- **`tick`'s check is not placed** ((e.5)): `Js.maySuspend` on the record's field answers yes in
  `define`'s suspendable twin, which every program whose other handlers may wait reaches, so a
  pure `tick` was refused at load (*measured*, the probe (e.5) owed). The form is the owner's
  (`cf-workers-q9`); until it comes, a `tick` that waits parks the object until it answers. The
  timer is one host `setTimeout`, re-armed as (e.5) says; under `--test-hooks` no host timer is
  armed and `/__beni/tick` is its firing ((k)).
- **`post` and `ask` on the wire** ((e.10)): `post` to `self` goes into the mailbox with the ids of
  the `Reply`s the message holds (a walk of its records and lists, `Object.js`); to another object
  it is `POST /__beni/post` on the stub with `x-beni-chain`, answered 204 after `received` ran.
  `ask` is `POST /__beni/ask` with `x-beni-ask: <uuid>`; the receiver keeps the pending ask by that
  id, `reply` prints the value with the schema captured at parse time and answers it 200, and the
  asker sorts the answer: 508 with `x-beni-cycle` is `Cycle`, 422 with `x-beni-message: unparsed`
  is `Unreadable`, 204 with `x-beni-reply: none` is `NoReply`, 200 is parsed by the asker's schema.
  A `Reply` prints only for the ask that makes it: one parsed in this instance, printed for any
  stub, is `Unprintable` (`ObjectAsk`'s `/hello`: the post is dropped with one warning line).
- **The holders of a `Reply`** ((e.10), #623): the platform cannot see which fiber holds one, so
  it counts **every fiber of the object**. `NoReply` is answered, after an event and before the
  consumer parks, for each ask whose `received` has returned when the object's scheduler runs no
  fiber but the consumer and no message to `self` waiting in the mailbox holds that `Reply`. That
  set contains (e.10)'s recursive one — a fiber the second `received` spawned is a fiber of the
  object — and is never smaller, so `NoReply` never comes while a holder lives. **It comes when
  the count allows** (*amended 2026-10-22, P723-2*): the platform watches the scheduler with
  `Task.onSchedulerCount`, so the last holder ending while the consumer is parked settles the
  pending asks at once, with no next event needed. **A choice the owners can overturn:** because
  the platform cannot see which fiber holds a `Reply`, one unrelated live fiber of the object
  delays every `NoReply` until it ends; `NoReply` then comes, never fails to. The alternative,
  holders tracked per ask, needs the checker to name the closures that capture a `Reply`.
  `ObjectHolders` shows the relay through `self`, the relay through a fiber the second call
  spawned, the `Reply` kept in the state (`NoReply` at once), the late `reply` through it (the
  warning line, no answer), the holder that ends while the consumer is parked, and the unrelated
  fiber that delays a `NoReply`.
- **`ask` to `self` is refused from every fiber of the object** (*amended 2026-10-22, P723-7; a
  choice the owners can overturn*), not from the running handler alone: the kernel does not say
  which fiber is current, so the platform cannot tell a spawned fiber from the handler it serves.
  For the handler the refusal prevents a deadlock. **For a spawned fiber it buys no guarantee**:
  the consumer is free and could answer. **A capability is lost** with it: a post to `self`
  carries no answer back, so a fiber that needs its own object's answer must route it another
  way — a `Deferred` kept in the state that `received` completes, or a `post` whose `received`
  acts. It narrows q8's `ask`, which is why it is the owners' to overturn. **The way out** is a
  core way to name the running fiber (#730): with it the platform refuses the handler alone, and
  R7-3's hazard — a handler joining a fiber that asks `self` — returns as the bounded hazard it
  was.

**(e.8) The Elm Architecture is a framework layer.** `Object.element` — `update : Context msg,
state, msg → state × Cmd msg` — sits over `post` and spawn, as §9.8.11 puts TEA over a direct
form. It is optional, adds no capability, and is a later slice ((j)).

**(f) A defect closes the object's scope, then aborts** (rule 9; `transparent-effects-proposal.md`
§16.5; the owner's decision 1 of #331 and his design for `cf-workers-q2`, (e.5)). *Rewritten
2026-10-21 with (e).* A throw in a handler, in `restore`, in `ticked` or in a sibling is a defect.
Nothing catches it: it leaves the fiber's drain, or the host's method when the handler ran in
none, and reaches the host as the uncaught exception it is, with its message and its stack —
measured: the stub's caller sees the original error with `remote` true and no
`durableObjectReset`. On its way out the platform's hook for the object's scheduler (the
per-object form of core's `onDefect`, #596) **closes the object's scope**: every fiber of it is
cancelled and its finalisers and `Task.bracket` releases run without interruption, as §9.8.14's
teardown runs them, under its deadline; **then it aborts the instance** with `ctx.abort(…)` and a
fixed reason — `ctx.abort` does not return (workerd terminates the running JavaScript,
`src/workerd/api/actor-state.c++:1133-1153`), which is why it comes last, after the teardown, and
why the reason is fixed: an abort called before the throw has left would replace the defect with
its own message (measured). From the throw to the abort no handler runs: the mailbox is stopped
with the scope. `ctx.abort(message)` resets the Durable Object at once and the host logs an
`Error` with the message ([`ctx`](https://developers.cloudflare.com/durable-objects/api/state/)):
in-flight requests fail, (d)'s `forward` throws the object's error again as "anything else", so
the Worker's request is a defect too, every attached socket is closed (measured: the client sees
1006 with no reason, `wasClean` false), and the next event starts a new instance whose `restore`
runs. **Every defect closes the scope, whether or not the throwing handler ran in a fiber** (R5-3):
the scope may hold fibers that earlier handlers spawned ((e.4)), each with its finalisers, so a
throw from a handler that never waited queues the same teardown and then the abort, on a timer of
zero so that the throw leaves first. *As built (2026-10-22):* the scheduler's hook stops it with a
1 000 ms deadline; when the teardown is done, one `console.error` line — `beni: a defect stopped
the object <name>; its next event starts a new instance` — and `ctx.abort` with that reason on a
timer of zero. The event that was running and every event waiting in the mailbox fail with the
throw (`arm`'s rejection), so the request in flight answers 500 with the error's text through the
Worker's `forward` and nothing waits on a mailbox that never runs again. `ObjectIsolation`: the
release of a fiber parked on `Task.never` prints before the abort line, the other instance serves
on, and the next request to the aborted one is a new instance.

**A defect in `alarm` is retried by the host.** The host retries an alarm whose handler threw
"using exponential backoff, starting at 2 second delays for up to 6 retries"
([alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)). In production the
abort passes `{ retryAlarm: false }`, whose options "accept `retryAlarm` (boolean, default
`true`)" (the state page; the changelog of 2026-08-25), so a defect is not retried as a transient
failure would be. workerd v1.20260518.1 has `abort(reason)` alone and ignores the option, and
nothing durable can stop the retry there — `abort` discards every write, a `deleteAlarm()`
before it included (measured: with and without the delete, `alarm` ran again about 2 s later,
`isRetry` true, on a fresh instance after `restore`, with `ctx.id.name` undefined). So under
(k)'s pinned tools a defect in `alarm` is retried up to 6 times on fresh instances, each after
`restore`, and the fixture expects that; the production rule is *owed* to a newer runtime in the
shell. A defect in the Worker's `fetch` is (d)'s: the request fails with 1101 and the Worker goes
on.

**(g) `WebSocket`: the server WebSocket, with hibernation.** The shape is §9.11's (the `ws`
worker's spec for the page and the `node` server) **where the host lets it be**: this platform's
module is also named `WebSocket`, and it declares the *handle operations* that §9.11's amendment
of 2026-10-20 shares (its item 1) — `Socket`, `eq`, `Close`, `CloseError` (with this host's set
of codes a server may send, item 3), `WriteError`, `write`, `close`, `protocol` — with the same
names, types and meaning, and an object answers an upgrade as §9.11 (e) does, with
`Object.accept` or a refusing response. Nothing of those is defined a second time here. **It does not declare `read`,
`buffered` or `drain`** — the *reading style* is the platform's (item 1), and `buffered` and
`drain` are not shared (item 2) — and no protocol module may need them to check here; the review
of #531 found why, and this section follows it:

- **The reading style is per event, not a pull** (the owner's `ws-q3`, 2026-10-21: *each host
  style* — `node` keeps the pull `read` session, Cloudflare uses event handlers so an object can
  hibernate; (l)). §9.11 (a)'s `read` parks the fiber that waits
  for the next message, and §9.11 (e)'s `accept session` runs the session in a fiber for as long
  as the connection lives. Under hibernation an object's memory is discarded ((a) above), and
  only the connection, its tags and an attachment of at most 16 384 bytes survive; a parked fiber
  would either keep the object in memory — no hibernation — or be lost. The host's own shape is
  one handler per event, `webSocketMessage`, `webSocketClose`, `webSocketError`, and that is (e)'s
  `message`, `closed` and `failed`. So `read` is not declared: a `sync` handler could not call it,
  and a fiber that called it would not survive hibernation. A handler may wait ((e.1)), but a
  fiber of the object's scope keeps the object awake ((e.5)), so a program that parked on a socket
  would give up hibernation; the per-event form keeps it.
- **There is no back-pressure signal.** The host's `WebSocket` has no `bufferedAmount`
  (*measured*, `undefined`), and `send` inserts each message into an unbounded `outgoingMessages` map with no size check
  (workerd v1.20260518.1, `src/workerd/api/web-socket.c++:617-618`), so neither `buffered` nor
  `drain` can be implemented; answering 0
  would be a silent wrong answer. A program bounds its own rate: the arena sends one state per
  tick per player and no more, and the host's advice is fewer, larger frames.
- **The upgrade is answered by the `request` handler**, not by a second handler: it returns the
    `Response` that `Object.accept` makes (§9.11 (e)'s `accept`, with the handlers of (e) as the
  session), or any other response (its `refuse response`). The host routes every request the Worker
  forwards to the one `fetch` of the class, so there is no `listenWith` to split them. A
  subprotocol is a header of the 101 response on this host, so a form like §9.11 (e)'s `acceptWith
  { protocol }` fits — this one takes `{ protocol, tags }` and no session — and the first slice
  declares it (*amended 2026-10-20, M10*): a client that
  offered subprotocols and is answered none fails its handshake (measured with Miniflare's client:
  "Server sent no subprotocol"), and a page that passes protocols to §9.11's `connect` needs it.

```elm
module WebSocket   -- cloudflare: the handle operations §9.11's amendment shares (item 1), plus these

-- *Amended 2026-10-21 (q8): `accept`, `acceptWith` and `autoReply` take the object's `Context msg`
-- and live in `Worker.Object` ((e.1)); their meaning is below. This module knows no object.*
pub id : Socket → String                 -- the platform's id, kept in the attachment: the same across hibernation
pub tags : Socket → List String          -- `ctx.getTags(ws)`
pub attach : Socket, Schema e a, a → Result AttachError ⊤
pub attachment : Socket, Schema e a → Result (List Schema.Issue) (Maybe a)


pub type AcceptError
    = NotAnUpgrade                       -- no `Upgrade: websocket` header, or the method is not GET; nothing is accepted
    | TooManyTags                        -- more than 10, or one over 256 characters
    | TooManySockets                     -- `getWebSockets()` already holds 32 768: the host's limit per object, tested first
    | ProtocolNotOffered                 -- `acceptWith`'s `protocol` is not in the request's `sec-websocket-protocol`

pub type AttachError
    = TooLarge                           -- the attachment as the host serialises it over 16 384 bytes ((h)'s count)
    | Unprintable (List Schema.Issue)
```

- **`accept ctx request tags`** checks the handshake as §9.11 (e) does — the method is `GET`
  and `upgrade` is `websocket`, without case — tests the socket count against the host's 32 768
  (*M5*), makes a `WebSocketPair`, calls `ctx.acceptWebSocket(server, tags)` and answers the
  socket and the 101 `Response` carrying the client, which the `request` handler returns.
  `acceptWith` also writes the chosen `sec-websocket-protocol` on the 101, when `protocol` is one
  the request offered. The host checks the rest of the handshake before the Worker runs. The
  platform writes the socket's id and its protocol into the attachment first —
  `{ id, protocol, data: null }` — so that both are the same after hibernation: `ctx.getWebSockets()`
  hands the host's objects back, and `id` and `protocol` read them from there, since the server
  socket's own `ws.protocol` is always `""` on this host (`src/workerd/api/web-socket.h:417`;
  measured). `attach` prints the value with its schema and stores `{ id, protocol, data: text }`;
  `attachment` parses it back. The attachment is the one place a
  value of the program's crosses a restart beside `Storage`, so it crosses as JSON text through a
  schema, (h). The host keeps attachments "as long as the WebSocket remains healthy" and drops
  them when either side closes.
- **`write`** is §9.11 (a)'s: `ws.send(text)` when `readyState` is OPEN, `Err NotOpen` otherwise,
  tested before the host is called; the host documents no failure of `send` on an open socket, so
  a throw is a defect. From a handler it is a direct call with no runtime between the program and
  the host: the arena's twenty to thirty frames per second per player cost one `write` each. The
  host's own advice — fewer, larger frames — is the program's to take.
- **`close`** is §9.11 (a)'s: `ws.close(code, reason)` with a code this host lets a server send
  — 1000 to 1003, 1007 to 1009, 1011 to 1014 and 3000 to 4999, the `node` server's set of
  §9.11's amendment (item 3; 1010 is a client's code, RFC 6455 §7.4.1, so neither server sends
  it; *amended 2026-10-21*); workerd accepts every code of it and refuses 1004, 1005, 1006
  and 1015 (`src/workerd/api/web-socket.c++:636-643`, measured) — and a reason of at most 123
  bytes, tested in beni; on a socket not open it does
  nothing and answers `Ok ⊤`. `closed` is delivered afterwards with §9.11 (a)'s `Close`, by its
  four rules; `clean` of `webSocketClose` is not a field, since rule 4 already names 1006.
- **`protocol`** is the attachment's, as above. A close code the host refuses is its
  `InvalidAccessError` (*measured* for 1005), which the check in beni keeps from being reached.
- **`Close`, from the host's events** (*amended 2026-10-20, M10*), by §9.11 (a)'s four rules: a
  peer's close frame is its code and reason (rule 1); the object's own `close`, then the peer's
  answer (rule 2); an end with no close frame is `webSocketClose(1006, "WebSocket disconnected
  without sending Close frame.", false)` (`io/hibernation-manager.c++:257-262`), which the
  platform delivers as 1006 and `""` (rule 4); a message over 32 MiB and any other fault the host
  finds arrive as `webSocketError`, not as a close, and `failed` then `closed` with 1006 is what
  the program sees — rule 3's code is not available from the host, and `failed`'s message says
  what happened.
- **`eq`** compares by identity, as §9.11 (a) says. Within one life of the object every event
  hands the same host object back, so a socket held in the state is equal to the one an event
  names; across hibernation the state is rebuilt from `sockets`, and `id` is what a program keeps
  in storage.
- **Binary frames** are §9.11 (j)'s rule, applied by the platform: the socket is closed with
  1003, one `console.warn` line names it, and the program sees `closed`.
- **Hibernation.** A socket accepted here keeps the object free to hibernate; the standard
  `ws.accept()` with listeners does not, and is not offered. The host answers ping frames and the
  `autoReply` pair without waking the object.

*As built (2026-10-22, the socket slice; `platforms/cloudflare/WebSocket.beni`, `Worker/Object.beni`,
fixture `workers/ObjectSocket`).*
- **The surface is as above**, with one change: **`tags` reads the attachment**, not
  `ctx.getTags(ws)`. A `Socket` is the host's object alone and holds no state, so the envelope the
  platform writes at `accept` is `{ id, protocol, tags, data }`; the tags are given once, at
  `accept`, and the host keeps the attachment as long as the socket lives.
- **`accept` and `acceptWith`** check the method and the `upgrade` header without case, the tag
  count and length, the socket count and the offered subprotocols (`sec-websocket-protocol`, split
  on commas), make the `WebSocketPair`, call `acceptWebSocket(server, tags)`, write the envelope
  and answer the 101 through `Worker.fromHost`, with the chosen `sec-websocket-protocol` on it. A
  client that offered `v1, v2` and was answered `v1` opened (*measured*).
- **`attach`** counts as (h) counts — two bytes per code unit of the id, the protocol, the tags and
  the text, plus 64 — against 16 384. **`autoReply`** is `setWebSocketAutoResponse` with a
  `WebSocketRequestResponsePair`; the fixture's `ping?` is answered `pong!` with no `message` event.
- **The events**: `webSocketMessage` with a string is a `message` event of the mailbox; a binary
  frame is closed with 1003 and one `console.warn` line, with no event, and `closed` follows;
  `webSocketClose` is `closed` with `Close` by the four rules (1006 with the host's text becomes
  1006 and `""`); `webSocketError` is `failed` with the error's text. The object's own `close`
  reaches the peer with its code and reason, and the peer's close reaches `closed` with the
  peer's (*measured*, 4001 and 4002 in the fixture). A `write` after the object's own `close` is
  `Err NotOpen` (the socket is closing).
- **A defect closes every socket**: after (f)'s abort the client sees 1006 and `""` (*measured*).
- **The driver** (`tests/workers/driver.mjs`, (k)) opens a client through Miniflare's own:
  `dispatchFetch` with `upgrade: websocket` answers a `Response` whose `webSocket` is the client's
  end, accepted and listened to; the steps are `socket`, `send`, `close` and `receive`
  (`tests/corpus/README.md`, *A Worker*). The `sec-websocket-accept` answers Miniflare's random
  key and is shown as `(the key)`. Hibernation itself is not driven: #593.

**(h) `Worker.Storage`: the key-value store, through schemas.** The object's storage is the
SQLite-backed synchronous API, `ctx.storage.kv` ([storage](https://developers.cloudflare.com/durable-objects/api/storage-api/)):
every operation returns before the handler goes on, which is what lets a `sync` handler use it.

```elm
module Worker.Storage

-- `Context msg` is `Worker.Object`'s ((e.1)).
pub get : Context msg, Schema e a, String → Result (List Schema.Issue) (Maybe a)
pub put : Context msg, Schema e a, String, a → Result PutError ⊤
pub delete : Context msg, String → Bool     -- whether the key was there
pub keys : Context msg, String → List String -- the keys with that prefix, in order

pub type PutError
    = TooLarge                          -- key and value as the host serialises them over 2 000 000 bytes (the count below)
    | Full                              -- the host's `Error` "database or disk is full: SQLITE_FULL": the object's 10 GB
    | Unprintable (List Schema.Issue)
```

- **A value is JSON text, printed and parsed by a schema** (`schema.md`). The host would take any
  structured-clone value, and a beni record is one; but a `--release` build spells a record's
  fields short (`backend.md` §9, *Item 4*), and the next deploy may spell them differently, so a
  value stored as the host sees it would not parse after a release. A schema names every field
  by text in every build (§4, *Types a shape reads keep their names*), so what one build wrote the
  next reads.
- **Limits are checked in beni before the host is called, counting more than the host can**
  (*amended 2026-10-20, M2; 2026-10-21, R2-5*): the host serialises a value as V8 does, by the
  string's representation and not its content — one byte per code unit for a one-byte string,
  two per unit for a two-byte one, and a string sliced from one with an emoji stays two-byte with
  ASCII content (measured: a 10 000-unit ASCII slice of such a string was refused as an
  attachment at 20 024 bytes, and the same content built plainly passed) — so no count of the
  content is the host's. `put` and `attach` therefore count **two bytes per UTF-16 code unit of
  every string that is serialised** — the value's text and the platform's own `id` and `protocol`
  alike — plus 64 bytes of envelope, and refuse `TooLarge` before the host is called. That halves
  the room for ASCII (about 8 100 characters of attachment) and is never under the host's count.
  A fixture that stores a sliced two-byte string pins the margin. `Full` is the one host exception caught, from `kv.put` alone, by the
  `SQLITE_FULL` in its message; any other throw is a defect.
- **The output gate** (*amended 2026-10-20, M1*). A write holds every outgoing message of the
  object until it is durable: a `write` on a socket after a `put` is queued behind the gate
  (workerd `src/workerd/api/web-socket.c++:601`, `:617-618`), and a `Response` leaves after it.
  A write that fails at the disk discards those messages, answers the callers with errors and
  restarts the object from scratch (the glossary's rule): the program sees a new instance and
  `restore`, and a client sees its request fail. Nothing of that is a value of the program's: a
  failed durable write is the host's defect, and the platform maps nothing of it.
- The store is there from the constructor on (*measured*: `ctx.storage.kv` and `ctx.storage.sql`
  are objects in the constructor), so `restore` may read it whenever it runs.
- **A namespace that is not SQLite-backed** has no `ctx.storage.kv`. The platform finds that at
  the first event and throws an `Error` naming the class and `"storage": "sqlite"` ((i)): the
  configuration is wrong, nothing can run, and the message says what to write.
- The asynchronous API, SQL and point-in-time recovery are (j)'s.
- *As built (2026-10-22, `Worker/Storage.beni`, `workers/ObjectStorage`):* the four operations as
  above; `TooLarge` counts two bytes per code unit of key and text plus 64 before the host is
  called (a 2 000 000-character value is refused); `Full` is `kvPut`'s one caught text; a read
  with another schema is `Err` with its issues; what one instance put, the instance after its
  abort reads in `restore`.

**(i) The Wrangler configuration the program's author writes.** A build —
`beni build --platform=cloudflare --out=out src/Server.beni`, or `beni build` with the project
file — writes `out/_worker.mjs`, `out/_platform/runtime.foreign.mjs`, the modules and
`out/_manifest.txt` (`backend.md` §2). The page, built separately for `browser-tea`
(§5.3), goes to its own directory. The author writes `wrangler.jsonc` beside them:

```jsonc
{
  "name": "snake-arena",
  "main": "out/_worker.mjs",
  "compatibility_date": "2026-10-01",
  "durable_objects": { "bindings": [{ "name": "ARENAS", "class_name": "Arena" }] },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["Arena"] }],
  "assets": { "directory": "page/", "binding": "ASSETS", "run_worker_first": ["/arena/*"] }
}
```

| Key | Must be |
|---|---|
| `main` | the entry file, `out/_worker.mjs` |
| `compatibility_date` | in production, 2026-10-01 or later, so a set timer holds the object ((e), M4); locally, no later than the pinned workerd's own build date, which it refuses to exceed (`2026-05-18` for the tools of (k)) |
| `compatibility_flags` | `["enable_request_signal"]`, so a client's disconnect interrupts the request's scope ((d)); without it the scope ends with the response |
| `durable_objects.bindings[].class_name` | a name in the app's `"exports"` list and a `Worker.Object.define` of the program |
| `migrations[].new_sqlite_classes`, or `exports.<class>` | the class's storage is SQLite, which (h)'s synchronous store needs. The declarative `exports` form — `"exports": { "Arena": { "type": "durable-object", "storage": "sqlite" } }` — needs Wrangler 4.107.0 or later (*amended 2026-10-20, M12*); the pinned 4.93.0 reads `migrations` only, so this slice writes that form. The two "are mutually exclusive", and a Worker moved to `exports` does not move back |
| `assets` | optional: the page, served by the host before the Worker unless `run_worker_first` names the paths the Worker takes |

and the program:

```elm
main : Worker.Program
main =
    Worker.program { fetch = route, objects = [ arena ] }


route : Env, Request → Response
route env request =
    case ( Worker.objects env "ARENAS", arenaOf (Worker.path request) ) of
        ( Just arenas, Just name ) →
            case Worker.forward (Worker.byName arenas name) request of
                Ok response → response
                Err _ → Worker.text 503 "the arena is not available"

        _ →
            Worker.text 404 "no such page"


-- "/arena/<name>/ws" is `Just name`.
arenaOf : String → Maybe String
arenaOf path =
    case String.split path "/" of
        [ "", "arena", name, "ws" ] → Just name
        _ → Nothing
```

**(j) Not in the first slices.** A request body read in a Worker's `fetch` (the stream is
forwarded whole; an object reads its body through (e)); `Object.element`, The Elm Architecture over
`post` and spawn ((e.8)); binary frames and `Bytes`; RPC methods on a stub and
`WorkerEntrypoint`; the SQL and asynchronous storage APIs, transactions and point-in-time
recovery; a `waitUntil` for programs (the platform's own use is (d)'s); `request.cf`; streaming bodies; `passThroughOnException`; KV, R2, D1,
Queues, cron triggers, Workflows, Containers; outgoing WebSockets (which do not hibernate);
`setHibernatableWebSocketEventTimeout`; the `ssr` lowering for a Worker that renders markup; a
`Response` validated in beni as §9.10 (d) validates one. Each gets an issue when a program needs
it.

**(k) The tests.** A Worker runs in `workerd`, which nixpkgs carries inside `wrangler` 4.93.0
with Miniflare (`lib/packages/miniflare`, Miniflare 4.20260518.0 over `workerd` 1.20260518.1; 2.2 GiB
of disk in the store, the dev shell `workers` of #698). Putting `wrangler` in the dev shell is a `flake.nix` change, which is
Cesar's to review and goes in a PR of its own. *Amended 2026-10-20 (M8, L3), the design:*

- **The driver is Miniflare's API, not a `wrangler` process**: `tests/workers/driver.mjs` imports
  `Miniflare` from that path, builds the options from the fixture (Miniflare reads no
  `wrangler.jsonc`; the driver maps `main`, the bindings and the SQLite classes), passes `cf:
  false` so nothing is fetched from the network, keeps the object storage under the case's scratch
  directory, listens on `127.0.0.1`, and disposes at the end. Nothing is deployed and no account is
  used.
- **The script** is a `.steps` file of requests, WebSocket opens, sends, reads and closes, and
  the transcript after each step is the golden, with run hashes as `serve/`'s (§9.10 (h)).
- **Time is driven, never waited for** (`cf-workers-q6`, decided 2026-10-21: *a hidden build
  flag*; (l)). workerd has no test clock and Miniflare no alarm trigger or fake timers, so a
  fixture that ticked for real would sleep for real. A hidden flag, `beni build --test-hooks` —
  hidden as `--allow-debug` is, test-only surface — compiles two paths into every object:
  `/__beni/tick` puts a `ticked` event in the mailbox as the timer would, and `/__beni/alarm` an
  `alarm` event; the corpus passes the flag, and a user's build never holds the paths. The runtime
  reads the flag's switch as it reads `Js.development`. The transcript is a function of the steps
  alone (rule 5).
- **The budget.** Measured with `perf stat -e instructions:u`: `node -e 0` is 112M, and one
  Miniflare start, one request and its disposal 1 933M — 45% of the 4 300M budget before a build
  runs — so a case starts Miniflare once, and the `run/` habit of a development and a `--release`
  pass in one case does not fit. A `workers/` fixture is therefore **two cases**, `<name>` and
  `<name>.release`, each one build and one Miniflare start over the same sources and script.
- *Amended 2026-10-22 (the Worker slice, as built).* **The `workers/` corpus kind**
  (`tests/corpus/README.md`, *A Worker*; `tests/blackbox/workers.zig`): a fixture is a project
  under `tests/corpus/workers/<Name>/` — its modules, `beni.json` with the `"exports"` list,
  `wrangler.jsonc` as (i) writes it, `_expected.steps` — and two cases, the development build and
  the `--release --allow-debug` build, each one Miniflare start (the budget above), each with a
  record file of its own (`_expected.run-hash`, `_expected.release-run-hash`), so neither case
  writes the other's. The driver takes Miniflare's entry file as `--miniflare=`, from
  `BENI_MINIFLARE` (`nix develop .#workers`, #698) or `-Dminiflare=`, because a program the harness
  spawns gets an empty environment; it maps `compatibility_date`, `compatibility_flags`, `vars`
  and `durable_objects` with `migrations` to Miniflare's options, passes `cf: false`, listens on
  127.0.0.1 and disposes at the end. `zig build test-workers` runs the kind; it is not a gate, and
  no CI job runs it yet (#697). The transcript prints each request, its answer with the headers
  sorted as the host keeps them, and the Worker's console lines after each step. The script's
  steps in this slice: a request, `detach`/`answer`, and `abort`. **Two facts measured under
  Miniflare 4.20260518.0**: a client that leaves — through `dispatchFetch`'s signal or a raw
  connection destroyed — never reaches the Worker's `request.signal`, because the Worker's client
  is Miniflare's own entry worker, so #600's second half is owed to a run under `wrangler dev`;
  and a request parked on a wait no host operation of its own answers is cancelled as hung ((d)).
  **Both halves of #600 stay open** (*P705-8*): the first — a release that runs before the
  platform's deadline, and the deadline's value, 25 000 ms in the code — has no fixture either,
  since driving 25 seconds needs a hook (#707). The Worker's own test hooks, in a `--test-hooks`
  build: `/__beni/mark/<text>` writes `beni:mark <text>` to the console, which the driver waits
  for after each step so that a step's console lines never land under the next (*P705-9*), and
  `/__beni/schedulers` answers how many schedulers the kernel lists, so a fixture sees that a
  request's leaves it, and `/__beni/holds` how many answered requests still hold work under
  `waitUntil` (R4-1 of #705's review: `CrossRequest` parks a detached fiber on a `Deferred` a
  later request completes, and the count goes 0, 1, 0). *The object's hooks (2026-10-22, as built):* on a request forwarded to an
  object, a path ending in `/__beni/tick` is the timer's firing — a `ticked` event, answered 204
  once it ran, or 409 when `tick` names no timer — and one ending in `/__beni/alarm` an `alarm`
  event, answered 204; under the flag no host timer is armed, so the transcript is the steps'
  alone. The five object fixtures are listed in (e.10)'s *as built* note. **#593 stays owed**:
  hibernation needs more than the 10 s delay, and a step is limited to 5 s.
- The probes behind every *measured* mark of this section — the cross-request scheduler, the
  abort, the attachment and value sizes, the close handshake — become fixtures of the first code
  slice under this driver; until then their result is what is cited, not a file. Three facts of
  (e.5) and (e.3) are to establish the same way, each with its issue: the live-fiber timer
  prevents hibernation (#593), the call-chain id travels through `stub.fetch` and an RPC stub
  (#594), two objects in one isolate stay isolated (#595), and a request's scope teardown runs
  under `waitUntil` at the platform's deadline and after a client disconnect (#600).

**(l) The owner's answers.** Taken on the dashboard; each is recorded here the day it comes, and
the part of the section it settles keeps its text.

- **`cf-workers-q1`, the platform's name** (Jayson Reis, 2026-10-21 11:28 UTC): **`cloudflare`**,
  as (b) writes it — `--platform=cloudflare`, `platforms/cloudflare/`, `Worker.Program`. The other
  choice, `workerd` after the runtime, was not taken.
- **`cf-workers-q3`, the class names** (Jayson Reis, 2026-10-21 11:28 UTC): **a list in the app's
  `beni.json`**, as (c) and §5.2's `"exports"` key write it; the recommended answer. The other
  choice, one fixed class per Worker, was not taken.
- **`cf-workers-q4`, the Worker's `fetch`** (Jayson Reis, 2026-10-21 11:28 UTC): B, a `sync`
  handler that answers a value the host runs. **Replaced by `cf-workers-q7`** the same day, below;
  (d) keeps its form as the record.
- **`cf-workers-q2`, the object shape** (Cesar Canassa, 2026-10-21 11:50 UTC, on PR #533):
  **neither option as offered — handlers that may suspend, run one at a time**, the end state:
  no `sync` marker and effects inferred; one mailbox per object with the state passed from one
  event to the next; a call-chain id that turns a cycle into `Err Cycle`; spawn then `send` for
  slow work; one fiber runtime per object through `Task.withScheduler`, with its own scope, a host
  timer while a fiber is live, and a defect that closes the scope then aborts; the survival table;
  The Elm Architecture as an optional `Object.element` layer. (e) and (f) are rewritten to it.
- **`cf-workers-q5`, the ownership row** (Cesar Canassa, 2026-10-21 11:52 UTC): **owned, like
  `update`**, as §8 of the same comment says: the state passed between handlers keeps the proposed
  row, and a spawned closure that captures the state makes it escape ((e.7)).
- **`cf-workers-q6`, the tests' time** (Cesar Canassa, 2026-10-21 11:53 UTC): **a hidden build
  flag**: the tests drive a tick and an alarm through hooks that `--test-hooks` compiles in ((k)).
- **`ws-q1`, the WebSocket names** (Cesar Canassa, 2026-10-21): Elm's names for the wrappers; the
  direct forms are `read`, `write` and `close` on `browser` and `node`, and `write` and `close` on
  Workers, which has no `read` (ws-q3); §9.11 and (g) already say so.
- **`ws-q3`, the socket session** (Cesar Canassa, 2026-10-21 11:52 UTC): **each host style** —
  `node` keeps the pull `read` session, Cloudflare uses event handlers so an object can hibernate
  ((g)).
- **`cf-workers-q8`, the message type** (Cesar Canassa, 2026-10-21 12:16 UTC): neither option as
  offered — **the object's message type is its protocol, typed from anywhere**: `define` takes
  the protocol with a schema for it; `Context msg` carries the type; `Object.self : Context msg →
  Ref msg` and `Object.post : Ref msg, msg → ⊤`; the Worker and other objects get typed refs from
  a `Namespace msg`, by name or id, and a post across isolates encodes through the schema;
  `received` is the one entry point for messages from anywhere, and `request` stays for HTTP; a
  post to another object is fire-and-forget; an ask waits like any other host I/O under (e.3)'s
  cycle error; delivery across objects is at most once, with the host's errors as typed results
  ((e.10)).
- **`cf-workers-q7`, may a Worker's `fetch` wait** (Cesar Canassa, 2026-10-21 12:17 UTC): **B,
  as the final design, and it replaces q4's form** (Jayson is told): the Worker's `fetch` is an
  ordinary beni function, `Context, Request → Response`, effects inferred, as an object's
  handlers are; each request runs on its own scheduler (`Task.withScheduler`, #596) and in its own
  scope, so a fiber never resumes in another request's I/O context and a defect fails only its
  own request (1101); `Answer` goes; `Worker.forward ref request` waits and returns the host's
  `Response` with its body stream untouched; typed asks to an `Object.Ref msg` are ordinary waits;
  fibers that outlive the response run under `ctx.waitUntil` with the host's 30-second cap and
  are delivered at most once; a client disconnect interrupts the request's scope, so finalisers
  run ((d)).
- No question of this section is open.

## Appendix — what is deliberately not done

- **User-writable `foreign`.** It has never been made safe in any of the fourteen languages surveyed,
  and the wall is the product.
- **A synchronous port variant.** Three independent mechanisms in Elm exist to prevent it, and the
  failure class it admits is the one nothing can catch.
- **A synchronous escape hatch "just for core".** Core is where the bugs in §4.1 were.
- **Settling for opaque-JSON-only ports.** That is the status quo, and it is the *unchecked* path.
