## 2026-11-27 07:10 CET — v3 reads a closure's field path where it is made

**What I did**

- Built v1's §31.6 rule into v3 (kernel §6 rule 3, *A field path a closure captures*): a chain of
  field reads of a captured local is read where the closure is made, and the closure captures the
  value, not the record's slots. A lambda's path is read where it is made, a local function's
  where its `let` starts, a later local's just after the item that binds it, a nested closure's
  at the outermost one. The rows go to the lowering through v3's channel (`Reads.Read.capture`),
  which places them as it places v1's, in every module of the application.
- Read first (§11 item 10) now covers those reads when a write comes before the closure (the
  holder bound where the write runs), and a field that a call writes, read before the call.
- An update reads none of the fields it names of the old record (§11 item 3); the sanitiser's
  record copy takes the named fields from the update alone.
- v3 now accepts 9 of group 2's 10 `browser-inline` pages (#2657). Each has a
  `.sanitize-lists-v3` file. Three v3 refusal fixtures lost the refusals the rule answers.
- `ModelCallback` stays refused: `model.next model.n` is lowered as `model.next(model.n)`, which
  hands the model to the callee as `this`, and the callee can be host code (`Js.to` of a host
  function such as `Object.prototype.valueOf`, which answers `this`).

**What I learned**

- One capture per read instruction made two roots of one cell where a code read `m.world` twice,
  or read `m` whole too: BallMachine's `knob` passed its budget. One path is one capture, and a
  path of a local the code reads whole, or one that holds a `Ref` handle, is read where the code
  runs, as before.
- A field call is a method call in JavaScript. A rule that drops its receiver needs the lowering
  to drop `this` too, in every build.
