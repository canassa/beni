#!/usr/bin/env bash
# Source-mutant campaigns over the identical generated stream and the
# seed-independent bounded grammar. Run inside nix develop .#ownership.
# scripts/run-mutants.sh <scratch-dir> [count] [seeds...] [-- mutants...]
# Every descendant shares at most eight Linux CPUs. Logs survive for every
# verdict, including misses, build failures, and crashes after a mismatch.
set -euo pipefail
ulimit -s unlimited
scratch=$1; shift
count=${1:-20000}; shift || true
seeds=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do seeds+=("$1"); shift; done
[ ${#seeds[@]} -gt 0 ] || seeds=(20261011 17 271828)
[ "${1:-}" != "--" ] || shift
names=("$@")
[ ${#names[@]} -gt 0 ] || read -r -a names <<< "$(node scripts/mutate.mjs --list)"
bound=${ENUMERATE_BOUND:-2}
cores=${MUTANT_CORES:-0-7}
node --input-type=module - "$cores" <<'JS'
const cpus = new Set();
for (const range of process.argv[2].split(',')) {
  if (!/^\d+(-\d+)?$/.test(range)) throw Error('invalid CPU set');
  const [a, b = a] = range.split('-').map(Number);
  if (b < a || b - a > 7) throw Error('CPU range exceeds eight');
  for (let i = a; i <= b; i++) cpus.add(i);
}
if (!cpus.size || cpus.size > 8) throw Error('use at most eight CPUs');
JS
command -v taskset > /dev/null || { echo 'Linux taskset is required for CPU pinning'; exit 1; }
here=$(pwd)
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd)
base="$scratch/base"
rm -rf "$base"; mkdir -p "$base"
cp -r Ownership Main.lean Ownership.lean lakefile.toml lean-toolchain lake-manifest.json "$base/"
[ ! -d .lake ] || cp -r .lake "$base/"
evidence="$here/regressions/mutant-evidence"
mkdir -p "$evidence"
# The unedited binary supplies the verdicts; the edited binary cannot be its
# own corrected checker. Each oracle stream must also have passed normally.
for s in "${seeds[@]}"; do
  (cd "$base" && taskset -c "$cores" ./.lake/build/bin/ownership accepted "$count" "$s" > "$scratch/accepted-$s.txt") &
done
wait
if [ "$bound" -gt 0 ]; then
  (cd "$base" && taskset -c "$cores" ./.lake/build/bin/ownership enumerate "$bound" \
    --accepted-out="$scratch/enumerated-accepted.txt" > "$scratch/enumerate-base.log" 2>&1)
  cp "$scratch/enumerate-base.log" "$evidence/"
  echo "unmutated: $(tail -1 "$scratch/enumerate-base.log")"
fi
bad=0
for m in "${names[@]}"; do
  d="$scratch/m-$m"
  rm -rf "$d"; cp -r "$base" "$d"
  mkdir -p "$evidence/$m"
  if ! node scripts/mutate.mjs "$m" "$d"; then echo "$m: PATCH FAILED"; bad=1; continue; fi
  # Mutants may invalidate proofs; only the executable oracle is needed.
  sed -i -e '/^import Ownership.Falsify$/d' \
    -e '/^  if mode == "falsify" then$/,/^    return (if clean then 0 else 1)$/d' "$d/Main.lean"
  if ! (cd "$d" && taskset -c "$cores" lake build ownership > build.log 2>&1); then
    cp "$d/build.log" "$evidence/$m/"; echo "$m: BUILD FAILED"; bad=1; continue
  fi
  for s in "${seeds[@]}"; do
    (set +e; cd "$d"; taskset -c "$cores" ./.lake/build/bin/ownership source-sweep "$count" "$s" \
      --baseline-accepted="$scratch/accepted-$s.txt" > "oracle-$s.log" 2>&1; echo $? > "status-$s") &
  done
  wait
  line="$m:"
  for s in "${seeds[@]}"; do
    status=$(cat "$d/status-$s")
    index=$(sed -n 's/.*mismatch index=\([0-9]*\).*/\1/p' "$d/oracle-$s.log" | head -1)
    if [ "$status" -ge 128 ] && [ -n "$index" ]; then kind=CRASH-after-mismatch; bad=1
    elif [ "$status" -ge 128 ]; then kind=CRASH; bad=1
    elif [ "$status" -eq 1 ] && [ -n "$index" ]; then kind=caught
    elif [ "$status" -ne 0 ]; then kind=FAILED; bad=1
    else kind=miss; fi
    out="$evidence/$m/$s"; mkdir -p "$out"
    cp "$d/oracle-$s.log" "$d/status-$s" "$out/"
    for f in "$d"/regressions/source-"$s"-*-unshrunk.txt; do [ ! -f "$f" ] || cp "$f" "$out/"; done
    counts=$(tail -1 "$d/oracle-$s.log")
    line="$line seed=$s $kind exit=$status first-index=${index:-none} [$counts]"
  done
  if [ "$bound" -gt 0 ]; then
    set +e
    (cd "$d" && taskset -c "$cores" ./.lake/build/bin/ownership enumerate "$bound" \
      --skip-accepted="$scratch/enumerated-accepted.txt" > enumerate.log 2>&1)
    status=$?
    set -e
    if [ "$status" -ge 128 ]; then kind=CRASH; bad=1
    elif [ "$status" -eq 0 ] && grep -q 'caught=true' "$d/enumerate.log"; then kind=caught
    elif [ "$status" -eq 1 ] && grep -q 'caught=false' "$d/enumerate.log"; then kind=miss
    else kind=FAILED; bad=1; fi
    cp "$d/enumerate.log" "$evidence/$m/"
    line="$line enumerate=$kind exit=$status [$(tail -1 "$d/enumerate.log")]"
  fi
  echo "$line"
  rm -rf "$d"
done
exit "$bad"
