## 2026-11-08 21:12 CET — private_method and private_name texts name the method

**What I did**

- Issue #1755. The texts the issue quotes ("private to core runtime modules",
  "core's Debug module") come from PR #1754, which merged into the `workers`
  branch only. They are not on master.
- On master the fence has one class, the worker entry names. Its text was
  "This name is private to the platform’s worker entry machinery." for both
  codes: no name, no method, no owner module.
- A private `eq` reached by `==` said "`x.eq` cannot reach it". The program
  wrote `==`.
- `CorePrivate.writeRefusal` is now the one wording map. Resolve's
  `private_name` and dispatch's `private_method` both call it. The texts name
  `Module.name`, the owner modules, and for a method the use and the type.
- The ordinary `private_method` text names the operator when the use is one.
- New fixtures: `check/bad/PrivateEqOperator`,
  `build/bad/dedicated/PrivateRunName`, `build/bad/dedicated/PrivateRunMethod`.
  Each was red on the master binary.
- `static-dispatch-spike.md` §10.2 and `workers.md` record the texts.

**What I learned**

- Check which branch a PR merged into before you reproduce its follow-up. A
  PR merged into a feature branch is not on master.
- `beni build --diagnostics=json` writes the diagnostics to standard error.
