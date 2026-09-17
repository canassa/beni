#!/bin/sh
# Regenerate the depth sweep (docs/design/checker.md §5, §7).
#
# One fixture per guard that can stop the checker reading a type, at
# guard − 1 and guard + 1. The SHALLOW one must check clean; the DEEP one
# must produce a diagnostic. That pairing is the whole point: every one of
# these guards used to poison a type and say nothing, and a poisoned type
# unifies with anything, so the declaration became a hole and a caller's
# mistake compiled clean. A test that only asserts "it did not crash"
# cannot see that.
#
# The boundaries below are MEASURED against the binary, not derived — the
# number of `read` levels one source level costs is an implementation
# detail and this is exactly the kind of change the sweep should catch. If
# a guard moves, re-run this and bless the goldens:
#
#   sh tests/corpus/check/depth/generate.sh
#   BENI_WRITE_EXPECTED=1 BENI_BLESS_ONLY=check/depth zig build test-blackbox
#
# Everything written here is a few kilobytes, well under the 256 KB the
# repository is willing to carry (`bench/pathological/`'s rule); the guards
# that need a megabyte-scale file are generated on demand by `bench/gen.zig`
# instead.
set -eu
dir=$(dirname "$0")

# `repeat <n> <text>` — `<text>` n times, no newline.
repeat() {
    i=0
    while [ "$i" -lt "$1" ]; do printf '%s' "$2"; i=$((i + 1)); done
}

# ---------------------------------------------------------------------------
# `Types.Builder.max_depth` (512): a WRITTEN type, read into store variables.
# Measured: 510 levels of tuple nesting check clean, 511 report.
# ---------------------------------------------------------------------------
annotation() {
    printf -- '-- check/depth: %s\n' "$2"
    printf 'pub f : '
    repeat "$1" '( '
    printf 'Int'
    repeat "$1" ', Int )'
    printf ' -> Int\nf _ =\n    1\n'
}
annotation 510 'one level under Types.Builder.max_depth: the checker reads it all.' \
    > "$dir/AnnotationOk.beni"
annotation 511 'one level over Types.Builder.max_depth: a diagnostic, never silence.' \
    > "$dir/AnnotationDeep.beni"

# ---------------------------------------------------------------------------
# The same guard reached through ALIAS EXPANSION, which is the path that
# crosses a declaration boundary — an alias body costs a level like any
# other node. Measured: a chain of 509 checks clean, 510 reports.
# ---------------------------------------------------------------------------
alias_chain() {
    printf -- '-- check/depth: %s\n' "$2"
    i=0
    while [ "$i" -lt "$1" ]; do
        printf 'type alias A%d =\n    A%d\n\n\n' "$i" "$((i + 1))"
        i=$((i + 1))
    done
    printf 'type alias A%d =\n    Int\n\n\npub f : A0 -> Int\nf _ =\n    1\n' "$1"
}
alias_chain 509 'one under the limit, reached by expanding aliases rather than nesting.' \
    > "$dir/AliasChainOk.beni"
alias_chain 510 'one over: an alias body costs a level like any other node.' \
    > "$dir/AliasChainDeep.beni"

# ---------------------------------------------------------------------------
# `Schemes.Writer.max_depth` (512): an INFERRED type, written into the
# interface. Nothing was annotated here — the type is as deep as the literal
# — so this is the guard on the way OUT, not the way in. Measured: 511
# checks clean, 512 reports.
# ---------------------------------------------------------------------------
inferred() {
    printf -- '-- check/depth: %s\n' "$2"
    printf 'pub f =\n    '
    repeat "$1" '( '
    printf '1'
    repeat "$1" ', 2 )'
    printf '\n'
}
inferred 511 'one under Schemes.Writer.max_depth: the whole type reaches the interface.' \
    > "$dir/InferredOk.beni"
inferred 512 'one over: the scheme is `<error>` AND there is a message.' \
    > "$dir/InferredDeep.beni"

# ---------------------------------------------------------------------------
# There is no pair for the DERIVATION guard of
# `docs/design/static-dispatch-spike.md` §6.3, and there cannot be one.
# Derivation is structural and recursive (§3.3), so `==` on a deep tuple
# costs a level of `targetFor` per level of type — but the TYPE READER stops
# at `Types.Builder.max_depth` (512) first, which `AnnotationOk`/`Deep`
# above already pin, and the §6.3 guard is written at `Parse.max_depth + 104`
# for the same reason `Constrain`'s and `Solve`'s are: the parser refuses the
# file before the checker can reach it. A pair here would have pinned the 512
# guard a second time under a name that says 4200, which is worse than none.
# The guard is in the code (`Solver.targetFor`) so a poisoned store cannot
# make the recursion run away; nothing reachable from a source file trips it.

# ---------------------------------------------------------------------------
# `Parse.max_depth` (4096), which is why the checker's own 4200-level guards
# in `Constrain` and `Solve` are unreachable and may stay silent: the parser
# refuses the file first. Measured: 4095 checks clean, 4096 reports — and
# the message comes from the PARSER, which is the argument those guards
# rest on.
# ---------------------------------------------------------------------------
parens() {
    printf -- '-- check/depth: %s\n' "$2"
    printf 'pub f : Int\nf =\n    '
    repeat "$1" '('
    printf '1'
    repeat "$1" ')'
    printf '\n'
}
parens 4095 'one under Parse.max_depth, which the checker never has to guard against.' \
    > "$dir/ParserOk.beni"
parens 4096 'one over: the PARSER reports, so the checker 4200 guards are unreachable.' \
    > "$dir/ParserDeep.beni"

# ---------------------------------------------------------------------------
# The same guard reached through a TYPE rather than an expression. Its own
# pair because the two take different paths into `enter()`: an expression
# charges in `parseExpr`, a parenthesised type in `parseTypeAtom`'s `(`
# branch, and the n-ary function type change briefly removed the second —
# `parseTypeItems -> parseTypeApp -> parseTypeAtom` is a cycle, so 30 000
# nested `(` were accepted in silence. Measured: 4095 clean, 4096 reports.
# ---------------------------------------------------------------------------
type_parens() {
    printf -- '-- check/depth: %s\n' "$2"
    printf 'pub f : '
    repeat "$1" '('
    printf 'Int'
    repeat "$1" ')'
    printf ' -> Int\nf _ =\n    1\n'
}
type_parens 4095 'one under Parse.max_depth, reached through a TYPE: it parses and checks.' \
    > "$dir/TypeParensOk.beni"
type_parens 4096 'one over, in a type: a parenthesised type charges a level like any other.' \
    > "$dir/TypeParensDeep.beni"

# ---------------------------------------------------------------------------
# `Render.max_depth` (24): the one guard whose silence is a FORMATTING
# decision and not a judgement. A type printed deeper than this is
# unreadable, so the renderer truncates it to `…` — the diagnostic is
# already decided and the guard only changes how much of one type is shown.
# ---------------------------------------------------------------------------
{
    printf -- '-- check/depth: a type printed past Render.max_depth truncates to `…`.\n'
    printf -- '-- The diagnostic is unaffected: only how much of the type it shows.\n'
    printf 'pub f : '
    repeat 30 '( '
    printf 'Int'
    repeat 30 ', Int )'
    printf ' -> Int\nf _ =\n    1\n\n\npub g : Int\ng =\n    f 1\n'
} > "$dir/RenderTruncatedDeep.beni"
