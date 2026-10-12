#!/usr/bin/env bash
# Build each source-level checker mutant in a scratch copy and run the normal
# oracle campaign (generator only, no fixtures) on it. A mutant is caught when
# the campaign stops on an accepted disagreement. Run inside `nix develop
# .#ownership` from proofs/ownership; node must be on PATH.
#   scripts/run-mutants.sh <scratch-dir> [count] [seeds...] [-- mutants...]
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
here=$(pwd)
mkdir -p "$scratch"
# One snapshot of the sources at the start, so later edits do not leak in.
base="$scratch/base"
rm -rf "$base"; mkdir -p "$base"
cp -r "$here/Ownership" "$here/Main.lean" "$here/Ownership.lean" "$here/lakefile.toml" \
  "$here/lean-toolchain" "$here/lake-manifest.json" "$base/"
[ -d "$here/.lake" ] && cp -r "$here/.lake" "$base/"
for m in "${names[@]}"; do
  d="$scratch/m-$m"
  rm -rf "$d"; cp -r "$base" "$d"
  if ! node scripts/mutate.mjs "$m" "$d"; then echo "$m: PATCH FAILED"; continue; fi
  # The executable's `falsify` mode imports Soundness.lean, whose proofs
  # follow the checker's text (a mutant that deletes a demand side condition
  # breaks them). The campaign needs neither: drop the mode from the copy.
  sed -i -e '/^import Ownership.Falsify$/d' \
    -e '/^  if mode == "falsify" then$/,/^    return (if clean then 0 else 1)$/d' "$d/Main.lean"
  if ! (cd "$d" && lake build ownership > build.log 2>&1); then echo "$m: BUILD FAILED"; continue; fi
  line="$m:"
  caught=0
  # The seeds run side by side; each records its exit status.
  for s in "${seeds[@]}"; do
    (cd "$d" && ./.lake/build/bin/ownership oracle "$count" "$s" > "oracle-$s.log" 2>&1; echo $? > "status-$s") &
  done
  wait
  for s in "${seeds[@]}"; do
    status=$(cat "$d/status-$s")
    index=$(grep -o "index=[0-9]*" "$d/oracle-$s.log" | head -1 | sed 's/index=//')
    family=""; [ -n "$index" ] && family=$(grep -o "family=[a-z-]*" "$d/oracle-$s.log" | head -1 | sed "s/family=//")
    [ $status -ne 0 ] && [ -n "$index" ] && caught=$((caught + 1))
    # A crash (abort, kill, segfault) is never a miss: flag it.
    crash=""; [ $status -ge 128 ] && crash=" CRASH"
    line="$line seed=$s exit=$status${crash} first-index=${index:-none}${family:+ family=$family}"
  done
  echo "$line caught-seeds=$caught/${#seeds[@]}"
  rm -rf "$d"
done
rm -rf "$base"
