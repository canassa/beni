## 2026-10-29 20:23 CET — Ownership v2: `within` fails closed, a symmetric supply join

**What I did**

- Fixed the three findings of the manager's review of #1189:
  - The discharge refuses a cell that no route reaches. `minted` passes only on a `site` or
    `result` cell.
  - `joinSupply` joins both nodes, merges both κ and takes the folded label, so `handOff` gives
    the same answer in either order.
  - `foldWithin` returns a failing pre-fold κ as it is, and one member keeps the pre-fold κ.
- Added witnesses for each fix and checked each fix with a mutation.
- Linked #1229, the S4 obligations, from §8.

**What I learned**

- A witness for a goal that the test equations do not hold passes for the wrong reason. An
  unknown goal is refuted approximately, which is also what the refusal witnesses expect. My
  first two fail-closed probes were never inserted, and they still "passed". The mutation check
  caught it.
