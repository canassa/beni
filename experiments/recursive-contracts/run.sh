#!/usr/bin/env bash
# run.sh <path> <stage|0> [extra flags]: v2 dump, verdict + limit + contract lines.
B=/home/canassa/.cache/beni-agents/contracts-exp/wt/zig-out/bin/beni
p=$1; s=$2; shift 2
f=(); [ "$s" != 0 ] && f=(--ownership-contracts=$s)
timeout ${T:-300} $B dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 "${f[@]}" "$@" "$p" 2>/dev/null
