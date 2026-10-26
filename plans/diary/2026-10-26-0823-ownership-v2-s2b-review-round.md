## 2026-10-26 08:23 CET — Ownership v2 S2b: the review round

**What I did**

- Answered the four reviews of #1057–#1060 and rebased the stack onto master
  after #1037 merged.
- Words: lowering now refuses rows that contradict themselves (a `taken`
  result from an `unused` parameter, a `taken` callback with no container
  before it, `concatenated` over other than two parameters, `builderdone`
  with a length that is more than read).
- Appendix C: C.4 now goes through `Cond.instantiate` and checks the
  feedback supply round by round. The C.2 class I built by hand is gone.
- Spread: a literal that is one spread records no fact; `Bir.verify`
  checks the spread and v2 word ranges.
- Pins: the gate reads the BIR dump of core and of every platform on
  disk. `dump --stage=bir` takes a directory, takes `--platform` there and
  prints v1's column. The gate pins every worded declaration, the helpers
  of the List/Ref/Deferred rows, and every reader of a taken result through
  wrappers.
- Block: canonical order by memoised structural hashes; a trial read into
  tables of its own; checked casts; fresh place numbers; field ranks and
  shared declarations through `Names`. A cell's interning key now takes
  its place.

**What I learned**

- **A correction to the 06:01 entry.** "mapHelp's κ matches each round" is
  true, but the class I printed afterwards was built by hand, so it tested
  only the printer. What the tests check is the κ at `res[*]` (C.2) and
  the res, κ and feedback supply (C.4), with the call and the fold done by
  the test as C.2 states them. Uses, calls and supplies wait for a walker.
- Spelling sort keys recursively is exponential on a union chain.
  A union's cells and a node's derived κ are the reader's to compute
  again, and writing them made the bytes quadratic as well.
- `Place.Table.of` memoises by type variable in a dense column. A block's
  places need numbers above every variable the table has seen; a large
  base allocates the whole column.
- `Cond.lower`'s cost for distinct-base arrivals is still quadratic
  (#1054); only the number of groups is linear.
