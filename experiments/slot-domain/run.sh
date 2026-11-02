#!/usr/bin/env bash
# run.sh <path> <mode> [extra flags]: the slot evaluator's dump (mode 0: master v2).
B=/home/canassa/.cache/beni-agents/slot-exp/wt/zig-out/bin/beni
p=$1; s=$2; shift 2
f=(); [ "$s" != 0 ] && f=(--ownership-slots=$s)
timeout ${T:-300} $B dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 "${f[@]}" "$@" "$p"
