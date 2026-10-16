# Diagnostic reach after PR #248

This finite campaign checks the coverage gaps in [#253](https://github.com/canassa/beni/issues/253).
It does not prove any general soundness obligation.

Grammar 3 adds a final record that observes the latest binding beside prelude list 1.
A two-binding program can now create a view, write that view, and retain its source as a live reader.
The declaration table and right-hand-side choices stay unchanged.
The new final observations change enumeration indices.

Bound 1 contains 399 programs. Bound 2 contains 157,824 programs.
The campaign also runs 953 fixture cases and 120,000 generated candidates.
Generator versions 5 and 6 each use 20,000 candidates at seeds `20261011`, `17`, and `271828`.

All 98,019 accepted programs complete with zero q1 hits and zero actual observer-storage changes.
Each accepted run also retains exact ordinary/diagnostic state and trace equality.

## Rejected reach

Rejected programs use fuel 5,000. Higher fuel previously reached the 10 GiB memory cap.
Their events measure reach. They do not count as accepted-program failures.
The nonvacuity condition requires all four direction/context categories from enumeration itself.

| Rejected q4 events | Main: view written | Main: source written | Call: view written | Call: source written | Other linked direction |
| --- | ---: | ---: | ---: | ---: | ---: |
| Enumeration, bound 2 | 28 | 170 | 54 | 114 | 0 |
| Generator v5 | 0 | 0 | 0 | 0 | 0 |
| Generator v6 | 7,890 | 4,873 | 785 | 647 | 413 |
| Fixtures | 18 | 18 | 0 | 0 | 0 |

These are event counts. The campaign reports 5,474 rejected programs with at least one q4 hit.
It classifies direct stored view/source edges by direction. Other linked relationships stay separate.
The diagnostic site tags identify main and call contexts.
For example, `enum:117507` reaches a main-context view write with a live source.

Of 180,758 rejected programs, 160,494 complete and 20,264 return an execution error.
No completed rejected run reports an incomplete diagnostic scan.
An execution error discards its partial diagnostic state. These partial runs contribute no reach events.
The reach counts therefore describe completed runs, not all executed prefixes.

## Call checks and controls

The new raw call check compares each pre-call observer's reachable storage against the actual post-call heap.
It uses no cache summary row. It reports 13,146 changed-observer call records in rejected programs and zero in accepted programs.
No raw observer scan reports an error.
This check compares call boundaries. It does not detect an intermediate change that the call restores before return.

The existing summary-row check remains separate. Its strict result stays false, with exit 1.
It retains the same two raw W/C candidates from the prior capture. Neither matches the chosen public-premise witnesses.
A summary W/C row is not itself an actual changed-observer event.
The raw call-boundary check finds no changed observer for either accepted candidate.

The six matched read-only linked calls all come from planted diagnostic fixtures.
No enumerated or generated accepted call in this campaign passes linked storage through two distinct input slots.
Read-only linked inputs remain legal under Cesar's q4 decision.

All 50 diagnostic controls pass: 48 complete, two expected incomplete, 34 hits, and zero failures.
All three call controls pass. `ownership ci` now runs these controls automatically.

## Records and limits

The measured source commit is `830ebb2ee57837da101d99a94dd200ea118db663`.
The campaign used its diagnostic sources and the earlier Main source hash in `inputs.json`.
The final Main edit changes only the CI controls' output path to scratch.
The campaign used enumeration bound 2 and rejected fuel 5,000.
Accepted fuel was 100,000 for fixtures and generated cases, and 20,000 for enumeration.

The capture ran this exact command from `proofs/ownership`:

```sh
.lake/build/bin/ownership diagnostics 20000 20261011 --enumerate-bound=2 --out=/home/jayson/src/beni.worktrees/ownership-proofs/zig-out/scratch/reach-campaign-1-evidence.log
```

`inputs.json` records the executable hash and source hashes.
`result.json` records the eight parsed case blocks and the campaign totals.
The archive-integrity fields describe the original local capture.
These records support the counts above. They do not replace the removed outputs.
The capture omits external toolchain and dependency hashes. It does not establish complete build reproducibility.

The repository excludes logs and run output. The following table identifies each removed output.

| Output | Bytes | SHA-256 |
| --- | ---: | --- |
| `reach.log.gz` | 9,305,481 | `b31a34df237422d1fae14c8f20d8042bceef4e59e63e2f2605c0741030419b4b` |
| `summary.log` | 16,764 | `66305845a1006bb4ef2b4a3fdf663708f8823f6a42d9acd93f23e3157ba84c1d` |
| `Main-before-ci-output.txt` | 11,920 | `752a4fab9e382fe37f0eb478a9d2490825d35075fbbbebf8125aa383912cc63a` |

The uncompressed native stream contains 225,508,384 bytes.
Its SHA-256 is `01e69eca58c4d7c3bf06bced7243fa3b225006f478b6d11d96c2b783f0f8fed2`.
The removed verifier depended on the removed files, so this folder excludes it too.
Local scratch copies retain the outputs. Git does not distribute those copies.

From `proofs/ownership`, reproduce the campaign under the required lock and memory caps:

```sh
lake exe ownership diagnostics 20000 20261011 --enumerate-bound=2 --out=../../zig-out/scratch/diagnostic-reach.log
```

The command returns 1 because the retained strict summary-row result remains false.
Check `enumerated-reach-complete=true`, every accepted block, and both raw summary-row candidates separately.
