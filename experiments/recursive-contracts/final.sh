#!/usr/bin/env bash
set -u
cd /home/canassa/.cache/beni-agents/contracts-exp
. ./env.sh
B=wt/zig-out/bin/beni
rm -rf ledger final; mkdir -p final
./ledger.sh ledger 0 1 2 5 8 >/dev/null 2>&1
for s in 1 2 5 8; do node diff.mjs ledger $s > ledger/diff$s.txt; done
for s in 0 2 5 8; do (cd wt && /run/current-system/sw/bin/time -f "%e %M" -o ../final/core$s.time timeout 900 ./zig-out/bin/beni dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=4 $( [ $s != 0 ] && echo --ownership-contracts=$s ) core > ../final/core$s.out 2>../final/core$s.err); done
for s in 0 1 2 5 8; do for f in TestSet TestSetBig Controls Reversed RemoveMinProbe RemoveMinBig; do /run/current-system/sw/bin/time -f "%e %M" -o final/$f.$s.time env T=900 ./run.sh probes/$f.beni $s > final/$f.$s.out 2>final/$f.$s.err; done; T=900 ./run.sh probes/Imported $s > final/Imported.$s.out 2>&1; done
for s in 3 4; do T=900 ./run.sh probes/TestSetBig.beni $s > final/TestSetBig.$s.out 2>&1; T=900 ./run.sh runp/Dup.beni $s --platform=node > final/Dup.$s.out 2>&1; done
T=900 ./run.sh runp/Dup.beni 2 --platform=node > final/Dup.2.out 2>&1
rm -rf scale/*.out scale/*.time
{ for f in scale/Copies?Big.beni scale/Fields?Big.beni; do for s in 2 8; do echo "$f $s"; done; done; for f in scale/Copies?.beni scale/Fields?.beni; do for s in 0 2 8; do echo "$f $s"; done; done; } | xargs -P4 -L1 ./scalerun.sh
node scalesum.mjs > final/scale.txt 2>&1
cd runp; for v in s2:--ownership-contracts=2: s2san:--ownership-contracts=2:--sanitize-lists s8san:--ownership-contracts=8:--sanitize-lists; do n=${v%%:*}; r=${v#*:}; a=${r%%:*}; b=${r#*:}; rm -rf u-$n; timeout 900 ../$B build --platform=node --ownership=v2 --ownership-everywhere $a $b --out=u-$n Useful.beni > ../final/ubuild-$n.log 2>&1; echo "rc $?" >> ../final/ubuild-$n.log; [ -f u-$n/_main.mjs ] && (cd u-$n && timeout 60 node _main.mjs > ../../final/urun-$n.txt 2>&1); done
for v in s4:--ownership-contracts=4: s4san:--ownership-contracts=4:--sanitize-lists s2:--ownership-contracts=2:; do n=${v%%:*}; r=${v#*:}; a=${r%%:*}; b=${r#*:}; rm -rf out-$n; timeout 900 ../$B build --platform=node --ownership=v2 --ownership-everywhere $a $b --out=out-$n Dup.beni > ../final/dbuild-$n.log 2>&1; echo "rc $?" >> ../final/dbuild-$n.log; [ -f out-$n/_main.mjs ] && (cd out-$n && timeout 60 node _main.mjs > ../../final/drun-$n.txt 2>&1); done
echo done
