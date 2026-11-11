# Prompt: round 2 of the ownership prototype

*For an agent. The owner asked for it on 2026-11-11.*

---

Report 111's prototype (`--ownership=v3`, `src/own3/`) is fast and precise on real code. Its rules for function
values were found by tests, not derived. The sweeps in `bench/ownership-sweeps/` (README) found 153 programs
that it accepts and that trap; `master`'s v2 refuses each one. This round decides one question: **do function
values converge under one rule, or do they need a new case for each new shape, as they did in v2?**

Treat the codebase as yours.

1. **Write the rule first.** Write one principle for function values (report 110 §6.5: a contract on the
   function-typed location, which every function that flows there must satisfy). Show that it explains each
   of the 175 faults so far: the 22 of report 111 and the 153 of the sweeps. If it cannot, that is the
   finding: say so and stop.
2. **Build the prototype to that rule.** Replace case rules where the principle covers them. Do not patch the
   153 one shape at a time.
3. **Gate:**
   - 0 `TRAP`, `DIFF` and `CRASH` on all four sweep generators, on report 111's two generators, and on the
     sanitiser corpus;
   - at least 299 of the 308 real writes accepted;
   - more than 500 000 lines per second.
   
   Report the precision on the `dead` twins against v2 as well.
4. **Test convergence.** After the gate passes, write a new generator family for function values that no
   earlier test covers: deeper compositions, callbacks in records, lists and `Maybe`, partial application,
   callbacks that return callbacks, mutual recursion through callbacks. Run it once. Report what it finds as
   it is.

**Deliver on this pull request (#2451):** the code, with the gates green, and
`docs/design/research/112-ownership-prototype-function-values.md`. It opens with a verdict of one paragraph:
*converges*, *does not converge*, or *unclear*, based on step 4. It then gives the rule, the measurements with
their commands, and the faults the new family found. Do not merge. `CLAUDE.md`'s rules apply.
