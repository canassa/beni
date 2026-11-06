## 2026-11-05 15:49 CET — Rework the checked-builds spec after its review (#1999)

**What I did**
- Read the independent review of #1999 and checked its WRONG findings against its evidence on dagon before changing text: the schema host-value result, `degrees 1e308`, the virtual clock past `M`, the Durable Object `ReferenceError`, the file input `InvalidStateError`, and the workerd counter-evidence. All held.
- Rewrote `language.md` §13, `backend.md` §16 and `boundary.md` §4.3 without renumbering, adding `language.md` §13.9 (core's own arithmetic) and §13.10 (the owner's decisions), and the review's order of work in `backend.md` §16.8. Fixed earlier amendments, `CLAUDE.md`, and reports 110 and 111. Report 111 gained §7 (the proofs) and §8 (what the review changed).
- Opened #2019–#2022, commented on #1988 (the owner's decisions) and on #1992–#1998. Merged master into the branch; no rebase, as the owner wants the history kept.

**What I learned**
- My own lowering advice was wrong in the plainest way: I put a `NaN` test in the arm where a comparison answers `false`, and `NaN !== 1` is `true`. A rule stated about results must be checked against every operator in the row, `≠` above all.
- "Release output does not change" and "core must repair these in every build" were both in my draft, and they contradict each other. A promise of byte identity needs a named baseline when the same document asks for repairs.
- "Two bodies, as `$s` does" sounded like a design and was not: two independent `number` variables are four instantiations, and a `--library` export has callers that no reachability graph shows.
- A weak predicate is not a smaller check: it is a wrong one. `typeof v === "number"` says nothing about `Int32`.
- Host claims need the host's name and version. workerd accepted three things I had predicted it would refuse.
