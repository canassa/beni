## 2026-11-08 22:14 CET — end the hangs on types that recur with growing arguments

**What I did**

- Reproduced #1763 on master 4e84ba4705. `src/check/Wire.zig` is on master. A worker
  message of `Fork Int` hung `beni build` past 150 s. `Nest Int` stopped at the 512 depth
  cap with a 3.5 kB diagnostic.
- `Wire.zig` `Builder.node` now keeps the named types open on the current path with the size
  of their arguments. When the same type is open with smaller arguments, the plan uses the
  type-variable walk (kind 5) and checks the new arguments for Wire.
- The dev build then ended, but `--release` still hung: `RepKeys.closeThrough` closed the
  wild set through `Nest Int`, `Nest (List Int)`, … without end. A plain Node program with
  `Nest` hung `--release --library` the same way, with no worker. The closure now counts the
  applications of each named type and makes every key wild (`all_wild`) past 1024.
- The test platform's `Worker.js` had no case for kind 5; it has one now, as
  `Browser/WorkerWire.beni` does.
- Fixtures: `browser/dedicated/PolyRecursiveFork`, `PolyRecursiveNest`,
  `emit/release/PolyRecursiveLibrary.beni`, and a platform test that runs the plan and
  `structuredClone` in both modes. All red before, green after.
- Amended `workers.md` §5 and `backend.md` §9 (dated). Asked the owner
  `wire-polyrec-hang-q1`: dynamic walk (built) or refusal.

**What I learned**

- An infinite plan path must meet one named type with larger arguments: the memo holds every
  frame's arguments, and a finite set of types has finitely many arguments of one size.
- Ownership v1 takes 66 s to dump a function with two polymorphically recursive calls; v2 takes
  0.2 s. The corpus runs v1 for its parity check, so a `run/` or `browser/` fixture with such a
  function times out on a loaded machine (#2301). The `Fork` fixture does not traverse the type.
- A `--library` fixture needs a closed application (`pub sample : Nest Int`) to reach the
  wild-set closure; with only `Nest a` it passed on master.
