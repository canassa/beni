## 2026-09-16 10:26 CEST — review of report 18, and the static-dispatch spike plan

**What I did**

- **Checked `research/18-static-dispatch-revisited.md` against its sources.** All seven Zulip
  quotes I pulled match the live messages verbatim, with the right authors and dates; the three
  Roc langref quotes and the repo citations hold. Defects found and reported, not yet fixed:
  "§708" is a stale line number used four times for what is §3.2 "Modules: no header"; the `->`
  operator is not in `test/echo/all_syntax_test.roc` as claimed (it is in other vendored tests);
  the comparator-site counts (19/20) do not reproduce (grep gives 9/12); the research session left
  no diary entry; `fast-compiler.md` line 79 still cites only reports 09 and 10; the §3.1 table
  still states the three withdrawn reasons unmarked. Two argument weaknesses: §2.3's claim that Roc
  does not pay the interface-churn cost is unsourced, and the churn comparison ignores that today's
  equivalent edit adds a parameter, which also changes the interface; §2.2 reads Roc's
  implementation defect (since designed away by per-use instantiation, which is how Haskell class
  methods always worked) as an inherent loss of principality.
- **Planned the static-dispatch spike** in `plans/static-dispatch-spike.md`, from four read-only
  maps of the checker, module system, backend and harness. Decisions taken with the user: dot-call
  syntax resolved on the receiver's type; the *module rule* for the method set (Roc's original
  design, flagged as something we may change); all four scope items (`where` constraints, `==` as
  `eq` with derivation, `compare` as a well-known method, return-type dispatch); N hidden function
  arguments for polymorphic sites. Eight slices on `spike/static-dispatch`, nine measurements with
  baselines captured on `master` before the first checker change.

**What I learned**

- **The mechanism is beni's `equatable` obligation generalised.** Roc's constraints live on the
  flex/rigid var, merge on flex-flex unification and become a *deferred check* when a flex meets a
  concrete type (`references/roc/src/check/unify.zig:859-1044`). beni already has the var payload
  (`TypeStore.Flags`), the per-rank obligation list, the drain loop that tolerates re-registration,
  and the "fold into the flex var for the caller to carry" path (`Solve.zig:1253`). The declaring
  module of every nominal type is already recorded (`Types.Entry.module`). What is genuinely new is
  the interface quantifier carrying a constraint range, the dispatch side table for the backend,
  and the implicit graph edges parallel checking needs.
- **Why Roc left the module rule.** It was "a method is a function defined in the same module as
  the type of its first argument" for ten months; the 2025-10 block form was adopted so that two
  types in one file, mutually recursive ones especially, can each have a `to_str`. The other three
  stated reasons are cosmetic or already covered here (`equatable` on the type is the derivation
  opt-in). For beni the immediate consequence is that `String` and `Char` are declared in `Basics`
  and must move to their own modules for `s.split` to resolve.
- **The grammar already has the `where` clause's disambiguation.** A comma ends a record field's
  type when the next tokens are `lower_ident ':'`; a constraint's type ends when the next three are
  `lower_ident dot_lower ':'`. No new precedence, no backtracking.
- **Nothing measures emitted JavaScript.** No runtime timing, no compressed size, no interface
  hashing, no CI. Node 24's built-in `zlib` brotli covers size; a `run/`-style runner covers time;
  `dump --stage=raw` byte-diffs are the honest interface-churn instrument until M4 hashes them.
