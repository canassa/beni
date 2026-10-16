# Enumerator and diagnostic evidence

The state-stream and CI comparisons measure the construction-helper extraction.
The fresh diagnostic capture also includes the separate audit memory repair.
The initial expanded build reached the audit memory cap.
[PR #245](https://github.com/canassa/beni/pull/245) supplies the repair through sequential module processes with every check intact.
Its committed-tree audit passed. The expanded build now passes with 7,142 kernel replays across 74 jobs.
The expanded enumerator source also requires its complete independent audit before publication. The PR records its result.
The fresh CI run passed, including its bounded compiler bridge.
These finite results do not establish a general proof.

Grammar 2 at bound 2 visits 105,150 programs and accepts 57,780.
The diagnostic scope adds 953 fixture cases and six generator blocks.
Each generator block contains 20,000 candidates: versions 5 and 6 use seeds `20261011`, `17`, and `271828`.

| Diagnostic measurement | Count |
| --- | ---: |
| Program cases / accepted and completed | 226,103 / 71,762 |
| Programs with links | 6,740 |
| Attempted writes / changed writes / linked writes | 91,214 / 80,521 / 837 |
| Reader checks / q1 hits | 295,843 / 0 |
| Calls / matched calls / unmatched calls | 51,088 / 43,432 / 7,656 |
| Cache candidates / matched / unmatched | 64,451 / 54,115 / 10,336 |
| Matched W/C demand calls / targets | 21,560 / 26,660 |
| Matched linked demand calls / targets | 84 / 84 |
| Matched demand calls with permanent registrations / targets | 369 / 431 |

The q1 check follows Cesar's q4 decision.
It covers every attempted write against distinct linked storage with a live protected reader, in main contexts and calls.
Six matched read-only linked calls remain legal.
All accepted runs complete without execution errors, snapshot errors, divergent states or traces, or dangling input or observer references.
Every logged call has a cache candidate. No call or premise check reports incomplete.

The strict q2 result remains false: `diagnostics clean=false`.
The raw W/C scan reports two direct-observer hits and zero linked-observer hits.
The matched subset reports zero direct or linked hits.

- `v6:20261011:11101`, call 3, cache entry 2: the candidate's empty callback environment cannot describe the actual array capture.
  `capAppend` changes unobserved address 2. Observed address 1 stays unchanged.
- `v6:17:1707`, call 5, cache entry 1: the candidate expects a writing, non-escaping callback.
  The actual `publish` callback writes nothing and escapes its argument. Only fresh builder address 10 changes; observed address 5 stays `[0]`.

These stale cache-summary matches do not establish checker defects. The raw scan retains both hits.
The premise filter checks one canonical naming and one chosen closure-class interpretation.
A failed chosen witness does not exclude every theorem instance. Unmatched calls and candidates remain explicit coverage limits.

The controls pass: 50 cases, 48 complete, two expected incomplete, 34 expected hits, and zero failures.
All three synthetic call controls pass, including the dangling-observer control.

The `Aliasing.lean` campaign metric lacks `.construct`, `.view`, `.prepend`, `.events`, and `.owned` cases.
[#243](https://github.com/canassa/beni/issues/243) tracks this limit. Do not quote that metric as complete v6 write coverage.
The diagnostic counts above come from runtime write events.

The before/after comparison covers 678,261 ordered records across 226,087 cases, without the 16 new accepted diagnostic fixtures.
It preserves verdicts, values, remaining fuel, heaps, links, reads, kept roots, external observations, write counters, and exact evaluation errors.
Call logging stays off in these state streams.
The diagnostic comparisons separately check logged calls, final snapshots, and complete traces.
Both streams match byte for byte: SHA-256 `81d7da1081e919812a8595860a28df8bb2328de99ef94914745dae76d06bec7f`.

Both historical before/after CI runs pass. All four frozen JSONL exports match byte for byte.
All 348 summary rows match as multisets; all 34 generator metric rows match.
Full logs and reports differ: 37 normalized log differences cover build totals, lead order, samples, and the executable hash.
One bounded sample changes membership. Its complete pattern count stays 10.
The corrected comparison reports `complete=true`, `equal=false`; it classifies every difference without a metric change.

The remaining-fuel run covers 226,088 programs and 238,166 paired runs, including the closed witness.
All 129,141 paired successes retain equal fuel and public traces. Both interpreters fail in the other 109,025 runs.
No run succeeds in only one interpreter.
Accepted v6 programs and the witness use fuel 0–32 and 100,000; other families use their recorded campaign fuel.
This finite result does not prove `Invariant.fuel`.

## Fresh diagnostic provenance

The fresh capture ran on 2026-10-16 from 13:27:09 to 13:28:22 UTC.
It returned exit 1 with `strict_clean=false`. Source and executable hashes stayed equal before and after execution.
Its numeric block counts match the earlier diagnostic measurement exactly.
The manifests identify the measured enumerator edits by per-file hashes on base HEAD `9230e047e`.
HEAD alone does not identify those edits.

| Captured artifact | SHA-256 |
| --- | --- |
| Native `ownership` executable | `6c04e08c1280afe6e72b4bf36e3c1f34e6752d56565255c8359084a10b2eb401` |
| Diagnostic summary log | `0035d0af49e0006440b39b8eba2d874eeee6da710b890c041e1b5367581a852c` |
| Diagnostic evidence log | `c3856170add17ba7ae2790a246a6abf4bc247d42433eb80c93a7122059998779` |

This directory keeps compact records:

- [Before](diagnostics-before.json), [after](diagnostics-after.json), and [result](diagnostics-result.json) preserve the exact capture manifests and receipt.
- [Diagnostic counts](diagnostics-summary.json) preserve every block, controls, totals, and the strict-false result.
- [Raw-hit classification](raw-hit-classification.json) preserves both hit keys, observed arrays, changed addresses, and coverage limits.
- [State comparison](state-comparison.json) preserves the equal stream hashes and exact case inventory.
- [CI comparison](ci-comparison.json) and [difference classification](ci-differences.json) preserve metric equality and full-report inequality.
- [Remaining fuel](remaining-fuel-summary.json) preserves the historical run's complete counters and its finite scope.
- [Source records](evidence-sources.json) identify each copied or derived record through exact source hashes.

[SHA256SUMS](SHA256SUMS) records the exact hash of each JSON file.
The source logs and large streams remain under `zig-out/scratch/`; the JSON records retain their paths and hashes.
The earlier `enum-measure-source-hashes.json` predates the fixture expectation and `FuelLeft.lean` syntax corrections.
It remains initial-draft evidence. The fresh manifests establish the current diagnostic provenance.

## Reproduce the native state streams

Use the enumerator source revision for this evidence. Later fixture or grammar changes can change the stream.
The optional `refactoroutcomes` target builds [RefactorOutcomes.lean](RefactorOutcomes.lean) as a native executable.
Do not use `lean --run` for this measurement.
Fresh paths can change executable bytes. Compare the complete ordered output and its SHA-256.

The commands make two source copies inside this worktree and exclude existing Lake artifacts.
Both copies retain grammar 2. Only the before copy replaces `Semantics.lean` with revision `f80c7c6be`.
This baseline includes the construction-fuel fix and precedes the construction-helper extraction.
Run these commands from the repository root with zsh:

```sh
task_root=$(git rev-parse --show-toplevel)
package_dir="$task_root/proofs/ownership"
mkdir -p "$task_root/zig-out/scratch"
repro_root=$(mktemp -d "$task_root/zig-out/scratch/refactor-native.XXXXXX")
mkdir "$repro_root/after"
tar -C "$package_dir" --exclude='./.lake' -cf - . | tar -C "$repro_root/after" -xf -
copy_codes=("${pipestatus[@]}")
if test "${copy_codes[1]}" -ne 0; then exit "${copy_codes[1]}"; fi
if test "${copy_codes[2]}" -ne 0; then exit "${copy_codes[2]}"; fi
cp -a --reflink=auto -- "$repro_root/after" "$repro_root/before"
git -C "$task_root" show f80c7c6be:proofs/ownership/Ownership/Semantics.lean \
  > "$repro_root/before/Ownership/Semantics.lean" || exit $?
git -C "$task_root" rev-parse HEAD > "$repro_root/source-revision.txt"
export XDG_CACHE_HOME="$repro_root/cache"
export TMPDIR="$repro_root/tmp"
mkdir -p "$XDG_CACHE_HOME" "$TMPDIR"

refactor_checked() {
  flock /home/jayson/.local/state/beni-dispatch/heavy.lock \
    systemd-run --user --scope --quiet -p MemoryMax=10G -p MemorySwapMax=2G -- \
    bash -eu -c '
      free -g >&2
      available_gb=$(free -g | awk "/^Mem:/ {print \$7}")
      if test "$available_gb" -lt 6; then
        printf "%s\n" "Less than 6 GB available; command did not start." >&2
        exit 75
      fi
      exec "$@"
    ' bash nix develop "$task_root#ownership" --command "$@"
}

for variant in before after; do
  export_package="$repro_root/$variant"
  cd "$export_package"
  refactor_checked lake build refactoroutcomes \
    > "$export_package/build.log" 2>&1 || exit $?
  refactor_checked .lake/build/bin/refactoroutcomes \
    > "$export_package/outcomes.tsv" 2> "$export_package/run.log" || exit $?
done
refactor_checked cmp "$repro_root/before/outcomes.tsv" "$repro_root/after/outcomes.tsv" || exit $?
refactor_checked sha256sum "$repro_root/before/outcomes.tsv" "$repro_root/after/outcomes.tsv"
```

Each stream must contain 678,261 records across 226,087 cases for the measured source.
Compare both hashes with `81d7da1081e919812a8595860a28df8bb2328de99ef94914745dae76d06bec7f`.
Keep the build logs, run logs, source copies, and stream files.
