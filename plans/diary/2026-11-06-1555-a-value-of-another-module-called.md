## 2026-11-06 15:55 CET — A value of another module, called

**What I did.** Fixed #2132: an imported value with no parameters, called with arguments, was read
through the arity-0 contract of its body, so the program was accepted and the sanitised run trapped. A
published contract is now read for a call only at the call's arity, on the direct route, on each name of
an alias chain and for a function reference used as a value. Everything else is the pessimistic contract.
New fixtures `run/SanitiserValueCallImported` and its `…Apart`; `ownership-v2.md` §2.11.1 amended.

**What I learned.** A block has no contract for a value's lambda: called contracts stop below a
declaration's own parameters. So a bare lambda value, called across modules, costs precision, and the
visible case is a type whose `eq` or `compare` is `λa b → …`: `==` on it now escapes its operands. A writer
held in a top-level value is refused in its own module (`once`), so evidence, whose only reader looks for
writes, was not a route to this defect.
