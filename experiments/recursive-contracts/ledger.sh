#!/usr/bin/env bash
# ledger.sh <outdir> <stage...>: every ownership fixture under each stage; one file per (fixture, token, stage).
B=/home/canassa/.cache/beni-agents/contracts-exp/wt/zig-out/bin/beni
C=/home/canassa/.cache/beni-agents/contracts-exp/wt/tests/corpus/ownership
out=$1; shift; mkdir -p "$out"
list() {
  for f in $C/*.beni; do n=$(basename "$f" .beni)
    if [ -f "$C/$n.platform" ]; then for t in $(cat "$C/$n.platform"); do echo "$f $t"; done; else echo "$f -"; fi; done
  for d in $C/*/; do d=${d%/}; n=$(basename "$d"); [ "$n" = core ] && continue
    if [ -f "$d/_expected.platform" ]; then for t in $(cat "$d/_expected.platform"); do echo "$d $t"; done; else echo "$d -"; fi; done
}
one() {
  p=$1; t=$2; s=$3; out=$4; B=$5
  f=(); case $t in -) ;; *+everywhere) f=(--platform=${t%+everywhere} --ownership-everywhere);; *) f=(--platform=$t);; esac
  [ "$s" != 0 ] && f+=(--ownership-contracts=$s)
  key=$(basename "$p")__${t//\//_}__$s
  start=$(date +%s.%N)
  timeout 120 $B dump --stage=ownership --ownership=v2 --jobs=1 "${f[@]}" "$p" > "$out/$key.out" 2> "$out/$key.err"; rc=$?
  end=$(date +%s.%N)
  echo "$key $rc $(awk "BEGIN{print $end - $start}")" >> "$out/times.txt"
}
export -f one
for s in "$@"; do list | while read p t; do echo "$p $t $s"; done; done | xargs -P4 -L1 bash -c 'one "$0" "$1" "$2" '"$out $B"
