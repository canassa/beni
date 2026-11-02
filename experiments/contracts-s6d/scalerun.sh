#!/usr/bin/env bash
# scalerun.sh <file> <cfg>
cd /home/canassa/.cache/beni-agents/contracts-s6d
f=$1; c=$2; n=$(basename $f .beni)
/run/current-system/sw/bin/time -f "%e %U %M" -o scale/$n.$c.time env T=300 ./run.sh $c $f > scale/$n.$c.out 2>/dev/null
echo "rc $?" >> scale/$n.$c.time
