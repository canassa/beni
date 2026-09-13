# The JavaScript boundary: `main`, the platform, and how `foreign` binds

**Commissioned by** the three decisions `fast-compiler.md` §3.1 leaves open for M3 — "the platform
interface, the shape of ports, the runtime" — which are one contract, and by the stance now at the
top of that document: **Elm's walled garden, better equipped.** The wall is not in question. User
code does not reach arbitrary JavaScript; effects cross a controlled boundary. The question this
report exists to answer is narrower and more useful: **what makes Elm's walled interior sparse, and
what would it take to furnish it richly?**

The exemplar is a decision already taken. `Int` is a double, and core ships an opaque `Int32` with
total wrapping arithmetic — a capability Elm lacks, added entirely inside the wall, with no hole cut
anywhere. This report looks for more of that.

**The test stays mechanical:** a capability is admitted when it can be typed such that well-typed
code still cannot crash. Applied to the boundary it splits into two questions that are usually
conflated — *what typing makes a capability safe* (§5), and *who is allowed to write the code that
implements that typing* (§4). Elm answers the first well and the second with two lines of Haskell.

**Sources.** The vendored Elm compiler at `references/elm` (`1bd5b36`, 2026-07-13) read directly;
`elm/core`, `elm/browser`, `elm/bytes`, `elm/file`, `elm/http`, `elm/html`, `elm/time` source and
their `Elm/Kernel/*.js`; the vendored Roc compiler plus the Roc Zulip archive; compiler source and
primary documentation for thirteen other JS-targeting languages; MDN, the WHATWG
HTML/DOM/Fetch/XHR/Streams specs, the W3C File API, ECMA-262 and ECMA-402 for every throwing
condition in §5. **No original measurements were run** — unlike report 12, almost nothing here is
measurable, and §9 says so rather than substituting plausible numbers. The session's web-search
budget ran out partway, so later research used direct URL fetches, the GitHub API, the package
registries and the Discourse and Zulip APIs: better provenance than search results, but no broad
discovery sweep.

---
## 0. The three findings, up front

**1. Elm's privileged interior is guarded by an author whitelist, not a mechanism.**
`references/elm/compiler/src/Elm/Package.hs:84-86` is the whole rule:

```haskell
isKernel :: Name -> Bool
isKernel (Name author _) =
  author == elm || author == elm_explorations
```

Two GitHub organisation names, compiled into the compiler. That one predicate gates three separate
privileges — declaring an `effect module` (`Parse/Module.hs:132-137`), importing `Elm.Kernel.*`
(`Canonicalize/Environment/Foreign.hs:77-82`) and declaring `infix` operators
(`Parse/Module.hs:81`). No property of the code is checked, no review process is encoded, and no
package can acquire the privilege. **The garden is sparse because only one organisation may plant in
it** — a governance fact, not a type-system one. §4 shows Roc has the same privileged interior
attached to a *role anyone can occupy*.

**2. The guarantee lives or dies in the privileged code, and Elm's own privileged code has two holes
in it.** `elm/file` types file reading as infallible — `toString : File -> Task x String`, where the
universally quantified `x` claims the task cannot fail — while its kernel listens only for
`loadend` and passes `reader.result` straight to `__Scheduler_succeed`. But `loadend` fires "when a
file read has completed, **successfully or not**"
([MDN](https://developer.mozilla.org/en-US/docs/Web/API/FileReader/loadend_event)), on failure
`result` is `null` ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/FileReader/result)), and
the File API spec names the causes — the file "may not exist at the time one of the asynchronous read
methods … is called … due to it having been moved or deleted after a reference to it was acquired"
([w3c.github.io/FileAPI](https://w3c.github.io/FileAPI/): `NotFoundError`, `NotReadableError`). So
`null` arrives typed `String`, and the next `String.length` reaches
`function _String_length(str) { return str.length; }` in `elm/core`'s `Elm/Kernel/String.js`, which
does not guard. **Well-typed Elm code crashes.** `_File_toBytes` is worse: `new DataView(null)`
throws inside the listener and the `Task` never completes. This is
[`elm/file#25`](https://github.com/elm/file/issues/25), **open since 2020**.

The second hole is in `elm/http`: `_Http_toTask` wraps `xhr.open` in a `try`/`catch`, but
`_Http_configureRequest` — which calls `xhr.setRequestHeader` for every user header — is not, and XHR
"Throws a **'SyntaxError'** DOMException if name is not a header name or if value is not a header
value" ([xhr.spec.whatwg.org](https://xhr.spec.whatwg.org/)). `Http.header "X Test" "one"` throws out
of an API whose only declared failure type is `Http.Error`; and where `open` *is* caught the value is
wrong, since a forbidden method throws `SecurityError` and is reported as `BadUrl url`. The same
organisation, in the same era, wrote `elm/bytes`'s reader as a total `try`/`catch`. **Trust is not a
mechanism.**

**3. There is a recipe for admitting a capability inside the wall, and Elm already uses it four
times.** Address the foreign object by a *value* and never hold one (`Browser.Dom` takes an id
`String`); marshal every result into plain data; make every spec-defined failure a constructor
(`Http.Error`, `Browser.Dom.Error`); implement it behind a `try`/`catch` in privileged code
(`_Bytes_decode`). §5 turns that into a per-capability roadmap with costs. It is cheap, it is total,
and none of it requires a hole in the wall.

---

## 1. Fourteen languages, and the column that matters

| Language | Declaration form | What the compiler checks about the JS | Runtime guard | Well-typed code can crash | **Who may write it** |
|---|---|---|---|---|---|
| **Elm** | `port` (apps only); `Elm.Kernel.*` JS | payload on a closed list, codec **generated** | **yes** — generated decoder on every inbound port and on flags | only via kernel bugs (§0.2) | **`elm` + `elm-explorations` only** |
| **Dart 3.x** | `external` on extension types over `JSAny` | **which types may cross** (~40 diagnostics) | **partial** — non-nullable return throws on `null`/`undefined` | yes — shape unchecked; `is` unreliable on Wasm | anyone |
| **Scala.js** | `@js.native` facade + `@JSGlobal`/`@JSImport` | richest *declaration-shape* rules in the survey | **dev only** — `fastLinkJS` inserts `$uI` casts, `fullLinkJS` strips them | yes, **and dev and prod disagree** | anyone |
| **PureScript** | `foreign import` + sibling `.js` | export names exist (v0.8.4, 2016); never arity or type | none | yes — silent wrong value | anyone |
| **ReScript / Melange** | `external` + `@val` / `[@mel.*]` | attribute grammar only; module string opaque | none | yes | anyone |
| **Fable** | `[<Import>]`, `[<Emit>]` | attribute well-formedness; **zero** `File.Exists` in `Fable.Transforms` | none | yes — `[<Emit>]` pastes unparsed text | anyone |
| **Gleam** | `@external(javascript, mod, fn)` | **two regexes** on the Gleam strings | none — emits a bare ES import + re-export | yes | anyone |
| **Idris 2** | `%foreign "javascript:lambda:…"` | nothing; declared FFI types **discarded by codegen** | none | yes — **and the function is still `total`** | anyone |
| **Kotlin/JS** | `external fun/class`, `dynamic`, `js("…")` | Kotlin shape only; `@JsModule` name *"is not interpreted by the Kotlin compiler"* | none — no `checkNotNull*` analogue | yes — silent corruption | anyone |
| **Haxe** | `extern class`, `js.Syntax.code` | nothing | none | yes | anyone |
| **GHC JS backend** | `foreign import javascript "((x)=>…)"` | nothing | none | yes | anyone |
| **js_of_ocaml / gen_js_api** | `Js.t` class types, `Js.Unsafe.*`, `[@@js.*]` | nothing; `Ojs.int_of_js` is `"%identity"` | only `[@@js.enum]`/`[@@js.sum]`, ending in `assert false` | yes | anyone |
| **ClojureScript** | `(.m o)`, `#js {}` | externs inference — for *renaming*, not types | n/a | yes (dynamically typed) | anyone |
| **Roc** | platform `hosted { … }` + host glue | host ABI generated by `roc glue`; nothing about the host | none | yes — Roc claims soundness, not crash-freedom | **anyone, but only in a platform** |

**Not one compiler in the survey reads the JavaScript it binds to.** PureScript gets closest: it
*does* parse the FFI file with `language-javascript`, but only to enumerate exported names, and since
0.15 a parse failure is **silently discarded** and the file copied through unchecked
([PR #4250](https://github.com/purescript/purescript/pull/4250): *"the underlying JavaScript parser
fails to parse even valid JavaScript files… If the parse fails, we no longer emit a compiler
error"*). Modern JS syntax disables the only check that exists. Every binding generator in the space
— ts2fable, ts2ocaml, Glutinum, ScalablyTyped, dukat, dts2hx — is **one-way**, never a checker, and
re-verifies nothing when the package changes.

**The one language that bought real safety bought it by restricting the declaration, not by checking
the JS.** Dart rejects `external Function get f;` and `external set list(List _);` outright — *"In
order to ensure type safety and consistency, the compiler places requirements on what types can flow
into and out of JS"* ([dart.dev](https://dart.dev/interop/js-interop/js-types)) — and adds one cheap
null check. Kotlin makes the same move as a *refusal*: `CANNOT_CHECK_FOR_EXTERNAL_INTERFACE` says
"this claim cannot be backed, so you may not make it." **You do not need to verify foreign code if
you forbid stating a claim the boundary cannot support** — exactly what Elm's `checkPayload` does,
four years earlier and more strictly.

**The leak is always one notch below the refusal.** Kotlin's
`UNCHECKED_CAST_TO_EXTERNAL_INTERFACE` is a *warning* with a suppression the IDE inserts for you;
Dart's `invalid_runtime_check_with_js_interop_types` is a *lint*. Where a boundary rule is a warning,
it is not a boundary. Elm is the only survey member whose equivalent rules are all hard errors.
---

## 2. Does any shipped design let user code call JavaScript and keep the guarantee?

**No — and the framing is the answer.** Every mechanism in §1 that is a *call* gives it up; the one
mechanism that keeps it is not a call.

- **A decoder at the boundary works only where it is mandatory.** Gleam's `gleam/dynamic/decode`
  genuinely checks (`int` is `Number.isInteger(data) ? Ok(data) : Error(0)`), but it is **optional**:
  `@external(…) pub fn f() -> Int` hands back an unvalidated `Int`, and `Dynamic` is itself defined
  by an unchecked `@external(… "identity")`. No language requires one except Elm, where it is
  *generated* rather than written.
- **The decoder is itself a crash site.** Sourced 2026 advisories: **HSEC-2026-0007** (aeson) —
  `1e-999999999` in a `Fixed`/`DiffTime` field builds a ~1-billion-digit integer and *"crash[es] the
  host process"*; **CVE-2026-18140** and **CVE-2026-15957** (smithy-rs, CVSS 7.5 each) — *"process
  abort via stack exhaustion"* from *"a single small HTTP request containing deeply nested JSON"*, in
  **machine-generated** deserializers. serde_json caps `remaining_depth: 128` and Swift's `Codable`
  guards `depth < 512`; Gleam's `decode.recursive` carries no bound that was found. **A direct
  constraint on recommendation 1.**
- **Validation spans 470×, and the fast tier is compiled.** From the public
  `typescript-runtime-type-benchmarks` (`node-24.json`, `parseSafe`, ops/s): typia 39,895,308 · zod
  v4 10,571,167 · valibot 1,272,362 · zod 3 803,304 · yup 84,912. typia, ajv and rescript-schema emit
  straight-line JS; the slow tier walks a combinator tree. **A compiler that generates its codecs is
  in the fast tier by construction.**
- **Some JS failures cannot be caught by the code that started them, at all.** V8 heap OOM
  (`node::OOMErrorHandler` — neither `try`/`catch` nor `uncaughtException` fires); a throw inside a
  host-invoked callback (WebIDL's `"report"` behaviour hands the registrar `undefined`); and HTML's
  *"abort the script… **without triggering any of the normal mechanisms like `finally` blocks**."*
- **Nobody verifies the foreign side statically.** JaVerT is the state of the art and *"cannot reason
  about the `for-in` loop and higher-order functions"* — which *are* the FFI boundary.

**Elm's ports keep the guarantee because a port is not a call.** Nothing crosses but data on a closed
list; the codec is generated from the declared type; the inbound decoder runs on every message; and a
decode failure throws in the *JavaScript caller's* stack —
`__Result_isOk(result) || __Debug_crash(4, name, result.a)` in `_Platform_setupIncomingPort` —
leaving the model untouched. No return value, no synchronous entry, no foreign frame on the Elm
stack. **The guarantee is bought by giving up synchronicity and expressiveness, not by verification.**
Ports are therefore the efficient frontier of what ships; the rest of this report is about the three
restrictions Elm stacked on top of them, none of which the guarantee requires.

---

## 3. Elm's boundary, measured

### 3.1 The three privilege levels

| Level | What it may do | Gate |
|---|---|---|
| plain module | nothing foreign | — |
| `port module` | `port` values with closed-list payloads | must be an **application**, never a package |
| `effect module` | define a *new* `Cmd`/`Sub` family (`Canonicalize/Effects.hs:50-73`) | `Parse/Module.hs:132-137`: *"It is not possible to declare an `effect module` outside the @elm organization"* |
| kernel | write JavaScript, import `Elm.Kernel.*`, declare `infix` | `Elm/Package.hs:84-86` |

The middle row is usually left out of the folklore and it explains the sparseness: a package author
cannot ship a new *kind* of effect **even in pure Elm**. The set of things a `Cmd` can be is fixed by
the same two organisations — which, not the difficulty of the JavaScript, is why `localStorage` has
no package: the only sanctioned shape for it is unavailable to whoever would write it.

Evan's stated reasoning, from ["Native Code in 0.19"](https://discourse.elm-lang.org/t/native-code-in-0-19/826),
is four points: **Reliability** (*"People observe that if it compiles, it works… Having arbitrary JS
in packages means giving this up"*), **Portability** (*"Elm will likely compile to WebAssembly some
day… It would be hugely valuable if the entire Elm ecosystem works across a boundary like that"*),
**Security** (*"people cannot put tricks in their packages that mess with your computer"*) and
**Performance / Code Size**, under the instinct *"Discipline is Unreliable… If the path exists,
people will walk it."* **All four are properties of what the foreign code may do, of distribution, or
of output format — none is a property of who wrote it.** §8 takes that seriously.

### 3.2 What may cross a port — the exact list, from the compiler

`Canonicalize/Effects.hs:159-205`, `checkPayload`. Accepted: `Json.Encode.Value`/`Json.Decode.Value`,
`String`, `Int`, `Float`, `Bool`, `List a`/`Maybe a`/`Array a` (recursive), `()`, 2- and 3-tuples,
and closed records of accepted fields. Rejected: type variables (`Error.TypeVariable`), functions
(`Error.Function`), extended records (`Error.ExtendedRecord`), **anything else**
(`Error.UnsupportedType`).

**No user-declared type may cross a port.** The zero-argument branch guards only
Json/String/Int/Float/Bool, so `type Msg = Save | Load` falls through to `UnsupportedType` exactly
like a function does — *narrower* than JSON-serialisable, far narrower than structured clone. The
compiler states its own reasoning in the error text: functions are refused because *"Elm
optimizations assume there are no side-effects"*, and type variables because *"I need to know exactly
what type of data I am getting, so I can guarantee that unexpected data cannot sneak in and crash the
Elm program."* Both are §7's concerns, stated by the compiler that has them.

### 3.3 Where the runtime check is, and what synchronicity costs

The check is **generated from the declared type at compile time**: `Optimize/Port.hs` (326 lines)
folds the canonical type into an ordinary `Json.Encode`/`Json.Decode` expression, and
`Generate/JavaScript.hs:426-432` emits `_Platform_incomingPort(name, decoder)` /
`_Platform_outgoingPort(name, encoder)`. Three consequences: the cost is proportional to the payload
on every message (**no verified number found**); `Json.Value` costs nothing and checks nothing, since
`toEncoder`'s `Name.value` branch is `registerGlobal ModuleName.basics Name.identity`, so the
*recommended* payload type is the one with no marshalling and no validation; and **ports are ordinary
nodes in the dead-code graph** — *"Ports can be dead code eliminated."* A generated boundary stays
visible to reachability; an opaque one would not (§7.1).

Asynchrony is enforced three independent ways: `_Platform_setupOutgoingPort` sets the effect
manager's `init` to `Process.sleep 0` and returns it from every `onEffects`; `subscribe(callback)`
**discards the callback's return value**, so a reply needs a second, incoming port; and
`_Platform_enqueueEffects` serialises dispatch — *"The queue is necessary to avoid ordering issues
for synchronous commands."* `Browser.Dom` pays the same tax *inside* the wall: all seven of its
functions go through `_Browser_withNode`, which wraps the work in
`_Browser_requestAnimationFrame`, so measuring an element and reacting to it is **two frames, ~33 ms
at 60 Hz**, and `focus` — a synchronous, instantaneous DOM call — waits a frame for nothing but
schedulability. That is the clearest single instance in this report of what the typing costs.

Evan has answered the request for request/response ports directly: *"The idea of ports is like
asynchronous messages in Erlang… I think these are all reiterations of wanting a traditional FFI in
Elm… if we have a traditional FFI, we start getting direct ports of JS libraries"*
([discourse 1200](https://discourse.elm-lang.org/t/chadtech-mail-making-ports-act-like-http-requests/1200/4)).
Three community packages exist only to rebuild correlation over a port pair.

### 3.4 `main`, concretely

`Platform.elm` declares `type Program flags model msg = Program` — opaque, no usable constructor, so
only kernel code can make one — and `elm/browser` folds a record of functions into it five ways
(`sandbox`, `element`, `document`, `application`, `Platform.worker`), e.g.
`element : { init : flags -> (model, Cmd msg), view : model -> Html msg, update : msg -> model ->
(model, Cmd msg), subscriptions : model -> Sub msg } -> Program flags model msg`.

Two things to copy. **The platform owns the type of `main` and there is more than one of them** —
five entry points, one `Program` type, differing only in what the platform will supply.
`Navigation.Key` is handed to `init` by `application` and is unforgeable elsewhere, which turns "you
may only push history if the platform manages history" into a type error. And **`flags` is a type
variable** resolved per program and decoded by a compiler-generated decoder — the one place a
whole-program type shapes a runtime check.

### 3.5 The friction, and the claim

The guide's own advice is the summary: *"Definitely do not try to make a port for every JS function
you need… ports are not designed for that."* That is a language telling users its only interop
mechanism does not scale with the number of things they want to interop with — a statement about the
*quantity of capability inside the wall*, not about the wall.

Measured, the friction is a step function. `rtfeldman/elm-spa-example`, the canonical real app by a
core-team member, has **exactly two ports and ~22 lines of inline JS**, all for `localStorage` —
including a `setTimeout(…, 0)` to fabricate a success acknowledgement, because a `Cmd` cannot return
one. The official localStorage example is ~8 lines and reads **only at init, through flags**. The
friction jumps the moment a capability cannot cross a port *at all*, from
[discourse 5743](https://discourse.elm-lang.org/t/what-is-currently-impossible-to-build-with-elm/5743):
*"I'd send the File or Bytes out a port, but they're not port-compatible. Now reimplementing all of
File picking outside Elm."* The sanctioned escape, **custom elements**, is unchecked in both
directions, carries its payload through `property : String -> Json.Value -> Attribute msg`, and is
warned about in Elm's own companion repo — *"if you mess with those nodes too much you risk breaking
their invariants, which in turn will cause runtime exceptions, **even in Elm**"*.

**And the headline claim does not survive contact.** elm-lang.org cites NoRedInk for "No Runtime
Exceptions". NoRedInk's engineering blog, November 2025: *"Although Elm is famous for having no
runtime exceptions, in practice, when browser extensions mutate the DOM behind Elm's back, Elm's
Virtual DOM can get confused and throw errors. **We were getting thousands of those a day.**"* Their
fix was not a port or a custom element — it was replacing three `elm/*` kernel packages with a third
party's forks (`lydell/elm-safe-virtual-dom`), applied by a wrapper script patching a private
`ELM_HOME` before invoking the compiler, because *"`elm/browser` and `elm/html` have not seen a
release in 6 years."* The upstream bug, [`elm/html#44`](https://github.com/elm/html/issues/44), has
been open since **2016-06-25**; Evan declined to caveat the homepage claim in `elm/elm-lang.org#746`
(2018). The guide, unlike the homepage, says *"No runtime errors **in practice**."*

**This is the strongest available argument that sparseness is the problem, not the wall.** The wall
held. What failed was that the privileged interior had one maintainer and a six-year release gap, so
users who needed a fix went *around* the mechanism entirely — the outcome the whitelist exists to
prevent.

---
## 4. Who may furnish the interior

Extending the platform is an ordinary package everywhere except Elm. What that produces is the
interesting part.

| Language | Who maintains the browser/platform surface | Scale |
|---|---|---|
| **Elm** | `elm` + `elm-explorations`, exclusively | `elm/browser`, `elm/http`, `elm/file`, `elm/bytes`, `elm/time`; **no release in ~6 years** |
| **Haxe** | **core team, generated from Mozilla WebIDL** | **565 files**, each headed *"This file is generated … Do not edit!"*; 308 haxelibs tagged `js` |
| **Dart** | first-party `package:web`, generated from WebIDL | the whole platform |
| **Kotlin/JS** | **vendor team** (JetBrains/kotlin-wrappers), largely generated | 84 modules / ~70 artifacts; **both `.d.ts` converters dead** (ts2kt archived, dukat's Gradle integration removed) |
| **Scala.js** | community, **hand-written against MDN/WHATWG prose** | ScalablyTyped peaked at **12,828** generated libraries (2023-03-01); its generator has been broken since 2023-06-28 |
| **PureScript** | separate `purescript-web`/`purescript-node` community orgs | **62,293 `foreign import`s** across the registry; **52.8%** of 648 current packages declare one; `unsafeCoerce` in **197 (30.4%)** |
| **Gleam** | core `gleam_javascript`/`gleam_fetch`; browser surface is **one community package** | `plinth`, 48 modules, one maintainer |
| **Fable** | `fable-compiler` org; `Browser.Dom.fs` is one hand-maintained **164 KB** file | 23 `Fable.Browser.*` packages; ts2fable feature-dead, Glutinum still 0.13.0 |
| **Idris 2** | one person | `idris2-dom`, **4,551** `%foreign` declarations, generator badged WIP |
| **GHC JS** | nobody — `base` ships **no DOM at all** | `ghcjs-dom`, `jsaddle`, `reflex-dom`, `miso`, all community |

**Open access does not by itself produce a maintained platform.** Idris, Gleam, Fable and GHC all let
anyone write bindings and all have a browser surface maintained by roughly one person. Openness
removes a bottleneck; it does not supply labour. **The two healthiest surfaces are generated from a
machine-readable spec by whoever owns the toolchain** — Haxe's 565 WebIDL-derived files and Dart's
`package:web` are the only bindings in the survey both broad and not drifting; every hand-written
surface accumulates a drift log, and two of the three generator pipelines that were **not**
first-party are dead.

**Elm's restriction and Roc's are not the same restriction, and that difference is the finding.** Roc
also has a privileged interior — a platform declares `hosted { … }` entries an application cannot,
owns the type of `main`, and the FAQ is emphatic: *"the platform is in complete control of when all
the Roc code runs… The public API can omit operations that aren't implementable in a particular
host… **Exclusivity is the point!**"* But **privilege attaches to the role, not the author.** Anyone
may write a platform; what nobody may do is declare a hosted effect inside an application.
`lukewilliamboswell/basic-ssg` exposes markdown parsing as a hosted effect — platform "primitives"
are whatever a platform author decides, not a syscall set — and `roc-ray` (2026-09) shows a third
party enforcing rules an application cannot escape (*"**Drawing is legal only in `render!`.** … A
phase violation stops the app as a programmer error"*), with authority routed by type and the host
still checking at runtime.

**So a governance answer that keeps all four of Evan's reasons is: make privilege a property of a
declared role with a checked contract, not of a GitHub organisation.**

---

## 5. The capability roadmap

For each capability: what Elm has, the smallest typed surface that makes every spec-defined failure a
value, and what that typing costs.

| Capability | Elm today | Typable inside the wall? | The cost |
|---|---|---|---|
| Binary data | `elm/bytes`, decoder-only | **yes**, and mostly already right | a bounds check per random read; must own the buffer |
| `Intl` / formatting | nothing; custom element recommended | **yes — the most tractable item here** | validation moves to smart constructors; ~zero runtime |
| Time zones | `elm/time`, POSIX + offset only | **yes** | IANA data payload, or an async round trip |
| DOM beyond vdom | `Browser.Dom`, seven functions | **yes** for reads and commands | one frame per operation; no live node ever held |
| `fetch` / streaming | `elm/http` (XHR), no streams | **yes**, Gleam has the shape | one `Task` per chunk; back-pressure inexpressible |
| Web Workers | nothing | **yes — the easiest of the list** | a full copy per message; no transfer |
| `localStorage` | nothing; ports | **yes, completely** | async round trip over a sync API |
| WebAssembly | nothing | **yes at the boundary** | no shared memory; copy in, copy out |
| Synchronous calls | impossible by construction | **no**, and it should stay no | — |

**Binary data.** `Bytes.Decode.decode : Decoder a -> Bytes -> Maybe a` is the right shape and
`_Bytes_decode`'s `try`/`catch` the right technique, but **Elm does zero per-read bounds checks** —
`_Bytes_read_u32` calls `getUint32` raw. Three consequences: `Bytes.Decode.fail` is `throw 0`, the
same channel as a real `RangeError`, so intentional and spec failure are indistinguishable; the catch
is unqualified, so a stack overflow from a deep `andThen` chain is reported as "corrupt bytes"; and
`Bytes.Decode.string` **does not validate UTF-8**, yielding lone surrogates in a value typed `String`
— a silently wrong value in a "safe" API with no `Maybe` anywhere. Gleam's
`bit_array.to_string : BitArray -> Result(String, Nil)` does validate and is the better model. *Safe
surface:* `getUint32 : Int -> Bytes -> Maybe Int`, bounds-checked per read (ECMA-262 §25.3's
`GetViewValue` throws `RangeError` past the view end and `TypeError` on a detached buffer).
PureScript's `arraybuffer` does exactly this and still has a hole, because on a detached buffer
reading `byteLength` to perform the check itself throws — so the length must be cached in the opaque
wrapper at construction, which means owning the buffer exclusively. **Untypable:** a live
`ArrayBuffer` the host still references, since detachment is someone else's action at an arbitrary
time. Elm gets this right by never letting `Bytes` out.

**`Intl` and time — the best single candidate.** `elm/time` is POSIX time, `Zone` and civil
accessors; no construction, parsing, formatting or locale. The README's reasoning is worth keeping
(*"human time should basically never be stored in your `Model` or database! It is only for
display!"*) but the deferral is explicit — *"I think points (2) and (3) should be explored by the
community before we add anything here"* — and the community cannot, because the answer needs an
effect. `Time.here` is also weaker than it reads: its kernel builds a `customZone` from
`getTimezoneOffset()` with an **empty era list**, so a timestamp across a DST boundary renders
silently an hour off. And the sanctioned workaround reintroduces the crash — the official
custom-element example passes `lang` straight into `new Intl.DateTimeFormat(lang, …)` inside
`attributeChangedCallback`, **inside the virtual-DOM patch**, where ECMA-402's
`CanonicalizeLocaleList` throws `RangeError` on a malformed tag. **Every ECMA-402 throw is argument
validation** (`CanonicalizeLocaleList`, `SetNumberFormatUnitOptions`, `DefaultNumberOption`'s 0..100
range, `supportedValuesOf`), so all of it moves into the type for free — a closed `Style` sum, a
smart-constructed `CurrencyCode`/`Locale`/`FractionDigits`, and then
`NumberFormat.format : NumberFormat -> Float -> String` is total. *Cost: one validation per
construction, none per call, no async round trip.* `new Date(String)` should not exist — ECMA-262
makes it return `NaN` rather than throw and `toISOString` then throws `RangeError` on that well-typed
value; `fromIso8601 : String -> Maybe Posix` is the replacement Elm's own README proposes.

**DOM beyond the vdom.** `Browser.Dom` is the archetype — address by id, return plain data,
`Task Error a` with `type Error = NotFound String`. It needs more members and richer errors, each a
closed set because the specs name the exceptions: `getContext2d` (`getContext` *"Returns **null** if
contextId is not supported, or if the canvas has already been initialized with another context
type"*), `play` (`NotAllowedError`, `NotSupportedError`), `getImageData` (`IndexSizeError`,
`SecurityError`), and a **parsed** `Selector.fromString`, which removes `querySelector`'s
`SyntaxError` from every call site. Two silent-wrong-value cases the type cannot express and which
must be documented instead: `focus()` on a non-focusable node is a no-op that still "succeeds", and
`getBoundingClientRect()` on a `display:none` element returns an all-zero rect. *Cost: one frame per
operation, structurally* — which is why `elm-explorations/webgl` is declarative rather than a bound
context. **Untypable:** a live DOM node as a value (the vdom can remove it underneath you), and
synchronous host→user callbacks (`MutationObserver`, `ResizeObserver`, `requestAnimationFrame`),
which can only degrade to subscriptions. Elm's `preventDefault` answer is worth copying: the event
*decoder* returns `{ message, preventDefault : Bool }`, so the decision is made by pure code during
dispatch.

**`fetch` and streaming.** `elm/http` is XHR-based with no streaming (`Http.track` reports byte
*counts*, never bytes), and 0.19 has no WebSocket story. `Http.Error` is the right shape; the fixes
are a **parsed** header type so `setRequestHeader`'s `SyntaxError` is unreachable (§0.2) and a closed
method sum. Gleam's `gleam_fetch` is the streaming model:
`read_chunk(BodyReader) -> Promise(Result(Option(BitArray), FetchError))` makes end-of-stream a value
and its `UnableToReadBody` constructor *is* the Fetch spec's "unusable body" `TypeError`; the
locked/disturbed `TypeError`s are unreachable only under linearity, so without it they must be a
runtime-checked `Consumed` constructor. *Cost: one `Task` round trip per chunk* — 1 MB at 16 KB
chunks is 64 scheduler hops, and a subscription instead loses back-pressure. **No verified number
found for either.**

**Web Workers — the easiest item, and Elm has nothing.** `Platform.worker` is a headless program, not
a Web Worker. The irony is that **a port-style payload restriction is strictly stronger than
structured clone requires**, so every `DataCloneError` in the HTML spec — symbols, platform objects,
callables, objects with internal slots, proxies, detached buffers, `SharedArrayBuffer` without
cross-origin isolation — is unreachable by construction, and `spawn`/`send`/`onMessage`/`terminate`
over port-legal payloads is total. *Cost: a deep copy per message, exactly what transfer exists to
avoid.* **Untypable:** transfer and `SharedArrayBuffer` + `Atomics`.

**`localStorage` — the clearest case that safety was never the obstacle.** There is no official
package; its predecessor's README reads, in full, *"This package was an experiment that I am not
satisfied with. **Please use PORTS to access localStorage for now.**"* The roadmap's three reasons
**never include that it cannot be typed safely** — *"the general policy is to prioritize things that
cannot be done over things that could be done better"*, and the work *"was not good enough to be
released… it will need to be supported forever… **losing that data could hurt their business.**"* The
spec defines exactly two throwing conditions — `SecurityError` from the getter on an opaque origin or
policy refusal, `QuotaExceededError` from `setItem` — plus one null, so
`type StorageError = Unavailable | QuotaExceeded` over `Task StorageError (Maybe String)` is
**exhaustive**, and `String -> String` is the spec's own type, which kills the `setItem(k, 42)`
coercion bug at compile time. The *official* Elm glue has no `try`/`catch`, so a `QuotaExceededError`
is an uncaught exception in the subscriber that Elm never learns about: **the port version is less
safe than the typed version would be.**

**WebAssembly.** Every JS-API failure is at a boundary — `CompileError`, `LinkError`, `RuntimeError`
on a trap, `RangeError` on `Memory.grow` — so `load : Bytes -> Imports -> Task LoadError Instance`
reflecting the export signatures once, plus per-call `Task CallError a`, is total. *Cost: no shared
memory, so wasm serves pure compute and not the zero-copy pipelines it is usually chosen for.*

**The rule this section converges on:** a capability is admissible inside the wall exactly when its
failures are enumerable from a specification and its values can be marshalled to plain data. It is
inadmissible when it requires holding a live host object whose validity someone else controls
(detachable buffers, DOM nodes, streams, shared memory), or when it requires the host to call
synchronously into user code.

## 6. What a platform is, and what beni's must be

**A Roc platform is a header plus a host.** `platform ""` declares `requires` (what the application
must provide), `exposes`, `packages`, `provides` (what the host calls) and `hosted` (the effects the
platform implements). `basic-cli`'s `main` branch (2026-09-09) requires
`main! : List([Utf8(Str), UnixBytes(List(U8)), WindowsU16s(List(U16))]) => Try({}, [Exit(I32), ..])`,
provides `"roc_main"`, and lists ~60 `hosted` entries.

`basic-webserver` is three entry points — `init!`, `respond!`, `shutdown!` — the same pattern as
Elm's five `Browser.*` functions landing differently because the domain differs. Roc deleted `Task`
outright on 2025-01-09 (PR #7487, +430/−14,391) in favour of purity inference (PR #7170), and its
safety claim is narrower than Elm's and stated as such: *"the type system is sound… If the program
reaches the error at runtime, it will crash."*

**Most of what a Roc platform provides does not exist on a JavaScript target.** Allocation, the
scheduler, stack-overflow handling (`src/base/signal_handler.zig`: *"Generated Roc code does not
install or call this module"*), process lifetime and the host ABI are all V8's job. Three things are
left, and they are the three beni must define: **the type of `main`**; **the set of effects** (the
`hosted` list, which on JS is §5's typed capabilities plus ports); and **the loop** — who calls the
application, when, and with what.

**A browser platform.** The Elm Architecture is the only serious contender, and the survey supports
that rather than restating it: **no JS/web Roc platform was found**; Leptos-style signals need
fine-grained mutable reactivity a pure value model cannot express without a runtime beni would then
own; and a plain `IO`-style entry point gives up the thing the design rests on — that `view` is a
pure function of the model, which is what makes §9.1's elimination exact and §9.5's `lazy` type
rewrite meaningful. So `main` is a record of `init`/`view`/`update`/`subscriptions` folded into an
opaque `Program flags model msg`, with more than one entry point differing in what the platform
supplies (§3.4), and each platform-supplied capability handed to `init` as an unforgeable value.
**A Node platform for tests** needs `Platform.worker`'s shape plus an **exit code** — Roc's `main!`
returns `Try({}, [Exit(I32), ..])` for exactly this reason, and a test runner that cannot fail a CI
job is useless.

---

## 7. What the boundary costs the rest of beni's design

### 7.1 Dead-code elimination (§9.1) — the one place there is hard evidence

**Elm solved this, and the solution degrades visibly in the source.** A kernel `.js` file is not
opaque JavaScript; it is a *template* parsed by `Elm/Kernel.hs` into chunks, and
`AST/Optimized.hs:204-216` turns every `ElmVar`/`JsVar` chunk into a real edge in the same global
graph the DFS from `main` walks — **a whole-program compiler can see through its own foreign code and
a bundler cannot, because the foreign code is written in a dialect the compiler reads.**

The degradation is granularity. `AST/Optimized.hs:218-220` keys every kernel `.js` file to **one**
graph node named `$` (`Global (ModuleName.Canonical Pkg.kernel shortName) Name.dollar`), so reaching
one function in `Elm.Kernel.String` pulls in all of `String.js` — module-granular tree-shaking
reappearing at the foreign boundary, which is what §9.1 exists to beat. Report 12's byte attribution
shows the same from the other side: 45.5% of Elm's TodoMVC bundle is hand-written runtime.

**The fix is already specified.** `language.md` §5.4 requires *"a sibling JavaScript file exporting
one function per foreign value, under the same name"* — one export per foreign value is one graph
node per foreign value, so beni stays declaration-granular where Elm goes file-granular. What must be
added is the *dependency* half: Elm recovers it by parsing `__Mod_name` markers; beni, emitting ESM,
recovers it from the sibling file's own `import` statements. **Make it a build-time check**: a
sibling `.js` whose exports reference anything not reachable from its own imports is a build error.

### 7.2 Purity (§3.1), and therefore the elimination's correctness

§9.1's exactness rests on purity, and a `foreign` declaration is where that proof is *assumed*. It
covers less than it appears, because §3.1 already decided effects are values interpreted by a
platform: a `foreign` of type `Task e a` or `Cmd msg` is pure to *evaluate* by construction, and its
interpretation happens in the platform, the one place impurity is expected. The dangerous shape is a
`foreign` that is neither pure nor an effect — `foreign now : Float` — which breaks elimination,
common-subexpression reasoning, `lazy` chunk assignment and the §8.2 `decl_val`/`decl_ty` split.
**The rule costs nothing to enforce:** a `foreign` is either (a) a total pure function over
already-admitted types, or (b) an effect value. Nothing else. All 65 of core's current `foreign`
values are (a); every capability in §5 is (b). The compiler cannot verify which it is, but it can
verify the *type*, and the type is what the rest of the pipeline reasons from. `Debug.log : String ->
a -> a` is the one deliberate violation, as it is in Elm.

Two corroborations. Elm's own port error text refuses functions *because "Elm optimizations assume
there are no side-effects"* — the same reasoning, reached independently. And Gleam's
`gleam_javascript` declines to make `Promise` generic over its error type because *"any Gleam panic
or JavaScript exception could alter the error value in an way that undermines the type, making it
unsound and untypable"* — a core package documenting that an uncaught foreign throw breaks the type
system, which is why §5's `try`/`catch` discipline is non-negotiable in privileged code.

### 7.3 The M4 interface firewall (§8.1)

**No problem, and the bit already exists.** `checker.md` §7 specifies
`values: [] { name, scheme, is_foreign: bool }` — foreignness is one bit derived from source text and
nothing about the JavaScript appears, so the interface stays a pure function of the `.beni` source,
which is the firewall's requirement. What changes is the **cache key**: §8.1's key must add **the
content hash of the sibling `.js`**, an input hash exactly like the source bytes, invalidating the
module's own `emit` unit without touching any dependent's `decl_ty`. Editing a sibling `.js` rebuilds
one module's output and nothing else — strictly better than Elm, where kernel code lives in the
package and any change re-runs the package build. One requirement to state now rather than debug in
M4: **the `stat` fast-path must cover sibling files**, not only `.beni` files.

## 8. Recommendations, ranked

**1. Keep ports as the user-facing boundary, and widen the payload to any type the compiler can
generate a codec for.** Elm's `checkPayload` list is not what buys the guarantee; *generating the
codec from the declared type* is. A beni ADT is trivially codec-able — a closed set of constructors
with known argument types — and admitting it removes the most-cited friction in §3.5 without touching
the safety argument. Refuse what Elm refuses for reasons that are actually about safety: functions,
type variables, extended records, anything containing a foreign type. **Give the generated decoder a
depth bound**, because §2 shows machine-generated deserializers are themselves a crash site.
*Guarantee: preserved. Cost: one more constructor case in the codec generator; payload grows with
ADT tags.*

**2. Make privilege a role with a checked contract, not an author list.** All four of Evan's reasons
(§3.1) survive a rule about the code. Concretely: `foreign` stays illegal in ordinary modules; a
**platform package** may declare foreigns and hosted effects; a platform is an ordinary package
anyone may publish, identified by a manifest key rather than a GitHub organisation. Add the checks
Elm lacks — a foreign's type must be (a) or (b) from §7.2, the sibling `.js` must export exactly the
declared names, and its imports must cover its references (§7.1). *Guarantee: the same one Elm has,
plus two mechanical checks Elm lacks. Cost: a manifest concept in M4, and the security argument now
rests on distribution rather than the compiler — which is where it rests in every other language in
the survey anyway.*

**3. Ship the `Intl` and time capability first.** Every ECMA-402 failure is argument validation, so
it moves into smart constructors at zero runtime cost; it is the capability Elm most conspicuously
lacks; and its sanctioned workaround demonstrably reintroduces crashes into the virtual-DOM patch.
*Guarantee: preserved. Cost: one validated-newtype pattern, reused everywhere after.*

**4. Adopt the four-part recipe as a written contract for privileged code, and test it.** Address
foreign objects by value; marshal results to plain data; every spec-defined failure is a constructor;
every privileged entry point wrapped in `try`/`catch`. §0.2 is what happens without it, from the
organisation that invented the wall. js_of_ocaml shows the right code shape: `Js.Unsafe.coerce` is a
*private* primitive and the public export is `CoerceTo`, which wraps it in a real `instanceof` and
returns `'a Js.opt`. Systems that export the unchecked coercion publicly end up with it as the
documented route for routine work — `web-sys`'s manual tells you to use `unchecked_ref` for **every**
closure. Testable form: **a corpus scenario per capability that forces the failure path and asserts a
value comes back.** *Guarantee: the one silently lost in `elm/file`. Cost: a `try`/`catch` per
foreign effect, and the discipline to write the failing test.*

**5. Make `main` a platform-owned opaque `Program`, with more than one entry point.** §3.4 and §6.
Copy the unforgeable-capability trick — anything the platform manages is handed to `init` as a value
no other code can construct. Browser platform is TEA; Node platform is `worker`-shaped plus an exit
code. *Guarantee: preserved. Cost: `main`'s type is a platform fact, so M3 resolves it per platform
rather than hardcoding one.*

**6. Keep ports asynchronous; do not add a synchronous variant.** §3.3 lists three independent
mechanisms Elm uses and §2 says why: a synchronous call means a foreign frame on the beni stack, a
throw landing mid-`update`, and host callbacks into user code — the failure class nothing can catch.
The ergonomic complaint is real and the answer is not sync but **correlation**: ship the
request/response layer three Elm community packages had to rebuild, as a core `Task`-shaped API over
one port pair. *Guarantee: preserved. Cost: one frame of latency, permanently.*


**Explicitly not recommended.** User-writable `foreign` (§1 shows it has never been made safe);
settling for `Json.Value`-only port ergonomics (that is the status quo, and it is the *unchecked*
path); a synchronous escape hatch "just for core" (§0.2 is the evidence that core is where the bugs
are).

## 9. Open questions this report could not resolve

1. **Almost every cost in §5 is structural, not measured.** No benchmark exists anywhere in the
   survey for port marshalling, per-read bounds checks, `Task` round-trip latency, or
   structured-clone copy cost. The only quantitative facts obtained are that `Browser.Dom` defers
   every operation by one `requestAnimationFrame`, that `elm/bytes` performs zero per-read checks,
   and §2's validator benchmark. **If the async round trip dominates, recommendation 6 is the one
   that breaks**, and nothing in the literature says whether it does.
   that breaks**, and nothing in the literature says whether it does.
2. **Whether a generated codec for user ADTs across ports is affordable.** Recommendation 1 assumes
   it is because Elm already generates codecs for records and lists — but nobody has published the
   cost of the codecs Elm *does* generate, so the marginal cost of one more case is unknown.
3. **Three absences, all searched for directly**: no Evan statement on Web Workers, on `elm/http`'s
   choice of XHR over `fetch`, or on why `elm-lang/websocket` was dropped in 0.19; the
   virtual-DOM-ownership argument for refusing direct DOM access was never found in his own words
   (this report infers it); and js_of_ocaml's modern half is unresearched — Melange's `[@mel.*]`
   family, OCaml 5, `wasm_of_ocaml`, `brr`'s `Jv`, opam counts.
4. **Dart's behaviour on a non-null *primitive* mismatch is unverified.** The null check is
   documented; whether dart2js emits a type check when `external String` returns a number is inferred
   from `native/behavior.dart` modelling interop returns as `dynamic`, not confirmed, and is probably
   backend-dependent — which would make Dart's "sound" claim weaker still.
5. **Idris 2's `%foreign` is unconditionally `total`** — derived from compiler source
   (`Core/TT.idr`'s `unchecked = MkTotality Unchecked IsCovering` plus an empty size-change graph),
   corroborated by [PR #2268](https://github.com/idris-lang/Idris2/pull/2268) hand-downgrading
   `fGetLine` to `covering` and by `idris2-dom`'s 4,551 declarations under `%default total`. **No
   statement from Edwin Brady was found** and the FFI docs never mention totality. It is the sharpest
   instance of this report's thesis and is stated as source-derived, not authoritatively confirmed.
6. **No bug-tracker label, audit or study quantifying FFI type-mismatch defects exists in any of the
   fourteen ecosystems.** Every incident cited is sampled, not counted. The claim that unchecked FFI
   causes defects in practice is well-evidenced anecdotally and **has never been measured**.
7. **A first research pass on §2 returned fabricated CVE identifiers and benchmark numbers**, caught
   only because a second pass re-derived them. The advisories and the benchmark table in §2 are the
   re-verified ones; anything not stated there should be treated as unsourced. This is recorded
   because it is the kind of failure a reader cannot otherwise detect.
