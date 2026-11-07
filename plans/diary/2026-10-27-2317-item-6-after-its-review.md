## 2026-10-27 23:17 CET — item 6 after its review: no sibling callee, the test on the printed name

**What I did.** Answered the Claude workflow review of #1127. Two points changed the rule, both in
`backend.md` §9 item 6 first (dated amendments): a name an `import` binds is no longer a callee —
under `--release` those are the siblings and the platform's runtime, hand-written functions that may
read `arguments` or `this`, so a host calling the reduced value with more arguments than the lambda
took could see a difference, where an emitted function (no rest, no default, no `arguments`, no
`this`) cannot — and the stability tests run on the name the printer writes, the callee after item
1's substitution, not on the name written. `countStmt` asserts that no emitted statement rebinds a
top-level `const` or function, `eta`'s comment carries the planning-order argument (`planList` plans
a list's bindings before it descends), and `resolve`'s says why a third step cannot exist. Fixtures:
`viaLetAlias` in `emit/release/core/EtaReduce` (a `let` behind an alias stays a lambda), and
`run/EtaReduceHost`, where `String.prototype.replaceAll` calls the reduced value with the match, its
offset and the whole string; `JsCompare`'s `viaValue`, a forwarding lambda to the sibling's `lt` taken
as a value, is a lambda again and pins the exclusion. Then #1116 restacked on the new head. Gates at `-j4` green on the head (4 min 15 s, 9.6 GB peak in its scope).

**What I learned.**
- η-reduction is sound for emitted code and only for emitted code: JavaScript lets a callee see its
  caller's arity (`arguments`, defaults, rest) and its receiver (`this`), and a hand-written sibling
  is promised neither. The boundary of the rule is "who wrote the function", so the callee set is
  "what this file binds", and under `--release` an `import` is exactly a sibling or the runtime.
- Check the name you print, not the name you read: item 1 may already have replaced the callee, and
  the tests on the written alias prove nothing about its target.
- A hand-written `.expected` is a guess until the fixture runs: `replaceAll("-", m => m + "+")` yields
  `a-+b-+c`, not `a+b+c`, since the replacer receives the match. The blessing run is the oracle; keep
  a copy of the guess and compare, so a wrong guess is a finding and not a silently blessed golden.
- A session can end while its heavy job runs; the job dies with it. The chain's logs and the blessed
  tree survive, so the restart reads them first and reruns only what did not finish.
