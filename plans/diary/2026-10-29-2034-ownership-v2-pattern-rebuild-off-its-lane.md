## 2026-10-29 20:34 CET — Ownership v2: a list pattern's rebuild off its lane (#1224)

**What I did**

- `Shape.without` enters `Shape.dagWalk`. It is the rebuild a list pattern makes of one position
  of a literal's positions DAG. Before, the whole DAG was charged to the pattern's
  `transfer_settlement` lane, and a 42-item literal of fresh lists reached the lane's ceiling.
- The branch is stacked on #1198 (the source continuation). Measured, each declaration's account:
  - fresh lists at 40 / 100 items: 8 345 / 22 792 records of continuation, 0 growth;
  - one shared list at 40 / 100 / 1 000 positions: 782 / 1 502 / 11 478.
- `PatternWideFresh` and `PatternWideShared` pin the twins. The fresh family is red without the
  fix.
- The fresh 1 000-item twin is pending fixture CK-312. It stops on `Demands.resolve`'s loop over
  the push's alternatives, which runs on the demand's own lane. That is #1225's.
- Added Astra's §4.1 and §8 text, with an *As built* note.

**What I learned**

- On master, a 1 000-item literal alone exceeds the default allowance. On #1198 it costs no growth.
  So measure an accounting change on the continuation branch, or the numbers mislead.
- A pending fixture's `RED` line takes the signature the walker reports, here
  `OwnershipV2Limit`, not `exit=0 ownership-differs`. Its first line must be `-- CK-NN: …`
  with the colon directly after the number.
