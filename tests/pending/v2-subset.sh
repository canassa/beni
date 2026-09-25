#!/usr/bin/env bash
# tests/pending/v2-subset.sh — the corpus fixtures checker v2 is held to, as of R6b
# (plans/checker-rewrite.md §3, R4b, R5, R6a and R6b; docs/design/checker-v2.md §22.2).
#
# From R6a v2 checks dispatch (`x.m`, `==`, `where`), and from R6b it elaborates
# evidence (P6) and writes v1's eager derived rows (P5 under v1's one-entry-per-
# parameter context until R8a), so `build` and `dump --stage=dispatch` of a
# dispatching module are v2's too. Every fixture of every kind is in the subset
# but one kind of build:
#
#   - an `emit/` or `emit/release/` fixture (a `--library` build) whose root module
#     declares a `type`: a library exports every nominal derived row, and
#     `js/Emit.zig` refuses to build one under v2 until R8a's contexts (checker-v2.md
#     §5, *Revised by R4b's review*).
#
# The fixtures `v2-expected.md` skips (`core/` directories, the §20.4 rows, R7's and
# R8a's) are never in it. Prints one repo-relative fixture path per line, sorted.
#
#   tests/pending/v2-subset.sh [beni]      # default: zig-out/bin/beni
#
# Run from the repository root. It runs v1 only and changes nothing.
set -euo pipefail

beni="${1:-zig-out/bin/beni}"
corpus=tests/corpus
kinds=(parse/bad dispatch check/good check/bad check/args check/depth build/bad build/bad-release run emit emit/app emit/release regress)

skipped() {
    # A fixture v2-expected.md names, or one under a listed `<kind>/core/`.
    local path="$1"
    grep -q -- "^- \`$path\`" tests/pending/v2-expected.md && return 0
    case "$path" in */core/*) return 0 ;; esac
    return 1
}

in_subset() {
    local path="$1" kind="$2"
    [[ "$kind" == emit || "$kind" == emit/release ]] || return 0
    local files f
    if [[ -d "$path" ]]; then
        files="$(find "$path" -name '*.beni' | sort)"
    else
        files="$path"
    fi
    for f in $files; do
        # A `--library` build of a module that declares a `type` is refused under
        # v2 until R8a (`js/Emit.zig`).
        if "$beni" dump --stage=bir "$f" 2>/dev/null | grep -qE '^decl [0-9]+: (pub )?(opaque )?type [A-Z]'; then return 1; fi
    done
    return 0
}

for kind in "${kinds[@]}"; do
    dir="$corpus/$kind"
    [[ -d "$dir" ]] || continue
    for entry in "$dir"/*; do
        name="$(basename "$entry")"
        case "$name" in core | app | release) continue ;; esac
        if [[ -d "$entry" ]]; then
            path="$entry"
        elif [[ "$entry" == *.beni ]]; then
            path="$entry"
        else
            continue
        fi
        skipped "$path" && continue
        in_subset "$path" "$kind" && echo "$path"
    done
done | sort
