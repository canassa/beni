# Construction fuel comparison

Issue: [#168](https://github.com/canassa/beni/issues/168).
The reference revision is `f9ade83c5`.
The fixed model removes only the in-place construction's element tick.
The value interpreter, checker, and generator code remain identical.

`FuelOutcomes.lean` defines the complete input stream and serializes both interpreter results.
The original measurement used the native compiler and linker templates in `provenance.json`.
The optional `fueloutcomes` Lake target now builds the unchanged driver directly from this directory.
Its module root is `FuelOutcomes`; its `srcDir` is `evidence/construction-fuel`.
Fresh target paths can change executable bytes. Compare the complete stream hashes in `summary.json`.

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
`provenance.json` identifies the historical native drivers and their compiler and linker templates.
`changes.tsv.gz` retains every changed result, with columns `case`, `result`, `before`, and `after`.
A generated case key gives its version, seed, and zero-based index.
An enumeration key gives its zero-based index in `Enumerate.walk` order.
The result key gives the interpreter and fuel.
A literal `\n` preserves each newline in Lean's printed result.

The archived comparison does not record remaining fuel.
`FuelLeft.lean` adds a separate measurement for [#236](https://github.com/canassa/beni/issues/236).
It checks the accepted programs and fuel bounds above, under the imported model and grammar.
Each evaluation success records its remaining fuel and its complete public trace result.
Evaluation errors and final snapshot errors remain exact, separate results.
The driver reports every unequal fuel result, one-sided success, and trace difference with its case key and initial fuel.
Its exit code is nonzero for those differences or an incomplete enumeration.
Paired failures remain explicit; they do not establish fuel equality.
This source adds no new measured result or stream hash before its native run.

The kernel regression in `Ownership/StatementChecks/ConstructionFuel.lean` proves equal remaining fuel at fuel 6 for one program.
The required `ownership ci` run checks negative controls separately.
Neither finite measurement proves the general soundness statements.

Use the native Lake targets. The interpreted `lake env lean --run` path did not complete the original measurement.
To reproduce the archived hashes, use the exact historical revisions below.
Later changes to imported fixtures or the grammar can change the stream.
Keep every export, output, and log inside this worktree.
The commands create fresh directories; they do not change another worktree.

Run these commands from the repository root with zsh:

```sh
task_root=$(git rev-parse --show-toplevel)
package_dir="$task_root/proofs/ownership"
probe_source="$package_dir/evidence/construction-fuel/FuelOutcomes.lean"
mkdir -p "$task_root/zig-out/scratch"
export XDG_CACHE_HOME="$task_root/zig-out/scratch/fuel-native-cache"
export TMPDIR="$task_root/zig-out/scratch/fuel-native-tmp"
mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"

fuel_checked() {
  free -g >&2
  local available_gb=$(free -g | awk '/^Mem:/ {print $7}')
  if test "$available_gb" -lt 6; then
    printf '%s\n' 'Less than 6 GB available; command did not start.' >&2
    return 75
  fi
  flock /home/jayson/.local/state/beni-dispatch/heavy.lock \
    systemd-run --user --scope --quiet -p MemoryMax=10G -p MemorySwapMax=2G -- "$@"
}

for revision in f9ade83c5 53300e2f0; do
  export_dir="$task_root/zig-out/scratch/construction-fuel-$revision"
  mkdir "$export_dir" || exit 1
  git -C "$task_root" archive "$revision" proofs/ownership | tar -x -C "$export_dir"
  archive_codes=("${pipestatus[@]}")
  if test "${archive_codes[1]}" -ne 0; then exit "${archive_codes[1]}"; fi
  if test "${archive_codes[2]}" -ne 0; then exit "${archive_codes[2]}"; fi
  export_package="$export_dir/proofs/ownership"
  mkdir -p "$export_package/evidence/construction-fuel"
  cp "$probe_source" "$export_package/evidence/construction-fuel/FuelOutcomes.lean"
  cat >> "$export_package/lakefile.toml" <<'TOML'

[[lean_exe]]
name = "fueloutcomes"
root = "FuelOutcomes"
srcDir = "evidence/construction-fuel"
TOML
  cd "$export_package"
  fuel_checked nix develop "$task_root#ownership" --command lake build fueloutcomes \
    > "$export_dir/build.log" 2>&1 || exit $?
  fuel_checked nix develop "$task_root#ownership" --command .lake/build/bin/fueloutcomes \
    > "$export_dir/outcomes.tsv" 2> "$export_dir/run.log" || exit $?
  sha256sum "$export_dir/outcomes.tsv"
done
```

Compare the reference and fixed hashes with `summary.json`.
Keep the historical driver, archive hashes, and compressed changes unchanged.

To measure remaining fuel on the current model, continue in the same shell:

```sh
cd "$package_dir"
git -C "$task_root" rev-parse HEAD > "$task_root/zig-out/scratch/remaining-fuel-revision.txt"
fuel_checked nix develop "$task_root#ownership" --command lake build fuelleft \
  > "$task_root/zig-out/scratch/remaining-fuel-build.log" 2>&1 || exit $?
fuel_checked nix develop "$task_root#ownership" --command .lake/build/bin/fuelleft \
  > "$task_root/zig-out/scratch/remaining-fuel.tsv" \
  2> "$task_root/zig-out/scratch/remaining-fuel.log" || exit $?
```

Record the source revision, grammar, program counts, summary, exit code, and output hash after the run.
Report the successful-state fuel scope separately from paired failures and final snapshot errors.
