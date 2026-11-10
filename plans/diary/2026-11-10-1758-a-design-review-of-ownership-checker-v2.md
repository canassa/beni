## 2026-11-10 17:58 CET — a design review of ownership checker v2 (#2445)

**What I did.** Worker `ownership-v2-design-review`. The owner asked for a review of the design of
ownership checker v2: is it correct, is it fast enough, is the path right. I wrote research report 110
(`docs/design/research/110-ownership-v2-design-review.md`) and changed no file under `src/`. Eight reader
agents digested the design history, the soundness holes, the cost issues, the precision issues, the code
(data model and algorithm), the records stack and the earlier research. I read the core sections of
`ownership-v2.md` myself and measured the checker on a ReleaseFast compiler of `96e93db4af`.
`bench/ownership-v2-review.mjs` is new: for each real-code root it times the type check, v1's pass and
v2's pass from the self-profile, and it reads v2's accounts and each checker's verdicts from the dump.
On the 32 real roots the type check runs at 573 000 lines per second, v1 at 141 000 and v2 at 113 000.
v2 puts 92 % of its records into declarations with no write. Five declarations of `bench/corpus`
`Codec.Decode` stop at the size limit on `master`, with no write in them. v2 refuses 32 of its 340
demands on real code, and v1 refuses none of its 308. The report's verdict: the carrier of 2026-11-02 is
right, and two parts built on it do not converge (the names of objects in recursive types, and function
values). It proposes three changes and an experiment that decides them before any commitment.

**What I learned.**

- A v2 dump prints an `account` line for each declaration. `continuation N of M` has M = 1 024 records
  for each instruction. A declaration at a `limit` prints no account: raise `@ownership_summary_size` on
  the module to see what it needs.
- `perf record -e cycles:u` fails on this machine. `perf record -e instructions:u -c 100000` works.
- The whole-corpus diff (`bench/ownership-everywhere.mjs --diff=v1,v2`) gives a dump no time limit. The
  root `tests/corpus/check/good/AliasDiamondChain` does not end under v2 (#2139), so the script waits on
  it. I stopped that one process by its PID after 24 minutes, and the diff then printed its lists.
- `bench/corpus` is not in the gates' v2 parity net. The limits in `Codec.Decode` have no line in
  `ownership-v2-known.txt`, and no gate reports them.
- In a `check` run the pass's time against the rest of the run is the number that requirement R-7.1
  bounds at 10 %. On Conduit it is +118 % for v1 and +145 % for v2.
- The v2 contracts of real code are simple. Of 1 872 contracts of `core/`, the TEA platform and
  `bench/corpus`, 45 write a parameter, none writes at a level slot, and each requirement asks
  uniqueness of exactly the written slots.
