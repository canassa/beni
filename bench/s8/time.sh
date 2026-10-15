#!/usr/bin/env bash
set -euo pipefail
cd ~/src/github.com/canassa/beni
export PATH="$HOME/.local/bin:$PATH"
export BENI="$PWD/zig-out/beni-s8-frozen"
export S8_CHROME="$(command -v chromium)"
export CHROME="$PWD/bench/s8/chrome.sh"
R="$PWD/bench/s8/results"
orders=(vanillajs,solid,beni-tea,beni-direct solid,beni-tea,beni-direct,vanillajs beni-tea,beni-direct,vanillajs,solid beni-direct,vanillajs,solid,beni-tea)
rounds=(0 1 2 3)
if [[ "${1:-}" == "--after-first-jfb" ]]; then
 rounds=(1 2 3)
 node bench/s8/artifacts.mjs --check
else
 node bench/s8/artifacts.mjs
fi
for i in "${rounds[@]}"; do
 label=jfb
 if [[ "$i" != 0 ]]; then label="jfb-$i"; fi
 taskset -c 0-1,6-7 node bench/jfb/run.mjs --skip-install --skip-build --ordered-frameworks --rotate-operations --no-retry --count=5 --frameworks="${orders[$i]}" --chrome="$CHROME" --out="bench/s8/results/$label" > "$R/$label.log" 2>&1
done
(cd bench/ui && taskset -c 0-1,6-7 node bench.mjs --no-retry --unthrottled --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 --n=20 --out=../s8/results/table.json) > "$R/table.log" 2>&1
(cd bench/ui && taskset -c 0-1,6-7 node scaling.mjs --beni="$BENI" --no-retry --full --no-build --untraced --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 --out=../s8/results/sweeps.json) > "$R/sweeps.log" 2>&1
taskset -c 0-1,6-7 node bench/todomvc/direct-time.mjs --samples=20 --mode=untraced --out=../s8/results/todo-timing.json > "$R/todo-timing.log" 2>&1
taskset -c 0-1,6-7 node bench/conduit/time.mjs --samples=20 --chrome="$CHROME" > "$R/conduit-timing.json" 2> "$R/conduit-timing.log"
taskset -c 0-1,6-7 node bench/s8/apps.mjs > "$R/apps-timing.log" 2>&1
node bench/s8/artifacts.mjs --check
printf 'TIMINGS COMPLETE\n'
