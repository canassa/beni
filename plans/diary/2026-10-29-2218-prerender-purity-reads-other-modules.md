## 2026-10-29 22:18 CET — Prerender purity reads other modules

**What I did.** #1170. The `prerender_impure` walk in `src/js/Lower.zig` now reads code in every
app and platform module, not only the program's module. It reads each module's checker table,
which `Emit` now passes to the lowering as `Lower.Input.dispatches`. Because of this,
`init = Counter.init` and a helper of another module that only logs now build. A read of another
module's constant is answered by the constant's body. No new checker fact was necessary. The walk
reads the `impure` answer at each call site and the `total` bit. The amendment is in
`prerender.md` §3.1. Case 4 of the issue, a dispatch target, is #1247.

**What I learned.** The walk had four soundness holes on `master`. Each one accepted a page that
held the build machine's clock:

- a field that names a function bound point-free (`init = stamp`, `stamp = Clock.now`);
- a call of a function bound point-free whose body only logs (`stamp = Debug.log "s" Clock.now`);
- a read of another module's point-free function whose body reads the clock when the module loads;
- a constant read behind a call that the checker answers pure, in a lambda or in a schema's
  conversion. The adversarial reviewer found this one, and it was in the program's module too.

The rule that fixes the first two: only a definition with parameters, or whose whole body is a
lambda, has a body that a call runs. The last needed a second walk that follows every reference
and every dispatch term, because the checker does not count a constant read as an effect. Each
hole has a `build/bad/prerender/` fixture.
