#!/usr/bin/env bash
# tests/pending/v2-subset.sh — the corpus fixtures checker v2 is held to, as of R5
# (plans/checker-rewrite.md §3, R4b and R5; docs/design/checker-v2.md §22.2).
#
# A fixture is in the v2-subset when its ROOT modules need no dispatch, read
# off the ORACLE (checker v1, the default checker). The obligation forms —
# `tuple_index`, `interp`, `try`, explicit `Basics.eq`/`neq` — are in it from
# R5:
#
#   - its `dump --stage=dispatch` has no `site` line and only `evidence=0`
#     declarations;
#   - v2 writes no eager derived row (A.23's rows are P5, R8a's: checker-v2.md
#     §5, as built by R4b), so a `dispatch/` fixture with a `derived` row is
#     out, and so is an `emit/` or `emit/release/` fixture (a `--library`
#     build) whose root module declares a `type` — v2 checks it, and
#     `js/Emit.zig` refuses to build it as a library;
#   - no root module's `dump --stage=bir` holds a `method_call`,
#     `type_dispatch` or `where` clause (dispatch v1 wrote no site for because
#     the module failed first: R6a).
#
# The fixtures `v2-expected.md` skips (`core/` directories, the §20.4 rows) are
# never in it. Prints one repo-relative fixture path per line, sorted.
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
    local table
    # A fixture that does not resolve may not dump; an empty table is fine.
    table="$("$beni" dump --stage=dispatch "$path" 2>/dev/null || true)"
    if grep -qE '^  site ' <<<"$table"; then return 1; fi
    # v2 writes no derived row (P5 is R8a's): a `dispatch/` golden that holds
    # one cannot match.
    if [[ "$kind" == dispatch ]] && grep -qE '^  derived ' <<<"$table"; then return 1; fi
    if grep -E '^  decl ' <<<"$table" | grep -qv ' evidence=0 '; then return 1; fi
    local files
    if [[ -d "$path" ]]; then
        files="$(find "$path" -name '*.beni' | sort)"
    else
        files="$path"
    fi
    local f bir
    for f in $files; do
        bir="$("$beni" dump --stage=bir "$f" 2>/dev/null || true)"
        if grep -qE ' = (method_call|type_dispatch) ' <<<"$bir"; then return 1; fi
        if grep -qE '^  where ' <<<"$bir"; then return 1; fi
        # A `--library` build (every `emit/` fixture but `emit/app/`) of a module
        # that declares a `type` is refused under v2 (`js/Emit.zig`).
        if [[ "$kind" == emit || "$kind" == emit/release ]] && grep -qE '^decl [0-9]+: (pub )?(opaque )?type [A-Z]' <<<"$bir"; then return 1; fi
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
