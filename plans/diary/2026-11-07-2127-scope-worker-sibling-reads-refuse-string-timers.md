## 2026-11-07 21:27 CET — Scope worker sibling reads, refuse string timers

**What I did.** Closed two of the routes #2211 left open in the worker realm
check. `Minify.globalReads` now resolves each read of a kept sibling through
a light lexical scope pass (`Scopes`) over the existing token `Structure`:
parameters (destructuring, defaults, bare arrow parameters), `var` hoisted
to its function, `let`/`const`/`class`/function declarations in their
block, `for` heads, `catch`, named function and class expressions. It no
longer reads check 3's scope-free binding set, which stays as it was. A
`setTimeout`/`setInterval`, bare or on `globalThis`/`self`, is refused as
dynamic code unless called at once with a first argument that is provably a
function. Spec in `workers.md` §4, *Sibling scopes and timers*.

**What I learned.** `cut` accepts only `import`, `export { }`, declarations
ending in `;` and function declarations at the top of a file, so the module
scope the pass sees is always well formed; the uncertain cases are nested.
The pass errs toward refusal (binds nothing where it cannot tell), and a
temporary sweep of every hand-written file in `core/` and the platforms
showed no read the scope-free reading did not already report, and their one
timer passes an arrow. Editing a test platform changes the build
fingerprint in every emit golden built on it, so those goldens move by
their fingerprint alone. Items 1b (`constructor`) and 3 (realm
declarations) of #2211 stay open.
