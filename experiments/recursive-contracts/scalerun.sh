#!/usr/bin/env bash
f=$1; s=$2; B=/home/canassa/.cache/beni-agents/contracts-exp/wt/zig-out/bin/beni
n=$(basename $f .beni)
fl=(); [ $s != 0 ] && fl=(--ownership-contracts=$s)
/run/current-system/sw/bin/time -f "%e %M" -o scale/$n.$s.time timeout 300 $B dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 "${fl[@]}" $f > scale/$n.$s.out 2>/dev/null
echo "rc $?" >> scale/$n.$s.time
