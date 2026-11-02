#!/usr/bin/env bash
# final.sh: every checkpoint again with the final binary, into final/.
set -u
cd /home/canassa/.cache/beni-agents/slot-exp
. ./env.sh
T=/nix/store/23s9fdv7c4fai0bygx433a87arrqkykf-time-1.10/bin/time
B=wt/zig-out/bin/beni
rm -rf final; mkdir -p final/fix final/fam final/scale final/oracle
# Checkpoints 1-3: the probes, master and slots.
for f in TestSet Controls RemoveMinProbe Reversed; do
  $T -f "%e s %M KB" -o final/$f.time ./run.sh probes/$f.beni 1 > final/$f.out 2>&1
  ./run.sh probes/$f.beni 0 > final/$f.v2 2>&1
  for m in 2 3; do ./run.sh probes/$f.beni $m > final/$f.m$m 2>&1; done
done
for d in ImportRT ImportRev Imported; do ./run.sh probes/$d 1 > final/$d.out 2>&1; done
(cd wt && $T -f "%e s %M KB" -o ../final/core.time timeout 600 ./zig-out/bin/beni dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 --ownership-slots=9 core > ../final/core.out 2>../final/core.err)
(cd wt && $T -f "%e s %M KB" -o ../final/core.v2.time timeout 600 ./zig-out/bin/beni dump --stage=ownership --ownership=v2 --ownership-everywhere --jobs=1 core > ../final/core.v2 2>/dev/null)
# Checkpoint 4: the sample and the family table.
for f in ChoiceArmsParams WriteOneLevel FoldCertificate CombinePositions KappaAtView LinkedJoinCertificate LevelFresh; do
  ./run.sh wt/tests/corpus/ownership/$f.beni 1 > final/fix/$f.slots 2>&1; ./run.sh wt/tests/corpus/ownership/$f.beni 0 > final/fix/$f.v2 2>&1
done
for f in FoldCertificateImported FoldCertificateImportedPair FoldCertificateWrapper FoldedKnotCall ApartAcrossModules JoinedCallContexts RepeatedPathCall CycleLinkRooting CrossDepthKids JoinFoldChoice FoldRelabelCall LinkedFoldCoverage ViewFoldRoute FoldedBCall RefinementFoldMultiplicity; do
  p=wt/tests/corpus/ownership/$f; [ -e $p.beni ] && p=$p.beni
  ./run.sh $p 1 > final/fam/$f.slots 2>&1; ./run.sh $p 0 > final/fam/$f.v2 2>&1
done
# Checkpoint 5: the families.
for f in Copies1 Copies2 Copies4 Copies8 Fields1 Fields2 Fields4 Fields8 Rotate2 Rotate4 Rotate8 Rotate15; do
  $T -f "%e s %M KB" -o final/scale/$f.time ./run.sh scale/$f.beni 1 > final/scale/$f.out 2>&1
done
# The runtime oracle.
cd oracle
for v in copy:4: plain:1: san:1:--sanitize-lists; do n=${v%%:*}; r=${v#*:}; m=${r%%:*}; x=${r#*:}; rm -rf out-$n
  timeout 600 ../$B build --platform=node --ownership=v2 --ownership-everywhere --ownership-slots=$m $x --out=out-$n Writers.beni > ../final/oracle/build-$n.log 2>&1; echo "rc $?" >> ../final/oracle/build-$n.log
  (cd out-$n && timeout 60 node _main.mjs > ../../final/oracle/run-$n.txt 2>&1; echo "rc $?" >> ../../final/oracle/run-$n.txt); done
for v in m1san:1:--sanitize-lists m3:3: m3san:3:--sanitize-lists m4:4:; do n=${v%%:*}; r=${v#*:}; m=${r%%:*}; x=${r#*:}; rm -rf u-$n
  timeout 600 ../$B build --platform=node --ownership=v2 --ownership-everywhere --ownership-slots=$m $x --out=u-$n UnsafeDup.beni > ../final/oracle/ubuild-$n.log 2>&1; echo "rc $?" >> ../final/oracle/ubuild-$n.log
  (cd u-$n && timeout 60 node _main.mjs > ../../final/oracle/urun-$n.txt 2>&1; echo "rc $?" >> ../../final/oracle/urun-$n.txt); done
grep -o '_sanitize\$list("[^"]*' out-san/Writers.mjs > ../final/oracle/wrapped-writes.txt
cd ..
echo done
