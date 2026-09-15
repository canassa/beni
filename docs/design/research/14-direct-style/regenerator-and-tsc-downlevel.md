# Compiling suspension to a `switch`: regenerator, `__generator`, and what the transform costs

**Commissioned by** `fast-compiler.md` §3.2's option **C — "Emit a state machine ourselves"**, listed
there as "a real backend transform, the thing Rust and C# do for `async`" with the cost column left
as a guess. This report is the evidence for that row. The transform in question is not hypothetical
and not exotic: it has been written three times for JavaScript specifically — Ben Newman's
regenerator (2013), Ron Buckton's `generators.ts` in the TypeScript compiler (2016), and Babel's
in-tree fork of regenerator (2025) — and between them they have shipped it to every ES5 browser for
a decade. Everything a beni backend would have to decide, these three already decided, in public,
in code we can read.

**Scope, as revised mid-research.** The programme owner narrowed this report to **ergonomics and
structure only**: what the transform can and cannot express, what it does to the user's code, to
source locations, to stack traces and to the debugger, and what it demands of the compiler
pipeline. **No performance work, and no numbers.** Timings and allocation counts that had been
gathered before the change are discarded and do not appear here; §8 records the question as
deliberately unanswered rather than unsourced.

**Sources.** Read directly: regenerator's transform source at `facebook/regenerator@main`
(`packages/transform/src/{emit,leap,meta,hoist,visit,util}.js`, 2,254 lines) and Babel's current
in-tree fork (`babel/babel@main`, `packages/babel-plugin-transform-regenerator/src/regenerator/*.ts`,
2,288 lines); regenerator's `packages/runtime/runtime.js` (761 lines); TypeScript's
`src/compiler/transformers/generators.ts` at `release-5.9` (3,284 lines) and `es2017.ts`;
`microsoft/tslib@main/tslib.js` (484 lines); the TypeScript 7 Go port's
`tsc/internal/transformers/estransforms/` directory listing and `async.go`. Ben Newman's JSConf 2014
slide deck *"Yield Ahead: Regenerator in Depth"* was fetched as HTML and read in full. Primary issue
and PR threads via the GitHub API: `microsoft/TypeScript#62196`, `#14506`, `#16376`;
`babel/babel#17205`, `#17249`, `#17268`, `#17287`, `#17334`, `#17359`, `#17426`, `#17556`, `#17608`.
Practitioner counts via the Stack Exchange API and the npm registry API. **Compiled-output samples**
in §2 were produced by running Babel 8.0.5 (`@babel/plugin-transform-regenerator` 8.0.5) and
TypeScript 5.9.3 `--target es5` **before** the read-only rule took effect; they are reproduced here
because output shape is explicitly in scope, and they are labelled with the exact tool versions.
Nothing was run after the rule change. All web sources accessed **2026-09-14**.

---

## 0. The three findings, up front

**1. Two independent implementations converged on the same architecture, down to the number of
kinds of jump target.** Both compile the function body to a linear *listing* of statements with
numbered jump labels, then wrap that listing in `while (1) switch (ctx.next) { case 0: … }`, and both
maintain a stack of enclosing "leap targets" so that a `break`, `continue`, `return` or `throw`
crossing a `try` is compiled into a call to the runtime rather than a jump. Regenerator calls the
stack the **leap manager** and its entries are `FunctionEntry`, `LoopEntry`, `SwitchEntry`,
`TryEntry`, `CatchEntry`, `FinallyEntry`, `LabeledEntry`
(`packages/transform/src/leap.js:17-125`). TypeScript calls it a block stack and its entries are
`CodeBlockKind { Exception, With, Switch, Loop, Labeled }`
(`src/compiler/transformers/generators.ts`, enum after the header comment). The two lists are the
same list. TypeScript additionally documents an **explicit intermediate instruction language** in a
120-line header comment — `.mark LABEL`, `.br LABEL`, `.brtrue`, `.brfalse`, `.yield (x)`,
`.try TRY, CATCH, FINALLY, END`, `.endfinally`, `.throw`, `.return` — with a side-by-side table of
what each instruction emits. That header comment is the single most reusable artefact this report
found: it is a specification of the transform, written by the person who implemented it, and beni
could implement against it directly.

**2. The transform is a *statement* rewrite that is forced to become an *expression* rewrite, and
that is where all the difficulty lives.** Moving statements around is easy. The hard part is that
`yield` is an expression, so `f(a(), yield b(), c())` requires the compiler to prove that `a()`
still means what it meant before the suspension — and it cannot. Regenerator's answer is a discipline
its author named "exploding": every sibling subexpression of a suspension point is hoisted into a
generated temporary, in source order, so that the order of side effects is preserved across the
suspension. The comment above `explodeViaTempVar` (`emit.js:913-921`) is the whole design: *"In order
to save the rest of `explodeExpression` from a combinatorial trainwreck of special cases,
`explodeViaTempVar` is responsible for deciding when a subexpression needs to be 'exploded' … The
point of exploding subexpressions is to control the precise order in which the generated code
realizes the side effects of those subexpressions."* And the reason it must be conservative
(`emit.js:935-950`): *"in general, a temporary variable is required whenever any child contains a
yield expression, since it is difficult to prove (at all, let alone efficiently) whether this result
would evaluate to the same value before and after the yield (see #206). One narrow case where we can
prove it doesn't matter … is when the result in question is a Literal value."* Three lines earlier in
the same file the invariants are stated bare: *"All side effects must be realized in order. If any
subexpression harbors a leap, all subexpressions must be neutered of side effects. No destructive
modification of AST nodes."* (`emit.js:337-343`).

**3. The transform's debt is paid mostly in the debugger, and the two implementations paid it
differently — badly, then deliberately.** Both must hoist every local binding to the top of the
outer function, because the state machine's cases are separate `switch` arms and a `var` declared in
one arm must survive into the next. TypeScript did the obvious thing and kept the original source-map
range on the hoisted declaration; the result, reported by Rob Lourens of the VS Code debugger team on
2017-03-07 (`microsoft/TypeScript#14506`), was that *"If you set a breakpoint on the `let x` line in
Chrome DevTools or VS Code, it actually sets a breakpoint on the `var x` line which runs before the
`await foo` line. So it's practically impossible"* to break after an `await`. The fix
(`microsoft/TypeScript#16376`, rbuckton, merged 2017-06-08) moves the mapping off the hoisted
declaration and onto the *assignment* at the original site — `generators.ts:1387-1395`,
`transformInitializedVariable`, wraps the generated `x = init` in `setSourceMapRange(…, node)` and
separately re-maps the cloned name. Regenerator carries a comment recording the same hazard from the
other direction (`hoist.js:29-31`): *"we duplicate `dec.id` here to ensure that the variable
declaration IDs don't have the same `loc` value, since that can make sourcemaps and retainLines
behave poorly."* **Line-level source maps survive the transform; a naive implementation of the
hoisting step silently destroys single-step debugging, and both implementations had to be told.**

---

## 1. The effect model: there isn't one

These are compiler transforms, not effect systems, and that is exactly why they are useful to beni:
they isolate the *sequencing mechanism* from any opinion about what is being sequenced.

The only thing the transform knows is that `yield <expr>` means "hand `<expr>` to whoever is driving
this function, suspend, and resume here with whatever they hand back." Nothing in `emit.js` or
`generators.ts` knows what a Promise is. `meta.js:93-99` defines the complete list of things the
transform treats as control-flow events:

```js
// These types are the direct cause of all leaps in control flow.
let leapTypes = {
  YieldExpression: true,  BreakStatement: true,  ContinueStatement: true,
  ReturnStatement: true,  ThrowStatement: true
};
```

Five node types. Everything else in the language is either "contains one of these somewhere below"
or "does not", and the latter is emitted verbatim.

**Async is a driver, not a second transform.** Newman's JSConf 2014 slides show the whole of it, on
one slide, under the heading "Easy now: `async` functions":

```js
wrapGenerator.async = function(innerFn, self, tryList) {
  return new Promise(function(resolve, reject) {
    var generator = wrapGenerator(innerFn, self, tryList);
    var callNext = step.bind(generator.next), callThrow = step.bind(generator.throw);
    function step(arg) {
      try { var info = this(arg); var value = info.value; }
      catch (error) { return reject(error); }
      if (info.done) resolve(value);
      else Promise.resolve(value).then(callNext, callThrow);
    }
    callNext();
  });
};
```

TypeScript's is the same shape and size — `tslib.js:164-172`, `__awaiter`, nine lines. The
TypeScript 7 Go port keeps `__awaiter` and drops the state machine entirely; its comment
(`estransforms/async.go:765-769`) still describes the split: *"An async function is emit as an outer
function that calls an inner generator function. To preserve lexical bindings, we pass the current
`this` and `arguments` objects to `__awaiter`."* **The suspension transform and the thing that
interprets the suspensions are cleanly separable, and the interpreter is about a dozen lines.** For a
`Task e a` interpreted by a beni runtime, it would be a dozen lines of a different shape.

**Typing.** Neither transform consults a type. Regenerator is a Babel plugin operating on an
untyped AST; `visit.js` triggers on `node.generator || node.async` and nothing else. TypeScript's
runs after type erasure in the emit pipeline, not in the checker. The colour on the signature
(`function*` / `async`) is syntactic, and it is the *only* input.

---

## 2. The mechanism

### 2.1 Two stages, in both implementations

**Stage 1 — lower the body to a flat listing with labels.** Regenerator's `Emitter` keeps
`this.listing` (an array of statements) and `this.marked` (a set of offsets that are jump targets).
A label is a mutable AST node: `loc()` returns `b.literal(-1)` and `mark(loc)` back-patches its
`.value` to the current listing length (Newman's slides quote both functions verbatim; current source
at `emit.js:81-93`). A jump is `ctx.next = <loc>; break;`; a conditional jump is `jumpIfNot`, which
emits `if (!test) { ctx.next = toLoc; break; }` and avoids double negation.

TypeScript keeps the same information as an explicit opcode array — `Nop, Statement, Assign, Break,
BreakWhenTrue, BreakWhenFalse, Yield, YieldStar, Return, Throw, Endfinally` — and its header comment
gives the emission table directly:

```
//  .mark LABEL                   | case LABEL:
//  .br LABEL                     |     return [3 /*break*/, LABEL];
//  .brtrue LABEL, (x)            |     if (x) return [3 /*break*/, LABEL];
//  .yield (x)                    |     return [4 /*yield*/, x];
//  .mark RESUME                  | case RESUME:
//      a = %sent%;               |     a = state.sent();
//  .mark TRY                     | case TRY:
//                                |     state.trys.push([TRY, CATCH, FINALLY, END]);
//  .endfinally                   |     return [7 /*endfinally*/];
```

**Stage 2 — wrap the listing in a dispatch loop.** `Ep.getDispatchLoop` (`emit.js:246-300`) walks
the listing and opens a new `switchCase` at every marked offset; its own comment is the output shape:
*"Turns `this.listing` into a loop of the form `while (1) switch (context.next) { case 0: … case n:
return context.stop(); }`. Each marked location in `this.listing` will correspond to one generated
case statement."* The transform's one micro-optimisation is `getUnmarkedCurrentLoc`
(`emit.js:868-874`): *"There's no logical harm in marking such locations as jump targets, but
minimizing the number of switch cases keeps the generated code shorter."*

### 2.2 The per-construct rewrite rule

Newman's slides walk `ForStatement` through, line by line, and the current source is unchanged
(`emit.js:496-535`):

```js
case "ForStatement":
  var head = loc(); var update = loc(); var after = loc();
  if (stmt.init) self.explode(path.get("init"), true);
  self.mark(head);
  if (stmt.test) self.jumpIfNot(self.explodeExpression(path.get("test")), after);
  self.leapManager.withEntry(
    new leap.LoopEntry(after, update, labelId),
    function() { self.explodeStatement(path.get("body")); }
  );
  self.mark(update);
  if (stmt.update) self.explode(path.get("update"), true);
  self.jump(head);
  self.mark(after);
  break;
```

That is the entire loop rule. `LoopEntry(after, update, label)` registers `after` as the `break`
target and `update` as the `continue` target; `getBreakLoc`/`getContinueLoc` (`leap.js:148-179`) walk
the entry stack outwards, skipping `LabeledEntry` frames unless the `break` names a label. **Fifteen
statement kinds are handled** — `ExpressionStatement`, `LabeledStatement`, `WhileStatement`,
`DoWhileStatement`, `ForStatement`, `ForInStatement`, `BreakStatement`, `ContinueStatement`,
`SwitchStatement`, `IfStatement`, `ReturnStatement`, `WithStatement`, `TryStatement`,
`ThrowStatement`, `ClassDeclaration` — plus `BlockStatement` and `VariableDeclaration` generically in
`explode`. Anything else reaches `default: throw new Error("unknown Statement of type " + …)`
(`emit.js:777-781`).

### 2.3 Exploding expressions: the temp-var discipline

`explodeExpression` (`emit.js:956-…`) begins with the only cheap case — *"If the expression does not
contain a leap, then we either emit the expression as a standalone statement or return it whole"*,
i.e. `if (!meta.containsLeap(expr)) return finish(expr);`.
Otherwise every child that is a sibling of the leap goes through `explodeViaTempVar`, which emits
`_t0 = <child>` into the listing and substitutes `_t0`. That covers `MemberExpression`,
`CallExpression` (callee and every argument), `NewExpression`, `ObjectExpression` values,
`ArrayExpression` elements, `SequenceExpression`, logical `&&`/`||`, and the conditional operator —
about fifteen expression forms, all in one `switch`. Two node types are declared **opaque** and never
descended into (`meta.js:76-79`): `FunctionExpression` and `ArrowFunctionExpression`. A `yield` inside
a nested closure is therefore *not* the enclosing generator's yield — which is the correct semantics,
and is also the reason the transform is compositional at all.

### 2.4 `try`/`finally` and abrupt completions

This is the part that cannot be done with jumps alone, and both implementations solve it the same
way: the compiler emits a **static table of protected regions** and the runtime does the search.

Regenerator's `getTryLocsList` (`emit.js:303-334`) emits, per `try`, the tuple
`[firstLoc, catchLoc, finallyLoc, afterLoc]` with holes for absent clauses, and passes the array as
the fourth argument to the runtime wrapper. TypeScript emits the identical tuple as
`state.trys.push([TRY, CATCH, FINALLY, END])`. Any `break`, `continue`, `return` or `throw` that might
cross a protected region is not compiled to a jump but to `return ctx.abrupt(type, target)`
(`emitAbruptCompletion`, `emit.js:799-840`); the runtime's `abrupt` scans `tryEntries` innermost-out,
and if it finds a `finally` between here and the destination it diverts there first, stashing the
pending completion. The end of a `finally` is `return ctx.finish(finallyLoc)`, which pops the stash
and resumes it.

Two consequences worth naming:

- **`ctx.prev` exists only because the compiler cannot afford precision.** `emit.js:888-902`:
  *"If we were implementing a full interpreter, we would know the location of the current instruction
  with complete precision at all times, but we don't have that luxury here, as it would be costly and
  verbose to set `context.prev` before every statement."* So the `switch` discriminant is
  `ctx.prev = ctx.next`, and `updateContextPrevLoc` patches it at the few places where falling into a
  `try` or a `finally` would leave it stale.
- **The catch parameter has to be renamed.** `catchParamVisitor` (`emit.js:784-798`) rewrites every
  reference to the `catch (e)` binding to a generated temp, because the state machine has no block
  scope to hold `e` in, and skips nested scopes that shadow the name.

### 2.5 The hard cases

Written as JavaScript generators, with the actual emitted state machine alongside. *(Output produced
with Babel 8.0.5 / `@babel/plugin-transform-regenerator` 8.0.5 and TypeScript 5.9.3 `--target es5`,
before the read-only rule; reproduced for shape.)*

**`fetchSummary`, with a bind in a loop, a bind in a branch and a `try`/`finally`:**

```js
function* fetchSummary(db) {
  var user  = yield db.getUser();
  var perms = yield db.getPermissions(user);
  var total = 0;
  for (var i = 0; i < perms.groups.length; i++) {
    total += yield db.getGroupSize(perms.groups[i]);   // bind inside a loop
  }
  try {
    var log = yield db.getAuditLog(user);              // bind inside a try
    return user + perms.n + total + log;               // early return out of the try
  } finally {
    total = 0;
  }
}
```

Regenerator emits (helper elided; `_context.n` is `next`, `.p` is `prev`, `.v` is `sent`, `.a` is
`abrupt`, `.f` is `finish` — abbreviated by `babel/babel#17334`, Ribaudo, 2025-05-26):

```js
function fetchSummary(db) {
  var user, perms, total, i, log, _t;
  return _regenerator().w(function (_context) {
    while (1) switch (_context.p = _context.n) {
      case 0: _context.n = 1; return db.getUser();
      case 1: user = _context.v; _context.n = 2; return db.getPermissions(user);
      case 2: perms = _context.v; total = 0; i = 0;
      case 3: if (!(i < perms.groups.length)) { _context.n = 6; break; }
              _t = total;                                  // <-- the explosion
              _context.n = 4; return db.getGroupSize(perms.groups[i]);
      case 4: total = _t += _context.v;
      case 5: i++; _context.n = 3; break;
      case 6: _context.p = 6; _context.n = 7; return db.getAuditLog(user);
      case 7: log = _context.v;
              return _context.a(2, user + perms.n + total + log);
      case 8: _context.p = 8; total = 0; return _context.f(8);
      case 9: return _context.a(2);
    }
  }, _marked, null, [[6,, 8, 9]]);
}
```

TypeScript emits the same machine with the same case numbering and the same try tuple
(`_b.trys.push([6, , 8, 9])`), differing only in the calling convention — `return [4 /*yield*/, x]`
and `_b.sent()` instead of `return x` and `_context.v`. **Note `_t = total` at case 3.** `total` is
read before the suspension and written after it; the transform cannot prove `total` is unchanged
across the suspension, so it spills. That single line is the whole of finding §0.2 made visible.

**Answering the cross-cutting questions, in order:**

1. **Loop.** Yes, unrestricted, in `for`, `for-in`, `while`, `do-while` and `switch`. A loop is a
   back-jump; a suspension inside it is just another case. This is the capability
   `fast-compiler.md` §3.2 identifies as the one no block-structured rewrite has. *Caveat:*
   `ForOfStatement` is **not** in regenerator's statement switch and reaches
   `default: throw new Error("unknown Statement of type …")`; Babel's plugin ordering guarantees
   `transform-for-of` runs first, and TypeScript expresses the same constraint as
   `--downlevelIteration` / error TS2802.
2. **Branch.** Yes, with no new block, and the bound value is live after the branch because every
   binding is hoisted to the outer function's `var` list, not to a block.
3. **Early return.** Yes, and it composes correctly with `finally` — which is what `ctx.abrupt` /
   `ctx.finish` and the `trys` table exist for. The most valuable property of the design: *cleanup
   semantics live in the runtime's tables, not in emitted code*, so the emitter never duplicates a
   `finally` body per exit path.
4. **Type-system demand.** **Nothing.** Both transforms run on an untyped or type-erased tree and
   trigger on a syntactic marker. No class, no trait, no member lookup, no name in scope.
5. **Position.** Anywhere an expression may appear — argument position, a condition, a scrutinee, an
   object-literal value, an array element. §2.3 is what that costs: about fifteen expression cases
   plus a conservative temp-var rule, in a dedicated backend pass, not the parser or the checker.
6. **Per-bind and per-call cost on JavaScript.** **Deliberately out of scope** — the programme owner
   removed performance from this report mid-research. Not measured, not estimated, not reported; see
   §8.
7. **Optimiser transparency.** The emitted function is ordinary ES5 — a `while`/`switch` over plain
   locals — so a minifier renames and eliminates it like any other function, and the state object's
   layout is ours (relevant to `fast-compiler.md` §9.5). The opacity runs the other way: **the
   suspension boundary is opaque to the emitter's own analyses**, which is why `_t = total` appears.
   Any beni pass reasoning across a suspension must run before the transform or know its shape.
10. **Effects as values.** Preserved cleanly. The machine *returns* the effect and waits; it does not
    perform it. Whoever drives it decides whether to run it now, later, twice or not at all —
    `__awaiter` chooses Promises; a `Task` interpreter would choose otherwise. The transform is
    neutral on retry, cancellation and interpretation.

**Not applicable / no source found.** *Pattern matching on the bound value* and *mixing two effect
types* have no analogue here: JavaScript has neither, and the transform is type-blind, so both
questions belong to the language wrapped around the transform, not to the transform.

---

## 3. History and decisions

**regenerator.** `facebook/regenerator` was created 2013-10-05 (GitHub API, accessed 2026-09-14);
Newman had been at it longer — his own tweet, quoted on his 2014 slides and dated **May 8, 2013**:
*"I've been jokingly referring to this side project as 'my life's work' for so long that I'm terrified
it might actually be finished soon."* The next slide reads, in full: **"It's the trickiest code I've
ever written."** The talk's framing is not about generators at all; it argues for transpilation as a
migration strategy — *"GitHub is strewn with better ways of doing things that never quite caught on"*,
*"How can ECMAScript 6 avoid the Python 3 trap?"*. After walking the audience through the
exception-dispatch loop he says: **"Good news! That's pretty much as hard as transpilation gets."**
The closing caveats slide is worth recording whole:

> Not everything can be transpiled. AST transforms don't always play well together. Niceties like
> source maps become an absolute necessity when debugging generated code. The language specification
> can change out from under you.

The README's only self-assessment is a warning to contributors: *"I must warn you that the code could
really benefit from better implementation comments"* (linking `facebook/regenerator#7`).

**TypeScript.** `src/compiler/transformers/generators.ts` begins with Ron Buckton's commit *"Early
support for generators."*, **2016-02-29**, and accumulated 138 commits through `release-5.9`. It
shipped as the mechanism behind `async`/`await` for ES5 in TypeScript 2.1 and behind
`--downlevelIteration` in 2.3. `tslib.js` predates it — Buckton, 2015-05-14.

**Babel absorbed regenerator in 2025.** `facebook/regenerator` is archived, last pushed 2024-02-29,
3,823 stars, **63 open issues out of 269 filed**. Nicolò Ribaudo's `babel/babel#17205`, *"Inline
regenerator in the relevant packages"* (2025-03-26), moved the transform in-tree; `#17249`, `#17268`
and `#17287` shrank the emitted helper and `#17334` shortened the context property names to the
single letters shown above. The interesting part is what came *after* the move: `#17359` *"fix:
Unexpected infinite loop with `regenerator` for `try`"* (liuxingbaoyu, merged 2025-06-03), `#17426`
*"fix: `regenerator` correctly handles `throw` outside of `try`"* (merged 2025-07-04), `#17556`
*"fix: `transform-regenerator` correctly handles scope"* (merged 2025-11-07), and `#17608` *"Fix
transform of destructuring after `await`"* (open as of access date), whose report is exact:

> When an `async` function uses destructuring assignment after an `await` expression, the
> transformation pipeline fails with the error: `Property name expected type of string but got
> undefined` … The bug was in `hoist.ts`, specifically in the `varDeclToExpr` function. The code
> incorrectly assumed that the `id` property of a `VariableDeclarator` is always an Identifier.

**Twelve years after the first commit, the transform is still producing control-flow bugs, and they
are in the hoisting and the `try` handling — exactly the two hardest parts.**

**The decision that matters most to us: TypeScript is removing it.** Daniel Rosenwasser,
`microsoft/TypeScript#62196`, **2025-08-04**, proposing `--target es5`'s deprecation:

> ECMAScript 5 was a stable and broad target that seemed like the safest option years ago, but the
> need to support ES5 environments has shrunk dramatically. … Additionally, **there is quite a bit of
> complexity in supporting the transformation of generators.** … Users who do rely on ES5 runtimes
> will be able to use older versions of TypeScript for its downlevel compilation capabilities, Babel,
> or another compiler.

The Go port bears this out: `tsc/internal/transformers/estransforms/` contains `async.go`,
`forawait.go`, `using.go`, `classfields.go` and thirteen others — **and no `generators.go`**. The
`__awaiter` split survives; the state machine does not. It is the strongest available statement of
what the transform costs to *own*: the team that wrote the best-documented implementation of it
declined to port it.

---

## 4. Costs — ergonomic and structural

### 4.1 What it does to the user's code: nothing

This is the finding that separates this mechanism from every one in report 15. `use`, `let*`, `with`,
backpassing and `?` all require the user to restructure: a new block at every branch, a fold in place
of every loop, a named function to return from. The state-machine transform requires **no
restructuring whatsoever**. The user writes ordinary statements — loops, branches, `try`/`finally`,
early `return` — and the compiler absorbs the difficulty. The only thing the user must accept is a
marker on the function (`function*`, `async`), which is JavaScript's function colouring and is a
language design question, not a transform question.

### 4.2 What it demands of the compiler pipeline

| Demand | regenerator | TypeScript |
|---|---|---|
| Own pass, after desugaring | `emit.js` 1,308 lines (Babel's fork: `emit.ts` 1,413) | `generators.ts` 3,284 lines, 2,486 non-comment, 127 functions |
| Supporting files | `leap` 179, `visit` 369, `hoist` 161, `meta` 110, `util` 45 | folded into the one file |
| Ordering constraint | must run **after** `for-of`, `let`/`const`, destructuring and class lowering | `--downlevelIteration` gates `for-of`; runs late in the emit pipeline |
| Hoisting | all declarations → one `var` list (`hoist.js`) | `hoistVariableDeclaration` + `transformInitializedVariable` |
| Renaming | catch parameters, and a temp per exploded subexpression | same, plus `renamedCatchVariableDeclarations` |
| `this` / `arguments` | captured into the wrapper's arguments (`visit.js:110-145`) | passed to `__awaiter`/`__generator` explicitly |
| Tests | 50 fixture directories in 6 groups (`integration` 7, `misc` 21, `regression` 12, `scope` 5, `v8` 4, `variable-renaming` 1) | part of the compiler's baseline suite |

**The ordering constraint is the one a new compiler will trip over.** The transform's statement
switch handles fifteen forms; every construct the source language has beyond those must be lowered
first, or the emitter throws. This is a real architectural commitment: the state-machine pass has to
sit near the end of the pipeline, after every other lowering, and every new surface-syntax feature
must either lower to one of the fifteen or extend the switch.

**Inference is untouched.** Neither implementation consults a type. For a Hindley-Milner language
this is the single best property on offer: the transform is entirely a backend concern and cannot
interact with unification, which is precisely the failure mode `fast-compiler.md` §3.2 records for
`?`-on-`Task` (the ordered speculative unification in `Solve.zig` silently choosing `Result`).

### 4.3 Source maps, stack traces, debugging

**8. Diagnostics and locations.** Line-level source maps survive, because the transform *moves*
statements without rewriting them: a statement that did not contain a leap is emitted verbatim
(`emit.js:961`, `if (!meta.containsLeap(expr)) return finish(expr)`), carrying its original range. The
two places the mapping has to be handled by hand are:

- **Hoisted declarations**, §0.3 above. `microsoft/TypeScript#14506` is the canonical failure —
  breakpoints firing before the `await` rather than after it — and `#16376` the fix; regenerator's
  `hoist.js:29-31` records the same hazard. **A beni implementation must map the hoisted `var` to
  nothing and map the assignment to the original binding site.** This is not discoverable by testing
  that output *runs*; it is discoverable only by stepping in a debugger.
- **Generated temporaries.** Every `_t = <subexpr>` produced by `explodeViaTempVar` is a statement
  with no source-level counterpart. Regenerator tracks them in `this.insertedLocs` and
  `getInsertedLocs()` (`emit.js:71-73`) and is careful to clone rather than reuse their location
  nodes.

**Stack traces are structurally degraded, and no amount of source-map care fixes it.** The user's
function body becomes an anonymous inner function passed to a runtime wrapper, so the frame's *name*
is the wrapper's, and the runtime's own frames (`step`, `invoke`, `next`) appear between the throw
site and the caller. Nothing in either project claims otherwise. For an asynchronous driver the loss
is larger and not specific to the transform: the logical caller is not on the stack at all, because
each resumption starts from the scheduler. Newman named the whole area unsolved in 2014.
**Formatter:** not applicable; no formatter ever sees a state machine.

**9. Removed or regretted.** TypeScript is removing the transform (§3), citing "quite a bit of
complexity"; the Go port never had it. Regenerator was archived by Facebook and adopted by Babel
rather than retired, but Babel 8 also removed `regenerator-runtime` as a separate dependency from
`@babel/runtime` and `@babel/node` (`#17635`, `#17639`, both Ribaudo, 2025-12-05), and Babel 8's
`preset-env` no longer includes regenerator by default (`#15838`, 2023-08-03). Nobody has publicly
regretted the *design*; two of the three owners have retreated from *maintaining* it.

### 4.4 What newcomers get wrong

The evidence is unusually clean, because the failure has a single error message. `regeneratorRuntime
is not defined` — the state machine referring to a runtime that the user's bundle does not contain —
returns **171 Stack Overflow questions** (Stack Exchange API, accessed 2026-09-14), led by *"Babel 6
regeneratorRuntime is not defined"* at **829 votes and 778,730 views**, then *"Babel 7 –
ReferenceError: regeneratorRuntime is not defined"* (109 votes, 103,507 views) and *"`regeneratorRuntime`
is not defined when running Jest test"* (100 votes, 77,597 views). `babel/babel#8713` is a user
opening with *"I have `Uncaught ReferenceError: regeneratorRuntime is not defined`, sorry I spent about
15 hours on it and I too tired."*

**The lesson is about packaging, not about the transform.** The emitted machine is correct; the
runtime it needs was a separate npm package with its own inclusion rules, and that split cost the
ecosystem more support load than any other property of the design. Babel 8's answer was to stop
splitting: the helper is now inlined into the output. **A beni implementation should emit its runtime
with its output and never make it a user-visible dependency** — which, for a whole-program compiler
with no user-facing module graph, is free.

---

## 5. What users say

**The finding is that they don't.** Searching for practitioner discussion of the *transform* turns up
almost nothing; what exists is discussion of its *packaging failures* and its *bundle footprint*. That
asymmetry is itself the evidence: a compiler transform that nobody discusses is a compiler transform
that works.

**Scale, for context** (npm registry API, week of 2026-09-05 to 2026-09-11, accessed 2026-09-14):
`tslib` 304,355,128 downloads; `regenerator-runtime` 48,550,969; `@babel/plugin-transform-regenerator`
33,535,229. Tens of millions of installs a week of a mechanism with essentially no design discourse.

**Complaints**, in order of volume:

1. *"regeneratorRuntime is not defined"* — §4.4. The dominant complaint by an order of magnitude, and
   a packaging complaint.
2. **Output size.** Benedikt Meurer of the V8 team, 2017-02-17 (*High-performance ES2015 and beyond*),
   measured an async-generator example at 187 characters (150 bytes gzipped) compiling to 2,987
   characters (971 bytes gzipped) of ES5 — his figure, cited here once for the shape of the cost and
   not pursued further.
3. **Interaction with other transforms.** Newman named it in 2014 (*"AST transforms don't always play
   well together"*); it remains the live constraint, visible as the `for-of` / `downlevelIteration`
   ordering requirement and as `#17608`'s destructuring-after-`await` crash.

**Praise.** None found in the form of practitioners saying so. The praise is implicit and is stated
by the implementers: Newman's *"That's pretty much as hard as transpilation gets"*, and TypeScript
shipping `async`/`await` to ES5 for nine years on this mechanism with `async.go` still describing the
same split.

**Wishes.** The only recurring one is to *not run the transform* when the target supports generators
natively — `babel/babel#2900`, *"Conditionally running regenerator runtime?"*. `preset-env`'s target
matrix answers it now.

**Distinguishing large-codebase maintainers from evaluators** is not possible here in the way the
brief asks: the users of this transform did not choose it, and mostly do not know they are using it.
That is the honest characterisation.

---

## 6. What it would take to do this in beni

**Type system: nothing.** This is the headline. No class, no trait, no row, no HKT, no new constraint
kind, no change to `Solve.zig`. `fast-compiler.md` §3.1's exclusions do not bind here at all, and the
silent-wrong-answer hazard §3.2 documents for `?`-on-`Task` cannot arise, because the transform never
asks the checker anything. **Of every mechanism in this research programme, this is the only one whose
cost is entirely in the backend.**

**Compiler pipeline: one new late pass, plus a pipeline ordering commitment.** Concretely:

1. A `containsLeap` predicate over the lowered IR, memoised per node, with closures opaque
   (`meta.js` is 110 lines and is the whole of it).
2. An emitter holding a listing, a marked-offset set and back-patchable label values; roughly the
   fifteen statement rules of §2.2 and the fifteen expression rules of §2.3.
3. A leap-entry stack with the six or seven entry kinds both implementations converged on.
4. A hoisting step, with the source-map discipline of §4.3 built in from the start rather than fixed
   later.
5. A try-locs table emitted per function, and a runtime that owns `abrupt`, `finish` and
   `dispatchException`.

Two things make this materially cheaper for beni than for either predecessor. First, **beni's IR is
already lowered**: the fifteen-statement constraint is a constraint on *JavaScript's* grammar, and a
compiler that lowers `case`, `let … in` and pipelines to a small core before this pass has a much
smaller switch to write. Second, **beni controls the protocol**. Neither regenerator nor TypeScript
could: both had to reproduce the ES2015 generator object exactly — `next`/`throw`/`return`,
`Symbol.iterator`, the prototype chain, `{ value, done }` per step, the "Generator is already running"
guard. `tslib.js:174-199` is twenty-five dense lines almost entirely spent on that conformance.
A beni `Task` machine has to satisfy a beni runtime and nothing else, so the wrapper shrinks to
something closer to the dozen lines of `__awaiter`.

**What it delivers.** Every hard case in §2.5 and every cross-cutting question 1, 2, 3 and 10:
suspension inside a loop, inside a branch with the value live afterwards, early return through
`finally`, and effects that remain values the runtime interprets. Question 4 (type-system demand) is
answered with "nothing", question 5 (position) with "anywhere", and question 7 (optimiser
transparency) favourably, because the machine is our own emitted code with our own layout.

**What it does not deliver.** It does not make a *sequence of binds read flat in an
expression-oriented language*. `fast-compiler.md` §3.2's closing paragraph is exactly right and this
report reinforces it: Effect-TS reads well partly because TypeScript has statements. The state-machine
transform makes a bind *expressible* anywhere; whether the resulting source reads flat is a grammar
question that must be decided separately. **A compiler that emits state machines for a language whose
only sequencing construct is `let … in` will still have nested branches — it will just no longer need
a fold to bind inside a loop.**

**What the builders would warn us about**, in their own words:

- Newman: *"It's the trickiest code I've ever written."* And: *"Not everything can be transpiled. AST
  transforms don't always play well together. Niceties like source maps become an absolute necessity
  when debugging generated code."*
- Rosenwasser: *"there is quite a bit of complexity in supporting the transformation of generators"* —
  and then did not port it.
- Babel's maintainers, by their commit log: the bugs land in hoisting and in `try`, they land years
  after the code is believed finished, and they are found by users rather than by tests.
- Lourens (`#14506`): the transform can be correct and still make the debugger useless, and you will
  not notice from the test suite.

---

## 7. Ranked summary

1. The transform needs **nothing from the type system** — untyped AST in, untyped AST out, triggered
   by a syntactic marker. (documented: `visit.js`, `generators.ts` both run post-typecheck)
2. **Two independent implementations converged on one architecture** — linear listing plus label
   back-patching, `while(1) switch`, a leap/block stack of five to seven entry kinds, and a static
   try-region table the runtime searches. (documented)
3. **TypeScript's `generators.ts` header comment is an executable specification** of that
   architecture — eleven opcodes and an emission table — and is the best starting point for a beni
   implementation. (documented)
4. **The hard part is expressions, not statements**: side-effect order across a suspension forces a
   conservative spill of every sibling subexpression to a temporary. (documented: `emit.js:913-950`)
5. **`try`/`finally` with early return works and costs the emitter almost nothing**, because the
   cleanup search lives in the runtime's tables rather than in duplicated emitted code. (documented)
6. **Source maps survive; the debugger does not, unless hoisted declarations are deliberately
   unmapped.** Both projects shipped the bug first. (documented: TS#14506 → #16376; `hoist.js:29-31`)
7. **Stack traces lose the user's function name and gain runtime frames**, irreducibly. (inferred from
   the output shape; no primary source claims otherwise)
8. **TypeScript is deleting the transform**, citing its complexity; the Go port has `async.go` and no
   `generators.go`. (documented: Rosenwasser 2025-08-04; directory listing 2026-09-14)
9. **It is still producing control-flow bugs twelve years in**, all in hoisting and `try`.
   (documented: babel#17359, #17426, #17556, #17608, 2025)
10. **The ecosystem's actual pain was packaging, not the transform** — 171 Stack Overflow questions
    about a missing runtime, led by one with 778,730 views. Inline the runtime. (measured, via the
    Stack Exchange and npm APIs, accessed 2026-09-14)

---

## 8. What could not be resolved

- **Runtime cost versus native generators.** Deliberately out of scope as of the mid-research rule
  change; not attempted and not reported. `fast-compiler.md` §3.2's "Nobody has measured this for us,
  and it is measurable" therefore still stands, and `bench` is still the place to settle it.
- **Whether Newman ever wrote down why the leap manager is a stack of entries rather than a
  per-construct continuation.** The 2014 slides show the API in use but not the alternatives
  considered. `facebook/regenerator#7`, the "better implementation comments" issue the README points
  at, is the closest thing to a design-rationale thread and was not resolved. Searched the archived
  repository's issues and the slide deck in full.
- **Any TypeScript design document for `generators.ts` beyond the header comment.** The first commit
  (Buckton, 2016-02-29) is titled "Early support for generators." with no linked proposal; searched
  the TypeScript issue tracker for a design issue and found only usage-level threads (`#12557`,
  `#15602`, `#40897`).
- **Whether the Go port's omission of the generators transform was ever discussed separately from the
  ES5 deprecation.** `microsoft/typescript-go` is archived and its contents merged into
  `microsoft/TypeScript`; `#62196` is the only statement located, and it addresses the target, not the
  port.
- **A primary source on stack-trace quality through the transform.** The degradation is evident from
  the output shape, and Newman names debugging as a problem in general terms, but no designer's
  statement specifically about frame names or async stack continuity through a downlevelled generator
  was found. Searched both trackers and the slide deck.
- **Practitioner testimony from maintainers of large codebases about the transform itself**, as
  opposed to its packaging. §5 reports the absence as the finding rather than substituting
  secondhand summaries, which the brief excludes.
