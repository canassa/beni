#!/usr/bin/env bash
# Re-run the recorded campaigns into regressions/*.log. Run inside
# `nix develop .#ownership` from proofs/ownership after `lake build`.
# Generator v5 is the default; v4 and v3 are re-run once as baselines.
set -u
# Every job shares 8 cores (other work needs the rest).
bin="taskset -c 0-7 ./.lake/build/bin/ownership"
$bin fixtures > regressions/fixtures-v5.log 2>&1
for s in 20261011 17 271828; do
  $bin oracle 20000 $s --cross-check > regressions/campaign-v5-$s.log 2>&1 &
  $bin oracle 20000 $s --reinfer > regressions/campaign-v5-reinfer-$s.log 2>&1 &
  $bin controls 20000 $s > regressions/controls-v5-$s.log 2>&1 &
done
$bin controls 20000 20261011 --reinfer > regressions/controls-v5-reinfer-20261011.log 2>&1 &
$bin oracle 20000 20261011 --generator-version=4 > regressions/campaign-v4-baseline-20261011.log 2>&1 &
$bin oracle 20000 20261011 --generator-version=3 > regressions/campaign-v3-baseline-20261011.log 2>&1 &
wait
$bin summaries > regressions/summaries-fixtures.log 2>&1
# The bounded enumeration one level deeper than ci's, on 8 cores.
$bin enumerate 3 > regressions/enumerate-3.log 2>&1
$bin enumerate 2 > regressions/enumerate-2.log 2>&1
echo done
