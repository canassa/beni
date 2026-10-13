#!/usr/bin/env bash
# Build each source-level checker mutant in a scratch copy and run, on it,
# the normal oracle campaign (generator only, no fixtures) on each seed, and
# the bounded-exhaustive enumeration (`ownership enumerate`, bound
# $ENUMERATE_BOUND, default 3; 0 skips it). Run inside `nix develop
# .#ownership` from proofs/ownership; node must be on PATH.
#   scripts/run-mutants.sh <scratch-dir> [count] [seeds...] [-- mutants...]
#
# Each seed is reported as one of
#   caught                 an accepted disagreement the corrected checker rejects
#   CRASH-after-mismatch   a disagreement was found, then the run crashed
#                          (status >= 128, e.g. while shrinking); not a catch
#   CRASH                  the run crashed before finding anything
#   miss                   the campaign finished without a disagreement
# and the scratch copy's logs and unshrunk programs of every run that is not
# a plain miss are kept in regressions/mutant-evidence/<mutant>-<seed>/.
set -u
# Shrinking a deep program can exhaust the default stack.
ulimit -s unlimited
scratch=$1; shift
count=${1:-20000}; shift || true
seeds=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do seeds+=("$1"); shift; done
[ ${#seeds[@]} -eq 0 ] && seeds=(20261011 17 271828)
[ "${1:-}" = "--" ] && shift
names=("$@")
[ ${#names[@]} -eq 0 ] && read -r -a names <<< "$(node scripts/mutate.mjs --list)"
bound=${ENUMERATE_BOUND:-3}
cores=${MUTANT_CORES:-0-7}
here=$(pwd)
mkdir -p "$scratch"
# One snapshot of the sources at the start, so later edits do not leak in.
base="$scratch/base"
rm -rf "$base"; mkdir -p "$base"
cp -r "$here/Ownership" "$here/Main.lean" "$here/Ownership.lean" "$here/lakefile.toml" \
  "$here/lean-toolchain" "$here/lake-manifest.json" "$base/"
[ -d "$here/.lake" ] && cp -r "$here/.lake" "$base/"
keep() {  # keep <dir> <mutant> <tag> <log files...>
  local d=$1 m=$2 tag=$3; shift 3
  local out="$here/regressions/mutant-evidence/$m-$tag"
  mkdir -p "$out"
  cp "$@" "$out/" 2>/dev/null
  cp "$d"/regressions/*unshrunk* "$out/" 2>/dev/null
  true
}
# The programs of the enumeration the unmutated build accepts (none of
# which may disagree): a mutant's enumeration runs only the others, and
# reports how many verdicts it changed.
if [ "$bound" -gt 0 ]; then
  if ! (cd "$base" && taskset -c "$cores" ./.lake/build/bin/ownership enumerate "$bound" \
      --accepted-out="$scratch/accepted.txt" > "$scratch/enumerate-base.log" 2>&1); then
    echo "unmutated enumeration FAILED:"; cat "$scratch/enumerate-base.log"; exit 1
  fi
  echo "unmutated: $(tail -1 "$scratch/enumerate-base.log")"
fi
for m in "${names[@]}"; do
  d="$scratch/m-$m"
  rm -rf "$d"; cp -r "$base" "$d"
  if ! node scripts/mutate.mjs "$m" "$d"; then echo "$m: PATCH FAILED"; continue; fi
  # The executable's `falsify` mode imports Soundness.lean, whose proofs
  # follow the checker's text (a mutant that deletes a demand side condition
  # breaks them). The campaign needs neither: drop the mode from the copy.
  sed -i -e '/^import Ownership.Falsify$/d' \
    -e '/^  if mode == "falsify" then$/,/^    return (if clean then 0 else 1)$/d' "$d/Main.lean"
  if ! (cd "$d" && taskset -c "$cores" lake build ownership > build.log 2>&1); then echo "$m: BUILD FAILED"; continue; fi
  line="$m:"
  caught=0
  # The seeds run side by side; each records its exit status.
  for s in "${seeds[@]}"; do
    (cd "$d" && taskset -c "$cores" ./.lake/build/bin/ownership oracle "$count" "$s" > "oracle-$s.log" 2>&1; echo $? > "status-$s") &
  done
  wait
  for s in "${seeds[@]}"; do
    status=$(cat "$d/status-$s")
    index=$(grep -o "mismatch index=[0-9]*" "$d/oracle-$s.log" | head -1 | sed 's/.*index=//')
    family=""; [ -n "$index" ] && family=$(grep -o "family=[a-z-]*" "$d/oracle-$s.log" | head -1 | sed "s/family=//")
    if [ "$status" -ge 128 ] && [ -n "$index" ]; then kind="CRASH-after-mismatch"
    elif [ "$status" -ge 128 ]; then kind="CRASH"
    elif [ "$status" -ne 0 ] && [ -n "$index" ]; then kind="caught"; caught=$((caught + 1))
    elif [ "$status" -ne 0 ]; then kind="FAILED"
    else kind="miss"; fi
    [ "$kind" != "miss" ] && keep "$d" "$m" "$s" "$d/oracle-$s.log"
    line="$line seed=$s $kind exit=$status first-index=${index:-none}${family:+ family=$family}"
  done
  line="$line caught-seeds=$caught/${#seeds[@]}"
  if [ "$bound" -gt 0 ]; then
    (cd "$d" && taskset -c "$cores" ./.lake/build/bin/ownership enumerate "$bound" --skip-accepted="$scratch/accepted.txt" > "enumerate.log" 2>&1; echo $? > "status-enumerate")
    status=$(cat "$d/status-enumerate")
    if [ "$status" -ge 128 ]; then kind="CRASH"
    elif grep -q "caught=true" "$d/enumerate.log"; then kind="caught"
    else kind="miss"; fi
    [ "$kind" != "miss" ] && keep "$d" "$m" "enumerate" "$d/enumerate.log"
    changed=$(grep -o "changed-verdicts=[0-9]*" "$d/enumerate.log" | sed "s/.*=//")
    line="$line enumerate=$kind changed-verdicts=${changed:-?}"
  fi
  echo "$line"
  rm -rf "$d"
done
rm -rf "$base" "$scratch/accepted.txt"
