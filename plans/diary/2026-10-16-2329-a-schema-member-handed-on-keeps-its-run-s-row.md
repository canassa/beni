## 2026-10-16 23:29 CEST — A schema member handed on keeps its run's row

**What I did.** Took over PR #225 (issue #216) for issue #269, at the owner's request. I rebased its three
commits onto master. Master had taken `ownership-checker.md` §30.10 for schema runs (#218), so #225's
section is now §30.11, with every pointer in the spec, the code and the fixture comments; the earlier diary
entry of #225 still says §30.10, and this entry is the correction. Master also gave `top.a = 2` to `⊤input`
and `3` to `⊤schema`, so `⊤call` moved from `2` to `4`. Then the fix: #225 kept §6.1's cell "made by the
call" for a schema constructor or member that the walk met as a function value (`isSchemaCallable`). With
`apply f s = f s`, `apply Fixed.parse input` answered a fresh value while `Fixed`'s conversion returns the
top-level `kept`, so the push onto it was accepted. Its line said `call (no summary: S.apply)`: the cell
named the call that handed the member on. Now a member handed on as a value is a closure whose class is
its run's row (`memberValue`, `schemaMemberRow` at the arity its type gives), and a schema constructor is a
constructor: a construction when called, `ctorClass` as a value. `isSchemaCallable` and `callArgAt` are
gone. Fixture `ownership/SchemaMemberHanded`: red before the fix (`handed` and `chained` accepted with the
wrong message), rejected `top-level` after. `SchemaCtorBlock` became more precise (`accepted fresh`), and
Conduit's report changed only in fresh numbers. `bench/ownership-everywhere.mjs`: 1 of 850 programs
rejected, `bench/corpus` (#223). Conduit, TodoMVC (all four), Sternhalma and Bike Wars check clean on
`browser-direct`.

**What I learned.** A constructor handed on as a value was already a closure with a synthesised class
(`constructorValue`). The same shape carries a schema member, so the fix needed no new cell kind and no
new class kind. A "no summary" line names the call whose result cell it is, so a cell made on behalf of a
callback names the callee that called it, not the callback.
