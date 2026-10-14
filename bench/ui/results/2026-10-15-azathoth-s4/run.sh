#!/usr/bin/env bash
set -euo pipefail
cd ~/src/github.com/canassa/beni
export PATH="$HOME/.local/bin:$PATH"
export CHROME=chromium
R=results/2026-10-15-azathoth-s4
cd bench/ui
mkdir -p "$R"
node build.mjs > "$R/build.log" 2>&1
node scaling.mjs --full --build-only --rebuild --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 >> "$R/build.log" 2>&1
{
  date -Is
  git rev-parse HEAD
  zorg version
  node --version
  chromium --version
  lscpu
  uptime
  cat /sys/devices/system/cpu/isolated
  ps -eo pid,comm,pcpu --sort=-pcpu | head -12
} > "$R/machine.txt"
node verify.mjs --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 > "$R/verify.log" 2>&1
node p3-verify.mjs --cases=table >> "$R/verify.log" 2>&1
taskset -c 0-1,6-7 node bench.mjs --unthrottled --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 --n=20 --taskset=2-5,8-11 --out="$R/table.json" > "$R/table.log" 2>&1
taskset -c 0-1,6-7 node scaling.mjs --full --no-build --untraced --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2 --taskset=2-5,8-11 --out="$R/sweeps.json" > "$R/sweeps.log" 2>&1
node sizes.mjs > "$R/table-sizes.txt"
node scaling-sizes.mjs --out="$R/sweep-sizes.json" > "$R/sweep-sizes.txt"
uptime >> "$R/machine.txt"
