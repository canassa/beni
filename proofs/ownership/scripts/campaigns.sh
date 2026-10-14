#!/usr/bin/env bash
# Run inside nix develop .#ownership from proofs/ownership after lake build.
# Publish logs only after every process succeeds; retain failed run artifacts.
set -euo pipefail
work=$(mktemp -d "$PWD/regressions/campaign-run.XXXXXX")
pids=()
finish() {
  status=$?
  if [ "$status" -ne 0 ]; then
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    echo "campaign failed; committed logs untouched; evidence: $work" >&2
  fi
}
trap finish EXIT
bin=(taskset -c 0-7 "${OWNERSHIP_BIN:-./.lake/build/bin/ownership}")
"${bin[@]}" fixtures > "$work/fixtures-v5.log" 2>&1
for s in 20261011 17 271828; do
  "${bin[@]}" oracle 20000 "$s" --cross-check > "$work/campaign-v5-$s.log" 2>&1 & pids+=("$!")
  "${bin[@]}" oracle 20000 "$s" --reinfer > "$work/campaign-v5-reinfer-$s.log" 2>&1 & pids+=("$!")
  "${bin[@]}" controls 20000 "$s" > "$work/controls-v5-$s.log" 2>&1 & pids+=("$!")
done
"${bin[@]}" controls 20000 20261011 --reinfer > "$work/controls-v5-reinfer-20261011.log" 2>&1 & pids+=("$!")
"${bin[@]}" oracle 20000 20261011 --generator-version=4 > "$work/campaign-v4-baseline-20261011.log" 2>&1 & pids+=("$!")
"${bin[@]}" oracle 20000 20261011 --generator-version=3 > "$work/campaign-v3-baseline-20261011.log" 2>&1 & pids+=("$!")
for pid in "${pids[@]}"; do wait "$pid"; done
pids=()
"${bin[@]}" summaries > "$work/summaries-fixtures.log" 2>&1
"${bin[@]}" enumerate 3 > "$work/enumerate-3.log" 2>&1
"${bin[@]}" enumerate 2 > "$work/enumerate-2.log" 2>&1
cp "$work"/*.log regressions/
echo "done; logs and evidence: $work"
