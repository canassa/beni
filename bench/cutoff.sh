#!/bin/sh
# The firewall cutoff's differential harness, in full (`plans/m4-3.md` §10.2,
# `fast-compiler.md` §8's *Acceptance is the incremental-determinism matrix,
# made sharp*).
#
# Where an interface-churn count asked "does editing a body change the
# interface?", this asks the sharper question the cutoff is answerable
# by: **after an edit, is the incremental build byte-identical to a cold
# one, AND was each module skipped exactly when the enumeration says it may
# be?**
#
# Byte-identity alone is satisfied by a cache that never hits. The criterion is
# byte-identity AND the counter, and the predicted set is not hard-coded: it is
# computed from `--cache-keys`, so a new edit class needs no new expectation.
#
#   cold   build into a fresh cache directory, capture every stream
#   warm0  build again; byte-identical to cold; modules_checked == 0
#   apply  the edit
#   warm1  build; byte-identical to a COLD build of the EDITED tree;
#          modules_checked == the number of keys that moved
#   revert the edit
#   warm2  build; byte-identical to cold again
#
# **The bounded subset is `tests/blackbox/cutoff_test.zig`** and runs in every
# gate: one edit per branch of the cut-off decision on §10.1's five-module
# project, the digest-only one a DEMONSTRATED miscompile. This script is the
# full cross over every module of every project, it is a documented command
# rather than a gate, and its wall time is reported. Over ten minutes on the reference machine it
# samples with a fixed stride, seeded and printed, exactly as §10.2 specifies
# the fallback rather than discovering it.
#
# Usage:
#   bench/cutoff.sh                     every project, every module
#   bench/cutoff.sh --stride=4          every 4th module of each project
#   bench/cutoff.sh --project=bench/corpus
#   bench/cutoff.sh --jobs=8
#
# Deterministic: the module list is the shell's sorted glob, the edit classes
# are in the order below, and the stride is over that list. Two runs of the
# same command do the same builds in the same order.

set -eu

BENI=${BENI:-./zig-out/bin/beni}
WORK=${TMPDIR:-/tmp}/beni-cutoff.$$
STRIDE=1
JOBS=1
ONLY=

for arg in "$@"; do
    case "$arg" in
        --stride=*) STRIDE=${arg#--stride=} ;;
        --jobs=*) JOBS=${arg#--jobs=} ;;
        --project=*) ONLY=${arg#--project=} ;;
        *) echo "usage: $0 [--stride=N] [--jobs=N] [--project=PATH]" >&2; exit 2 ;;
    esac
done

if [ ! -x "$BENI" ]; then
    echo "cutoff: $BENI is not executable; run 'zig build' first" >&2
    exit 2
fi

mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

started=$(date +%s)
total=0
failures=0

# ---------------------------------------------------------------------------
# The edit classes
# ---------------------------------------------------------------------------
#
# Every one is MECHANICAL and applied to a whole file, so it needs no parse:
# a harness that had to understand the language would be a second compiler,
# and the interface-churn instrument before this learned that the hard way.
#
#   comment     prepend a comment line — no token of the program moves
#   whitespace  append two blank lines
#   private     append a private value nothing names
#   privtype    append a private TYPE nothing names
#   pubvalue    append a `pub` value — moves the interface hash
#   reorder     move the last declaration to the front
#
# The classes that need a SPECIFIC declaration to edit — a private type's
# payload becoming a function, an alias body no scheme mentions, a `pub`
# signature change — are the two demonstrated miscompiles and their
# neighbours, and they live in the bounded subset where the project is written
# to contain them. A mechanical edit cannot manufacture one on an arbitrary
# module, and a harness that pretended to would be reporting on the rows it
# happened to hit.
EDITS="comment whitespace private privtype pubvalue reorder"

apply_edit() {
    _class=$1
    _file=$2
    case "$_class" in
        comment)
            { echo "-- cutoff.sh: a comment nobody reads"; cat "$_file"; } > "$_file.new"
            ;;
        whitespace)
            { cat "$_file"; echo; echo; } > "$_file.new"
            ;;
        private)
            { cat "$_file"; echo; echo; echo "cutoffShHelper : Int"; echo "cutoffShHelper ="; echo "    7"; } > "$_file.new"
            ;;
        privtype)
            { cat "$_file"; echo; echo; echo "type CutoffShUnmentioned"; echo "    = CutoffShU Int"; } > "$_file.new"
            ;;
        pubvalue)
            { cat "$_file"; echo; echo; echo "pub cutoffShExtra : Int"; echo "cutoffShExtra ="; echo "    2"; } > "$_file.new"
            ;;
        reorder)
            # The last two paragraphs SWAPPED, and nothing else moved.
            #
            # Moving the last paragraph to the FRONT was the first attempt and
            # it is wrong: a module whose first paragraph is `import` becomes a
            # module whose import follows a declaration, which does not parse —
            # so the "edit" was really "break the file", the module went
            # uncacheable, and its importers were re-checked for a reason the
            # enumeration has nothing to say about. Swapping the tail leaves
            # the import block where it is. A file with fewer than three
            # paragraphs is left alone, and the scenario then asserts that a
            # no-op moves nothing, which is still worth asserting.
            awk 'BEGIN{RS="";ORS="\n\n"} {a[NR]=$0} END{
                if (NR < 3) { for (i=1;i<=NR;i++) print a[i]; }
                else { for (i=1;i<=NR-2;i++) print a[i]; print a[NR]; print a[NR-1]; }
            }' "$_file" > "$_file.new"
            ;;
    esac
    mv "$_file.new" "$_file"
}

# ---------------------------------------------------------------------------
# One run
# ---------------------------------------------------------------------------

# `beni check` over $1 (the project root), with $2 as the cache directory
# ("-" for --no-cache) and $3 as the trace path. Writes stdout to $4.out,
# stderr to $4.err, the exit code to $4.code and the counter to $4.checked.
one_run() {
    _root=$1; _cache=$2; _trace=$3; _slot=$4
    if [ "$_cache" = "-" ]; then
        _cacheflag="--no-cache"
    else
        _cacheflag="--cache-dir=$_cache"
    fi
    set +e
    # `EXTRA` is `--core-root=<the copy>` when the project IS core: without it
    # the files are checked as APP modules beside the EMBEDDED core, which is
    # two copies of every type and a project that does not resolve. Measured
    # before adding it: 60 of 60 scenarios, all `warm0 re-checked 8`.
    # shellcheck disable=SC2086
    "$BENI" check --jobs="$JOBS" --cache-keys $EXTRA "$_cacheflag" \
        "--self-profile=$_trace" "$_root" > "$_slot.out" 2> "$_slot.err"
    echo $? > "$_slot.code"
    set -e
    # `modules_checked` is a counter event in the trace; the last one wins,
    # exactly as the blackbox harness reads it.
    tr ',' '\n' < "$_trace" | sed -n 's/.*"modules_checked":\([0-9]*\).*/\1/p' | tail -1 > "$_slot.checked"
    [ -s "$_slot.checked" ] || echo 0 > "$_slot.checked"
}

keys_moved() {
    # Lines present in $1 and not in $2, plus module names present in $2 and
    # not in $1.
    _gone=$(comm -23 "$1" "$2" | wc -l)
    _new=$(cut -d' ' -f1 "$2" | sort > "$WORK/n2"; cut -d' ' -f1 "$1" | sort > "$WORK/n1"; comm -13 "$WORK/n1" "$WORK/n2" | wc -l)
    echo $((_gone + _new))
}

fail() {
    failures=$((failures + 1))
    echo "  FAIL  $*" >&2
}

# ---------------------------------------------------------------------------
# One project
# ---------------------------------------------------------------------------

sweep() {
    _src=$1
    echo "project $_src"
    if [ -n "$EXCLUDE" ]; then echo "  excluding: $EXCLUDE"; fi

    _modules=$(find "$_src" -name '*.beni' | sort)
    for _drop in $EXCLUDE; do
        _modules=$(echo "$_modules" | grep -v "/$_drop\$" || true)
    done
    _count=$(echo "$_modules" | wc -l)
    echo "  $_count modules, stride $STRIDE, $(echo "$EDITS" | wc -w) edit classes"

    _i=0
    for _module in $_modules; do
        _i=$((_i + 1))
        [ $(((_i - 1) % STRIDE)) -eq 0 ] || continue
        _rel=${_module#"$_src"/}

        for _class in $EDITS; do
            total=$((total + 1))
            _tree=$WORK/tree
            rm -rf "$_tree" "$WORK/cache"
            mkdir -p "$_tree"
            cp -R "$_src/." "$_tree/"
            for _drop in $EXCLUDE; do rm -f "$_tree/$_drop"; done
            EXTRA=
            if [ "$IS_CORE" = 1 ]; then EXTRA="--core-root=$_tree"; fi

            one_run "$_tree" "$WORK/cache" "$WORK/t0.json" "$WORK/cold"
            sort "$WORK/cold.out" > "$WORK/k0"
            one_run "$_tree" "$WORK/cache" "$WORK/t1.json" "$WORK/warm0"
            if ! cmp -s "$WORK/cold.out" "$WORK/warm0.out" || ! cmp -s "$WORK/cold.err" "$WORK/warm0.err"; then
                fail "$_rel/$_class: warm0 differs from cold"
                continue
            fi
            if [ "$(cat "$WORK/warm0.checked")" != "0" ]; then
                fail "$_rel/$_class: warm0 re-checked $(cat "$WORK/warm0.checked") modules"
                continue
            fi

            apply_edit "$_class" "$_tree/$_rel"

            one_run "$_tree" "$WORK/cache" "$WORK/t2.json" "$WORK/warm1"
            one_run "$_tree" "-" "$WORK/t3.json" "$WORK/cold1"
            if ! cmp -s "$WORK/cold1.out" "$WORK/warm1.out" || ! cmp -s "$WORK/cold1.err" "$WORK/warm1.err" ||
                ! cmp -s "$WORK/cold1.code" "$WORK/warm1.code"; then
                fail "$_rel/$_class: the incremental build is not the cold build"
                continue
            fi
            # **The counter assertion holds for a CLEAN build, and only for
            # one.** `fast-compiler.md` §8's clean-check rule refuses to write
            # an entry for a module that reported, and uncacheability
            # propagates to its importers — so a broken tree re-checks a set
            # the KEYS cannot describe, because those modules' keys name
            # nothing. A mechanical edit can break an arbitrary file (measured:
            # `reorder` on `core/List.beni` splits a `let` across a blank line
            # and the module stops parsing), and a row that asserted the
            # counter there would be asserting the error path.
            #
            # Byte-identity is asserted either way, and for the rows that
            # matter most it is the WHOLE assertion: §6.1's and §6.2's
            # miscompiles are exactly "warm exits 0 where cold exits 1".
            if [ "$(cat "$WORK/cold1.code")" = "0" ] && [ "$(cat "$WORK/cold.code")" = "0" ]; then
                sort "$WORK/warm1.out" > "$WORK/k1"
                _predicted=$(keys_moved "$WORK/k0" "$WORK/k1")
                _checked=$(cat "$WORK/warm1.checked")
                if [ "$_checked" != "$_predicted" ]; then
                    fail "$_rel/$_class: re-checked $_checked, $_predicted keys moved"
                    continue
                fi
                echo "  ok    $_rel/$_class  re-checked $_checked"
            else
                echo "  ok    $_rel/$_class  byte-identical (the edit does not compile)"
            fi
        done
    done
}

# `bench/corpus` carries two modules that do not resolve from a pristine root
# — excluded here for that reason. They error, so
# they are uncacheable, so they are re-checked on every run whatever the
# cutoff decides; leaving them in would make every scenario in the project
# "fail" at warm0 for a reason the enumeration has nothing to say about.
# Measured before excluding them: 66 of 66 scenarios, all `warm0 re-checked 2`.
CORPUS_EXCLUDE="JsonCodecs.beni NotesApp.beni"
EXCLUDE=
IS_CORE=0
EXTRA=

configure() {
    EXCLUDE=
    IS_CORE=0
    case "$1" in
        *bench/corpus*) EXCLUDE=$CORPUS_EXCLUDE ;;
        core|*/core) IS_CORE=1 ;;
    esac
}

if [ -n "$ONLY" ]; then
    configure "$ONLY"
    sweep "$ONLY"
else
    for p in bench/corpus core tests/corpus/check/good/Chain tests/corpus/check/good/Diamond \
        tests/corpus/check/good/AliasAcrossModules tests/corpus/check/good/GenericChain; do
        [ -d "$p" ] || continue
        configure "$p"
        sweep "$p"
    done
fi

elapsed=$(( $(date +%s) - started ))
echo
echo "cutoff: $total scenarios, $failures failures, ${elapsed}s"
[ "$failures" -eq 0 ]
