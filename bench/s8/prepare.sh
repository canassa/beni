#!/usr/bin/env bash
set -euo pipefail
cd ~/src/github.com/canassa/beni
export PATH="$HOME/.local/bin:$PATH"
export BENI="$PWD/zig-out/beni-s8-frozen"
R="$PWD/bench/s8/results"
export S8_CHROME="$(command -v chromium)"
export CHROME="$PWD/bench/s8/chrome.sh"
{
 date -Is
 git rev-parse HEAD
 sha256sum "$BENI" flake.lock
 zorg version
 "$BENI" version
 node --version
 "$S8_CHROME" --version
 lscpu
 uptime
 cat /sys/devices/system/cpu/isolated
 cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
 cat /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
 ps -eo pid,comm,pcpu --sort=-pcpu | head -15
 git submodule status
} > "$R/machine.txt"
node bench/jfb/run.mjs --frameworks=vanillajs,solid,beni-tea,beni-direct --skip-run --chrome="$CHROME" > "$R/jfb-build.log" 2>&1
(cd bench/ui && node build.mjs --beni="$BENI" && node scaling.mjs --beni="$BENI" --full --build-only --rebuild --subjects=beni-release,beni-direct-release,p3,vanillajs,solid1,solid2) > "$R/ui-build.log" 2>&1
node bench/todomvc/direct-size.mjs --beni="$BENI" > "$R/todo-sizes.json"
(cd bench/todomvc/apps/vanilla-es6 && npm ci --no-audit --no-fund) > "$R/vanilla-build.log" 2>&1
node bench/todomvc/vanilla-build.mjs >> "$R/vanilla-build.log" 2>&1
printf 'PREPARED\n'
