## 2026-10-29 12:03 CET — item 6 after its second review

**What I did.** The second review of #1127 (`runtime-in-beni-review`, on `964d67067`) found two
release builds that differ from the development build, and the coordinator chose the fixes. I
amended the spec first (`479c8b05d`): item 6's local callee is a `const` whose statement comes
before the statement that evaluates the arrow (F1); a lambda whose call is a `Js.apply` stays a
lambda, a `const` that holds an import is never a callee, and `boundary.md` §4.2 now states the
duty of a `Js.to` that casts a host function to a beni function type (F2, option 1); the bullet on
imports says what an `import` binds under `--release` (F3, which `77ee6b72a` had already fixed:
#1116's key prints `c:jb`); the stale sentence on arity, the host's uses of function identity,
the shapes the code declines and the fixtures that exist are written (F5). Then the code
(`4dac8f07e`): `JsIr.Node` has a `host` column, which `Lower` sets on the `call` it writes for a
`Js.apply` and `Spec`'s `copyNode` and `Copy.node` keep; `Opt` marks a local `const` once its
statement is planned (`initialised`), knows an inner function is hoisted (`func_bound`), records
each `const`'s value (`value_of`, `top_value`) and the names an `import` binds (`imported`), and
`eta` declines a host call, an uninitialised local and a `const` that holds an import through
any chain of aliases. Fixtures: `run/EtaReduceForwardRef`, `run/EtaReduceHostValue` (the
reviewer's probes as a platform package), and `aliasOnce`, `aliasTwice`, `ahead`, `aheadTwice` in
`emit/release/core/EtaReduce`. Every probe of the reviewer prints the same in both builds now.

**What I learned.** The first build of the fix stopped reducing to a parameter and to a local
`const` while evidence and top-level callees still reduced. A trace showed `Opt` recording every
reduction, so the printer was refusing them: `Print.handWritten` compared `Rename.ordinal` of the
callee with the bitset of hand-written imports, but a local name's ordinal is its slot in the
function's own namespace, not a whole-program ordinal. The veto of `77ee6b72a` therefore fired on
any local whose slot number a hand-written global happened to have, and it had not fired on the
goldens only because the first ordinals were emitted modules; the fixture's new `import` of
`Js.lt` moved them. Only a qualified name is tested now. Two smaller things: the checker refuses
a read of a lambda between it and its callee (`let_used_too_soon`), so the reviewer's `tdzmoved`
is not a program and the order rule matters only for a lambda read after its callee is bound; and
a sibling may not name `arguments` (the free-name check), so the alias cases of the run fixture
pin behaviour only and the emit golden pins the shape. The cost of option 1 is visible in every
page: the browser runtime's `Task.onDefect λ⊤ → Js.to (Js.apply stop [])` is a lambda again
(`P=()=>e()`, six raw bytes), and 194 browser hashes moved with it.
