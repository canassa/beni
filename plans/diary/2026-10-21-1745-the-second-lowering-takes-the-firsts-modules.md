## 2026-10-21 17:45 CEST — The second lowering takes the first's modules

**What I did.** Issue #608, cause 5 of `plans/build-profile-2026-10-21b.md`. A build with a runtime
module lowers twice. The first lowering skips core and the runtime module, because what they need
depends on what the other modules use of the runtime. Until now the second lowering lowered
every module again. Now `Emit.reusableLowerings` keeps a module's first lowering when the walk
from the narrower roots changed no answer that lowering read. Those answers are:

- its own survivor sets;
- the constructors behind its `ext_ctor`s;
- any schema member;
- the shared validators;
- the lowerings of the modules whose view pieces it reads.

Development builds print the kept lowering in the second round. `-Demit-lower-reuse-cross-check`
lowers every kept module again and compares the two, and `test-blackbox` passed with it. I made
the check fail on purpose once, to prove that it runs. `Copy.property` now reads a per-module
index (`Mod.findName`) in place of its linear walk. The index catches up lazily with names
appended since the last lookup. At N = 64, lowerings fell from 151 to 80, lowering time from 21.3
to 11.8 ms, and instructions from 1 303M to 1 205M. Every output and run hash is the same. The
tables are in `backend.md` §15.1 and §9.

**What I learned.**

- The first lowering's results were already complete. It threw them away (`lower_only`) only
  because nothing could tell whether they still held. The funnel's list of questions is what
  answers that. Of those questions, only the survivor sets, `ext_ctor`, schema members and
  resharing can move between the two walks.
- `src/rules_test.zig`'s dense-id lint takes `JsIr.Name` for `markup/Interface.Name`, which is an
  `enum(u32)`, because it matches names lexically. The key is composite, so I put it on the
  allowlist with the reason.
- Splitting `Main` by declaration group would give far less than the profile's −30…−40 ms at
  `--jobs=8`. Ownership's summaries of `main → update → step → pushed → replaced` form one
  chain, 79% of `Main`'s ownership. Lowering `Main` is 89% its `main` declaration, the
  program site. Only check would split well: 13 annotated singleton groups, the largest 26%. My
  estimate is about −6 ms in all.
- dagon ran at load 20–90 while other agents' suites ran. I measured between their bursts and
  interleaved the old and new binaries run by run.
