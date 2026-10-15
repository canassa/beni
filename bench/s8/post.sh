#!/usr/bin/env bash
set -euo pipefail
cd ~/src/github.com/canassa/beni
export PATH="$HOME/.local/bin:$PATH"
export BENI="$PWD/zig-out/beni-s8-frozen"
export S8_CHROME="$(command -v chromium)"
export CHROME="$PWD/bench/s8/chrome.sh"
R="$PWD/bench/s8/results"
node bench/writesets/stats.mjs --json --extra-apps=examples/sternhalma/src,examples/bike-wars/src > "$R/stats.json" 2> "$R/stats.log"
node bench/size.mjs --beni="$BENI" --pages-only > "$R/floor.jsonl" 2> "$R/floor.log"
(cd bench/ui && node sizes.mjs) > "$R/table-sizes.txt" 2> "$R/table-sizes.log"
(cd bench/ui && node scaling-sizes.mjs --out=../s8/results/sweep-sizes.json) > "$R/sweep-sizes.txt" 2> "$R/sweep-sizes.log"
node bench/s8/pool-jfb.mjs > "$R/pool.log" 2>&1
node bench/jfb/run.mjs --report-only --skip-install --frameworks=vanillajs,solid,beni-tea,beni-direct --chrome="$CHROME" --out=bench/s8/results/jfb-pooled > "$R/jfb-pooled.log" 2>&1
node bench/s8/summarise.mjs > "$R/summary.log" 2>&1
node bench/s8/audit.mjs > "$R/audit.log" 2>&1
node bench/s8/post.mjs > "$R/post.log" 2>&1
node bench/s8/anatomy.mjs > "$R/helper-anatomy.log" 2>&1
node bench/s8/inspect-endpoints.mjs > "$R/endpoint-inspection.log" 2>&1
node bench/s8/validate.mjs
git diff --exit-code 6c327a9f17050941bc170f9e888160795ca471f5 -- src core platforms examples > "$R/production-source-diff.txt"
node bench/s8/provenance.mjs
printf 'POST COMPLETE\n'
