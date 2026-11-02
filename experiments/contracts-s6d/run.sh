#!/usr/bin/env bash
# run.sh <cfg> <path> [extra]: cfg = m | m6 | c2 | c26 | c8 | c86
B=/home/canassa/.cache/beni-agents/contracts-s6d/wt/zig-out/bin/beni
cfg=$1; p=$2; shift 2
case $cfg in
  m) f=() ;; m6) f=(--ownership-s6d=1) ;;
  c2) f=(--ownership-contracts=2) ;; c26) f=(--ownership-contracts=2 --ownership-s6d=1) ;;
  c8) f=(--ownership-contracts=8) ;; c86) f=(--ownership-contracts=8 --ownership-s6d=1) ;;
esac
. /home/canassa/.cache/beni-agents/contracts-s6d/env.sh
exec timeout ${T:-300} $B dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 "${f[@]}" "$@" "$p"
