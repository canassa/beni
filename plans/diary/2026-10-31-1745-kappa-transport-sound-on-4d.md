## 2026-10-31 17:45 CET — κ transport, sound and stacked on 4d (#1459)

**What I did**

- Removed `propagate`'s shape-only skip. The re-review showed that a certificate merged in from one member makes a side read stronger than its member read it. The reviewer's counterexample is now a `Cond.zig` test.
- Rebased onto 4d (#1473, covered rounds).
- In a recursive group's read-off:
  - implied join entries are dropped, and others are moved onto sides that `map` met (`Cond.withoutImpliedJoins`, read-off's baseline);
  - views follow their own origins only (`Shape.originHead`'s `templates`).
- Results:
  - `rose` costs 40 027 records in 4 walks, against 4d's 10 085 in 2;
  - `mergeSort` costs 41 058 in 3, against 36 853;
  - K is unchanged;
  - over 2 045 roots, no verdict changed against 4d.

**What I learned**

- On 4d, template origins in group read-offs made `rose` diverge. It hit the limit even at an allowance of 2 000 000. The port join keeps each round's entries, so following a view's template origins across a round only repeats history.
- Blocking views of group calls outright diverged too: it dropped entries the next rounds then weakened. Following views' own origins converges.
- `mergeSort` needs the read-off filter: without it, 135 537 records in 4 walks.
