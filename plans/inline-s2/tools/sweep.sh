#!/usr/bin/env bash
# sweep.sh <scenario> <emitter> <flags...> : sizes 1,4,16,64,256 seeds 1-3 -> out/sweep-<sc>.tsv
S=${S2DIR:?set S2DIR to a scratch directory}; T=$(dirname "$0")
sc=$1; em=$2; shift 2
SIZES=${SIZES:-1 4 16 64 256}
for fl in "$@"; do
  for seed in 1 2 3; do for n in $SIZES; do
    tag=${fl:-none}; [ "$fl" = "-" ] && fl="" && tag=none
    out=$S/out/sw-$sc-$(basename $em .js)-$tag-n$n-s$seed
    S2=$fl node $T/gen.mjs $sc $em $n $seed $out >/dev/null 2>$out.err || { echo -e "$(basename $em .js)\t$tag\t$n\t$seed\tFAIL"; continue; }
    r=$(node $T/measure.mjs $out)
    echo -e "$(basename $em .js)\t$tag\t$n\t$seed\t$r"
  done; done
done
