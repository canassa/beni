#!/usr/bin/env bash
# Research 108's measurements, reproducible. Not part of any gate.
#
#   bench/embedded-engine/run.sh <step>...
#
# Steps, in the order the report uses them:
#   fetch     download QuickJS 2026-06-04, QuickJS-ng 0.17.0 (SHA-256 checked)
#   hosts     build the two prototype hosts (ReleaseFast) into $WORK/hosts
#   programs  build programs/*.beni with $BENI for node, dev and --release
#   stress    programs/stress.mjs under node and both hosts, diffed
#   fidelity  the beni programs under node and both hosts, diffed (Math block apart)
#   corpus    every tests/corpus/run/ program, dev and release, under all three
#   timing    one page and fifty pages, whole process and in process
#   determinism  five runs of each program per engine, distinct output hashes
#   cross     cross-compile both hosts for every target from a cold cache
#   ctime     compile time of each engine's C files with zig cc
#   ubsan     both hosts under Zig's C sanitizer (ReleaseSafe and Debug)
#
# WORK (default ~/.cache/beni-engine-bench) holds everything written; BENI
# (default zig-out/bin/beni of this checkout) is the compiler under test.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
WORK=${WORK:-$HOME/.cache/beni-engine-bench}
BENI=${BENI:-$repo/zig-out/bin/beni}
QJS=$WORK/src/quickjs-2026-06-04
NG=$WORK/src/quickjs-0.17.0
H=$WORK/hosts/bin
mkdir -p "$WORK"

fetch() {
  mkdir -p "$WORK/src" && cd "$WORK/src" || exit 1
  curl -sSfL -o qjs.tar.xz https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
  curl -sSfL -o ng.tar.gz https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.17.0.tar.gz
  sha256sum -c <<'EOF' || exit 1
b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a  qjs.tar.xz
559bc4c420475e55c7ab4510adbc562f55d7524d75e8e89d79ce4bb02f5687d9  ng.tar.gz
EOF
  tar xf qjs.tar.xz && tar xf ng.tar.gz
}

hostbuild() { # <prefix> <zig build args...>
  local prefix=$1; shift
  (cd "$here" && zig build -Dqjs="$QJS" -Dng="$NG" --prefix "$prefix" --cache-dir "$WORK/zig-cache" "$@")
}

hosts() { hostbuild "$WORK/hosts" -Doptimize=ReleaseFast; }

programs() {
  mkdir -p "$WORK/out"
  for p in Numbers Strings Page Page50; do
    "$BENI" build --platform=node --no-cache --no-source-maps --out="$WORK/out/$p" "$here/programs/$p.beni"
    "$BENI" build --platform=node --no-cache --no-source-maps --release --allow-debug --out="$WORK/out/$p-rel" "$here/programs/$p.beni"
  done
}

three() { # <entry> [host flags] : writes <entry>.{node,qjs,ng}.out, prints a verdict
  local f=$1; shift
  node "$f" > "$f.node.out" 2> "$f.node.err"; local n=$?
  "$H/qhost-qjs" "$@" "$f" > "$f.qjs.out" 2> "$f.qjs.err"; local q=$?
  "$H/qhost-ng" "$@" "$f" > "$f.ng.out" 2> "$f.ng.err"; local g=$?
  local qv=same gv=same
  { cmp -s "$f.node.out" "$f.qjs.out" && [ $n = $q ]; } || qv=DIFF
  { cmp -s "$f.node.out" "$f.ng.out" && [ $n = $g ]; } || gv=DIFF
  echo "$f node=$n qjs=$q:$qv ng=$g:$gv lines=$(wc -l < "$f.node.out")"
}

stress() {
  cp "$here/programs/stress.mjs" "$here/programs/globals.mjs" "$WORK/"
  three "$WORK/stress.mjs"
  diff "$WORK/stress.mjs.node.out" "$WORK/stress.mjs.qjs.out"
  diff "$WORK/stress.mjs.node.out" "$WORK/stress.mjs.ng.out"
  "$H/qhost-qjs" "$WORK/globals.mjs"; "$H/qhost-ng" "$WORK/globals.mjs"
}

mathcols() { # <a> <b> : differing values per column of the engine-dependent block
  local a=$1 b=$2 start
  start=$(grep -n "engine-dependent" "$a" | cut -d: -f1)
  echo "differing lines before the block: $(diff <(head -n "$start" "$a") <(head -n "$start" "$b") | grep -c '^<')"
  paste -d'\t' <(tail -n +$((start + 1)) "$a") <(tail -n +$((start + 1)) "$b") | awk -F'\t' '
  { split($1, x, " "); split($2, y, " "); for (i = 1; i <= 7; i++) if (x[i] != y[i]) d[i]++ }
  END { split("sin cos tan sqrt atan log10 pow", n, " "); for (i = 1; i <= 7; i++) printf "%s=%d ", n[i], d[i] + 0; print "of " NR " rows" }'
}

fidelity() {
  for p in Numbers Numbers-rel Strings Strings-rel Page Page-rel Page50-rel; do three "$WORK/out/$p/_main.mjs"; done
  for e in qjs ng; do echo "Numbers, node vs $e:"; mathcols "$WORK/out/Numbers/_main.mjs.node.out" "$WORK/out/Numbers/_main.mjs.$e.out"; done
}

corpus() {
  local src=$repo/tests/corpus/run w=$WORK/corpus
  mkdir -p "$w"
  for f in "$src"/*; do
    local base name
    base=$(basename "$f")
    case "$base" in *.beni) ;; *.*) continue ;; esac
    name=${base%.beni}
    [ -e "$src/$name.requests" ] || [ -e "$f/_expected.requests" ] && continue
    for mode in dev rel; do
      local flags="" out=$w/$name.$mode
      [ $mode = rel ] && flags="--release --allow-debug"
      rm -rf "$out"
      if [ -d "$f" ]; then
        local plat=node; [ -d "$f/platform" ] && plat=platform
        (cd "$f" && "$BENI" build --platform=$plat --no-cache --no-source-maps $flags --out="$out" . > "$out.build" 2>&1)
      else
        "$BENI" build --platform=node --no-cache --no-source-maps $flags --out="$out" "$f" > "$out.build" 2>&1
      fi
      [ -f "$out/_main.mjs" ] || { echo "$name $mode nobuild"; continue; }
      # The corpus may read the clock or randomness; prerendering may not.
      echo "$name $mode $(three "$out/_main.mjs" --date --random | cut -d' ' -f2-4)"
    done
  done | tee "$WORK/corpus.txt" | grep DIFF
  echo "runs: $(wc -l < "$WORK/corpus.txt"); qjs DIFF $(grep -c 'qjs=[0-9]*:DIFF' "$WORK/corpus.txt"); ng DIFF $(grep -c 'ng=[0-9]*:DIFF' "$WORK/corpus.txt")"
}

med() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
wall() { local n=$1 s e; shift; for _ in $(seq "$n"); do s=$(date +%s%N); "$@" > /dev/null 2>&1; e=$(date +%s%N); echo $(((e - s) / 1000)); done | med; }

timing() {
  for p in Page Page-rel Page50-rel; do
    local f=$WORK/out/$p/_main.mjs n=21 abs
    [ $p = Page50-rel ] && n=7
    echo "$p: node $(wall $n node "$f") us, qjs $(wall $n "$H/qhost-qjs" "$f") us, ng $(wall $n "$H/qhost-ng" "$f") us (median wall of $n)"
    abs=$(realpath "$f")
    echo "$p: node in process $(for _ in $(seq $n); do node -e "const t=performance.now(); import('$abs').then(()=>process.stderr.write(String(Math.round((performance.now()-t)*1000))+'\n'))" 2>&1 > /dev/null; done | med) us"
  done
  "$H/qhost-qjs" --repeat 5 "$WORK/out/Page-rel/_main.mjs" > /dev/null
  "$H/qhost-ng" --repeat 5 "$WORK/out/Page-rel/_main.mjs" > /dev/null
}

determinism() {
  for p in Strings Numbers Page50-rel; do
    local f=$WORK/out/$p/_main.mjs
    for q in qhost-qjs qhost-ng; do
      echo "$p $q distinct=$(for _ in 1 2 3 4 5; do "$H/$q" "$f" | sha256sum; done | sort -u | wc -l)"
    done
  done
}

cross() {
  for t in x86_64-linux-musl aarch64-linux-musl x86_64-linux-gnu aarch64-macos x86_64-macos x86_64-windows-gnu wasm32-wasi; do
    rm -rf "$WORK/zig-cache"
    local s e r=ok
    s=$(date +%s%N)
    hostbuild "$WORK/cross/$t" -Doptimize=ReleaseFast -Dtarget=$t > "$WORK/cross-$t.log" 2>&1 || r=FAIL
    e=$(date +%s%N)
    echo "$t $r $(((e - s) / 1000000)) ms: $(cd "$WORK/cross/$t/bin" 2>/dev/null && for f in *; do printf '%s=%s ' "$f" "$(stat -c %s "$f")"; done)"
    [ $r = FAIL ] && grep -m2 "error:" "$WORK/cross-$t.log"
  done
  hostbuild "$WORK/cross/wasm-small" -Doptimize=ReleaseSmall -Dtarget=wasm32-wasi -Dstrip=true > /dev/null 2>&1
  stat -c '%n %s' "$WORK/cross/wasm-small/bin/qhost-ng.wasm"
  node --no-warnings "$here/run-wasi.mjs" "$WORK/cross/wasm-small/bin/qhost-ng.wasm" "$WORK/out" Page/_main.mjs | cmp - "$WORK/out/Page/_main.mjs.node.out" && echo "wasm32-wasi QuickJS-ng: Page identical to node"
  for e in qhost-qjs qhost-ng; do strip -o "$WORK/$e.stripped" "$WORK/cross/x86_64-linux-musl/bin/$e" && stat -c '%n %s' "$WORK/$e.stripped"; done
}

ctime() {
  local o=$WORK/ctime.o
  for d in "$QJS" "$NG"; do
    for opt in -O0 -O2; do
      local total=0 line=""
      for f in "$d"/{quickjs,dtoa,libregexp,libunicode,cutils}.c; do
        [ -f "$f" ] || continue
        local s e ms
        s=$(date +%s%N)
        zig cc -c $opt -std=gnu11 -funsigned-char -w -D_GNU_SOURCE -DCONFIG_VERSION='"x"' -I "$d" "$f" -o "$o"
        e=$(date +%s%N); ms=$(((e - s) / 1000000)); total=$((total + ms))
        line="$line $(basename "$f")=${ms}ms"
      done
      echo "$(basename "$d") $opt total=${total}ms$line"
    done
  done
}

ubsan() {
  hostbuild "$WORK/ubsan-safe" -Doptimize=ReleaseSafe -Dubsan=true
  hostbuild "$WORK/ubsan-debug" -Doptimize=Debug -Dubsan=true
  # stress.mjs's last line differs for Bellard's by design (§6.1), so its
  # verdict is against that engine's own unsanitized output.
  for v in ubsan-safe ubsan-debug; do
    for e in qhost-qjs qhost-ng; do
      for f in "$WORK/stress.mjs" "$WORK/out/Strings/_main.mjs" "$WORK/out/Numbers/_main.mjs" "$WORK/out/Page50-rel/_main.mjs"; do
        local ref=$f.${e#qhost-}.out
        "$WORK/$v/bin/$e" "$f" > "$WORK/$v.$e.out" 2> "$WORK/$v.$e.err"
        local x=$?
        echo "$v $e $(basename "$(dirname "$f")")/$(basename "$f") exit=$x same-as-unsanitized=$(cmp -s "$WORK/$v.$e.out" "$ref" && echo yes || echo no) $(head -1 "$WORK/$v.$e.err")"
      done
    done
  done
}

[ $# -gt 0 ] || { sed -n '2,24p' "$0"; exit 2; }
for step in "$@"; do echo "== $step"; "$step"; done
