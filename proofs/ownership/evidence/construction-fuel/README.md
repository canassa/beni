# Construction fuel comparison

Issue: [#168](https://github.com/canassa/beni/issues/168).
The reference revision is `f9ade83c5`.
The fixed model removes only the in-place construction's element tick.
The value interpreter, checker, and generator code remain identical.

`FuelOutcomes.lean` defines the complete input stream and serializes both interpreter results.
The measurement compiled this driver with Lake's compiler and linker commands for `ownership`.
It replaced only the driver source, driver object, and executable output paths.
The two driver objects are identical. The static executables retain their separate interpreter implementations.

The stream contains:

- The retained closed witness, fixed fixtures, sync fixtures, and targeted programs.
- All 55,966 programs in the bound-2 grammar.
- Generator v5 and v6, with 20,000 candidates per seed: `20261011`, `17`, and `271828`.
- Accepted programs at campaign fuel: 100,000, or 20,000 for enumeration.
- Rejected generator candidates at fuel 5,000, as in the precision campaign.
- Accepted v6 programs and the closed witness at every fuel from 0 through 32.

Each stream has 813,802 records across 176,904 program cases.
Checker verdicts, value results, and both results at campaign fuel remain unchanged.
At small fuel bounds, 958 in-place results change from fuel exhaustion to success across 475 programs.
Every changed result now matches its value result.

| Stream | Changed results |
|---|---:|
| Closed witness, fuel 5 | 1 |
| v6, seed 20261011 | 302 |
| v6, seed 17 | 335 |
| v6, seed 271828 | 320 |
A record contains a checker verdict or a complete interpreter result.
Results retain final values, closure captures, reads, external reads, and errors.
The comparison checks identical ordered keys, unique keys, and equal record counts.
It requires unchanged checker verdicts and unchanged value results.

`summary.json` contains the counts and SHA-256 hashes of both complete streams.
`provenance.json` identifies the native drivers and their compiler and linker templates.
`changes.tsv.gz` retains every changed result, with columns `case`, `result`, `before`, and `after`.
A generated case key gives its version, seed, and zero-based index.
An enumeration key gives its zero-based index in `Enumerate.walk` order.
The result key gives the interpreter and fuel.
A literal `\n` preserves each newline in Lean's printed result.

The comparison does not record remaining fuel.
The kernel regression in `Ownership/StatementChecks/ConstructionFuel.lean` proves that fact at fuel 6.
The required `ownership ci` run checks negative controls separately.
This finite comparison does not prove the general soundness statements.

To reproduce the stream, build each revision and run `lake env lean --run` with the same probe source.
The interpreter runs slower than the native probe.
Keep output inside the worktree. Use the shared lock and the required memory cap for builds and probes.
Start only with at least 6 GB available.

```sh
flock /home/jayson/.local/state/beni-dispatch/heavy.lock \
  systemd-run --user --scope --quiet -p MemoryMax=10G -p MemorySwapMax=2G -- \
  nix develop .#ownership --command lake env lean --run evidence/construction-fuel/FuelOutcomes.lean \
  > ../../zig-out/scratch/construction-fuel-outcomes.tsv
```

Run that command from `proofs/ownership` after the memory check.
For the reference revision, supply this probe from a directory inside the same worktree.
Do not create or change another worktree.
