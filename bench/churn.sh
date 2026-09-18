#!/bin/sh
# Interface churn — M3 of `plans/static-dispatch-spike.md` §7.
#
# The question: how often does editing a declaration's BODY change the
# interface that declaration exports? `fast-compiler.md` §3.1 makes top-level
# annotations optional and §8.1 makes the inferred scheme the interface, so on
# an UNANNOTATED declaration a body edit can move the interface and break
# every dependent's incremental build. Report 18 §2.3 argues that static
# dispatch makes that worse. This script measures it instead of arguing it.
#
# Method, per `pub` value declaration of every module in the corpus root:
#
#   * Two VARIANTS of the same declaration are measured. `annotated` is the
#     module as written. `unannotated` deletes that one declaration's type
#     annotation and moves its `pub` onto the definition line, so the scheme
#     is inferred — the same program, the same interface, one fewer written
#     type.
#   * Four EDIT CLASSES are applied mechanically to the body:
#       E1     change one integer literal. The first integer literal in the
#              body that is a token of its own (not a digit inside an
#              identifier, not inside a string or a comment) is incremented.
#              This is the control: an edit that cannot change any type.
#       E2     duplicate an existing operator application on a parameter.
#              The operand may be the parameter itself or a field path rooted
#              at it (`model.count + 1` counts), it may sit on either side of
#              the operator, and the operator set is `++ // + - * /` — every
#              one of them left-associative and type-preserving, so
#              `p OP x` -> `p OP p OP x` and `x OP p` -> `x OP p OP p` are
#              both well formed. A second use of an operation the parameter
#              is already constrained by; under dispatch, a second use of a
#              method already in the constraint set.
#       E3     add a NEW operator application on ANY parameter: the body B
#              becomes `always ( B ) (p == p)` for the first parameter `p`
#              that no `==` or `/=` already mentions. `always : a, b -> a`
#              returns B unchanged, so the program's VALUE is untouched and
#              only the constraint on `p` is new.
#       E3poly the same edit restricted to a parameter the ANNOTATION types
#              with a bare type variable — a lower identifier that is not
#              `number` or `appendable`, both of which are already
#              constrained and so belong to E2's question rather than this
#              one. This is the row report 18 §2.3's claim is actually about:
#              E3 over any parameter mostly lands on concrete types, where
#              `==` adds nothing, and says nothing about polymorphism.
#     `==` is the only ad-hoc operation C0 has on a polymorphic value, which
#     is itself part of the finding.
#   * `beni dump --stage=raw` is taken before and after each edit and the
#     target module's record is byte-compared. That dump is the interface
#     record's bytes (`src/dump/interface.zig`), the same surface the
#     determinism test compares across `--jobs`, and §9 notes it is exactly
#     what M4's interface hash will be taken over.
#
#     The dump is of the WHOLE ROOT (`dump --stage=raw --root=<root> <root>`,
#     `src/main.zig:257`), not of one file. Dumping one file leaves its
#     sibling imports unresolved — `Counter.beni` alone reports seven UNKNOWN
#     MODULE — so a per-file baseline would be comparing two broken records.
#     The target module's record is cut out of the root dump by its `module`
#     header line.
#
# What this script structurally CANNOT measure, and where that lives instead.
# Every edit class above edits the declaration whose dump it diffs, so none of
# them can see a record moved by an edit to a DIFFERENT module. That is a real
# failure mode and it was a real defect: `Interface.Term`'s `app` and `alias`
# carried a whole-program `TypeStore.TypeId`, so a type declared anywhere
# earlier in sorted-path order rewrote an untouched module's bytes
# (`plans/m4-plan.md` §2.2). The fixture that covers it is a black-box
# scenario, not a bench row — "a type declared elsewhere leaves an untouched
# module's interface bytes alone" in `tests/blackbox/blackbox_test.zig`, which
# is a gate rather than a measurement because the answer is 0 or a bug.
#
# Every outcome is counted:
#
#   changed    the edit moved the interface
#   unchanged  it did not
#   skipped    the edit class does not apply to this declaration (no integer
#              literal, no operator on a parameter, no parameter, no
#              polymorphic parameter, a body that shares its line with the
#              `=`)
#   rejected   the compiler reported an error on the edited program. This is
#              counted from `--diagnostics=json` and NEVER from the exit
#              status: `beni dump` exits 0 whatever it found, so a run that
#              read the exit code would score a type error as a successful
#              measurement. For E3 on an annotated declaration a rejection is
#              often the EXPECTED answer and the point of the row — in C0 you
#              cannot add an operation to a value whose annotation says `a`,
#              so the edit that dispatch would turn into an interface change
#              is today a compile error.
#
# Modules the pristine corpus cannot resolve are EXCLUDED before anything is
# measured — `bench/corpus/JsonCodecs.beni` imports a `Json.Decode` and
# `NotesApp.beni` an `Html` that do not exist — because a root that does not
# resolve has no baseline to compare against. The exclusion list is printed.
#
# Nothing under the corpus root is written: the whole tree is copied to a
# temporary directory first, and the copy is diffed against the original at
# the end, which is reported as `tree restored`.
#
# POSIX sh, awk, and the beni binary. No bashisms and no other tooling.

set -eu

beni="./zig-out/bin/beni"
corpus="bench/corpus"
only_module=""
verbose=0
core_flag=""
extra_excludes=""

usage() {
    cat <<'USAGE'
usage: sh bench/churn.sh [options]

  --beni=<path>       compiler to run (default ./zig-out/bin/beni)
  --corpus=<dir>      corpus root to churn (default bench/corpus)
  --module=<rel>      only this module, relative to the corpus root
  --exclude=<rel>     drop this module from the copy before measuring;
                      repeatable. Modules the pristine root cannot resolve
                      are dropped automatically.
  --core              the corpus root IS the core package (adds --core to
                      every dump, so `--corpus=core` works)
  --verbose           list every declaration and outcome before the table
  --help              print this

Prints a table of changed/accepted per edit class and variant, with the
applied, skipped and rejected counts beside it. Declarations are visited in
sorted module order, then in source order, so the output is the same on
every run.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --beni=*) beni=${arg#--beni=} ;;
        --corpus=*) corpus=${arg#--corpus=} ;;
        --module=*) only_module=${arg#--module=} ;;
        --exclude=*) extra_excludes="$extra_excludes ${arg#--exclude=}" ;;
        --core) core_flag="--core" ;;
        --verbose) verbose=1 ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "bench/churn.sh: unknown option $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ ! -x "$beni" ]; then
    echo "bench/churn.sh: $beni is not executable; run 'zig build' first" >&2
    exit 2
fi
if [ ! -d "$corpus" ]; then
    echo "bench/churn.sh: $corpus is not a directory" >&2
    exit 2
fi

beni_abs=$(cd "$(dirname "$beni")" && pwd)/$(basename "$beni")
corpus_abs=$(cd "$corpus" && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/beni-churn.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT INT TERM

# EVERY file, not just the `.beni` ones: a `foreign` value binds to a sibling
# `.js` file by name (`boundary.md` §4), so a copy of `core/` without
# `Basics.js` beside `Basics.beni` does not resolve and six of its eleven
# modules would be excluded before anything was measured. Only `.beni` files
# are ever edited, so the siblings come back byte-identical for free.
#
# The copy keeps the ROOT'S OWN NAME rather than a generic `src`, because
# `--core` only checks clean when the package directory is called `core`:
# copied to `src/`, `core/Basics.beni` reports six TYPE MISMATCHes at
# `angle * pi / 180` and six of eleven modules would be excluded.
src_name=$(basename "$corpus_abs")
src="$work/$src_name"
mkdir -p "$src"
(cd "$corpus_abs" && find . -type f -print | sort) | while IFS= read -r f; do
    mkdir -p "$src/$(dirname "$f")"
    cp "$corpus_abs/$f" "$src/$f"
done

# ---------------------------------------------------------------------------
# awk: enumerate the `pub` value declarations of one module.
#
# A top-level declaration starts at column 0. `pub name :` opens an
# annotation that runs to the next column-0 line; the definition is the next
# column-0 line starting with the same name. `pub name args =` with no `:`
# before the `=` is an unannotated definition. `pub type`, `pub opaque type`,
# `pub foreign` and `pub equatable foreign type` are not values.
#
# One line out per declaration:
#   name TAB ann_start TAB ann_end TAB def_start TAB def_end TAB params TAB poly
# with ann_start 0 when there is no annotation, line numbers 1-based and
# inclusive with trailing blank lines trimmed, `params` the definition's
# parameter names and `poly` the subset of those the annotation types with a
# bare type variable.
# ---------------------------------------------------------------------------
cat >"$work/decls.awk" <<'AWK'
{ line[NR] = $0 }
END {
    n = NR
    tops = 0
    for (i = 1; i <= n; i++)
        if (line[i] != "" && line[i] !~ /^[ \t]/) top[++tops] = i

    for (t = 1; t <= tops; t++) {
        i = top[t]
        text = line[i]
        if (text !~ /^pub [a-z]/) continue
        rest = substr(text, 5)
        split(rest, word, /[ \t]+/)
        name = word[1]
        if (name == "type" || name == "opaque" || name == "foreign" || name == "equatable") continue

        # `pub name :` — an annotation. The definition is the next top-level
        # line that starts with the same name.
        if (rest ~ ("^" name "[ \t]*:")) {
            ann_start = i
            ann_end = trim(t, tops, top, n, line)
            d = 0
            for (u = t + 1; u <= tops; u++) {
                if (line[top[u]] ~ ("^" name "([ \t]|=)")) { d = u; break }
                if (line[top[u]] ~ ("^" name "[ \t]*$")) { d = u; break }
                break
            }
            if (d == 0) continue
            def_start = top[d]
            def_end = trim(d, tops, top, n, line)
            emit(name, ann_start, ann_end, def_start, def_end, line[def_start], name)
            continue
        }

        # `pub name args =` — no annotation, so nothing is known about which
        # parameters are polymorphic.
        head = rest
        eq = index(head, "=")
        if (eq == 0) continue
        before = substr(head, 1, eq - 1)
        if (index(before, ":") != 0) continue
        def_start = i
        def_end = trim(t, tops, top, n, line)
        emit(name, 0, 0, def_start, def_end, "pub " before "=", name)
    }
}

# The last non-blank line of the block that starts at top[k].
function trim(k, tops, top, n, line,   last, j) {
    last = (k < tops) ? top[k + 1] - 1 : n
    while (last > top[k] && line[last] ~ /^[ \t]*$/) last--
    return last
}

function trimws(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
}

# The annotation's type text: every line of the annotation joined with single
# spaces, after the `:`.
function annotationType(a0, a1,   s, i, t, at) {
    s = ""
    for (i = a0; i <= a1; i++) {
        t = trimws(line[i])
        s = (s == "") ? t : s " " t
    }
    at = index(s, ":")
    if (at == 0) return ""
    return trimws(substr(s, at + 1))
}

# The top-level parameter types of an n-ary function type. `A, B -> C` yields
# `A` and `B`; a type with no top-level `->` yields none. Parentheses,
# brackets and braces are tracked, so the `->` of `(a -> b)` and the `,` of
# `{ x : Int, y : Int }` are invisible here.
function paramTypes(ty, out,   depth, i, c, lastArrow, head, k, start) {
    depth = 0
    lastArrow = 0
    for (i = 1; i <= length(ty); i++) {
        c = substr(ty, i, 1)
        if (c == "(" || c == "[" || c == "{") depth++
        else if (c == ")" || c == "]" || c == "}") depth--
        else if (depth == 0 && c == "-" && substr(ty, i + 1, 1) == ">") lastArrow = i
    }
    if (lastArrow == 0) return 0
    head = substr(ty, 1, lastArrow - 1)
    depth = 0
    k = 0
    start = 1
    for (i = 1; i <= length(head); i++) {
        c = substr(head, i, 1)
        if (c == "(" || c == "[" || c == "{") depth++
        else if (c == ")" || c == "]" || c == "}") depth--
        else if (depth == 0 && c == ",") {
            out[++k] = trimws(substr(head, start, i - start))
            start = i + 1
        }
    }
    out[++k] = trimws(substr(head, start))
    return k
}

# Parameters are the whitespace-separated words between the name and the `=`
# on the definition line. A declaration whose parameters are not all plain
# lower identifiers reports none, so E2 and E3 skip it rather than guess.
#
# `poly` keeps the parameters whose annotated type is a bare type variable.
# `number` and `appendable` are excluded: they are already constrained, so
# `==` on one of them is not the new constraint E3poly is asking about.
function emit(name, a0, a1, d0, d1, defline, dname,   head, eq, before, i, k, w, out, ty, types, nt, poly) {
    head = defline
    sub(/^pub[ \t]+/, "", head)
    eq = index(head, "=")
    out = ""
    k = 0
    if (eq != 0) {
        before = substr(head, 1, eq - 1)
        sub("^" dname "[ \t]*", "", before)
        k = split(before, w, /[ \t]+/)
        for (i = 1; i <= k; i++) {
            if (w[i] == "") continue
            if (w[i] !~ /^[a-z][A-Za-z0-9_]*$/) { out = ""; k = 0; break }
            out = (out == "") ? w[i] : out " " w[i]
        }
    }

    poly = ""
    if (a0 != 0 && out != "") {
        nt = paramTypes(annotationType(a0, a1), types)
        for (i = 1; i <= k && i <= nt; i++) {
            ty = types[i]
            if (ty !~ /^[a-z][A-Za-z0-9_]*$/) continue
            if (ty == "number" || ty == "appendable") continue
            poly = (poly == "") ? w[i] : poly " " w[i]
        }
    }
    printf "%s\t%d\t%d\t%d\t%d\t%s\t%s\n", name, a0, a1, d0, d1, out, poly
}
AWK

# ---------------------------------------------------------------------------
# awk: write the `unannotated` variant of one declaration — drop its
# annotation lines and carry the `pub` onto the definition line.
# ---------------------------------------------------------------------------
cat >"$work/unannotate.awk" <<'AWK'
NR >= ann_start && NR <= ann_end { next }
NR == def_start { print "pub " $0; next }
{ print }
AWK

# ---------------------------------------------------------------------------
# awk: cut one module's record out of a whole-root `--stage=raw` dump. Each
# record starts with its own `module <Name>` line.
# ---------------------------------------------------------------------------
cat >"$work/record.awk" <<'AWK'
/^module / { on = ($2 == want) }
on { print }
AWK

# ---------------------------------------------------------------------------
# awk: the edits. Each prints the edited module on stdout and the word
# `applied` or `skipped` on stderr, so the caller can tell "no change because
# the edit did not apply" from "no change because the interface held" — and
# awk's own exit status is checked separately, so a broken edit program is a
# failure rather than a wall of skips.
# ---------------------------------------------------------------------------
cat >"$work/edit.awk" <<'AWK'
{ line[NR] = $0 }

# Blank out everything a literal or a comment owns, keeping the length so
# offsets still line up with the original: string and char contents, and
# anything after `--`. Searching the mask and editing the original is what
# keeps E1 off the digits inside `"20%"` without giving up on the whole line.
function mask(s,   out, i, c, q, esc) {
    out = ""
    q = ""
    esc = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (q == "") {
            if (c == "\"" || c == "'") { q = c; out = out c; continue }
            if (c == "-" && substr(s, i + 1, 1) == "-") {
                while (i <= length(s)) { out = out "x"; i++ }
                break
            }
            out = out c
        } else {
            out = out "x"
            if (esc) { esc = 0; continue }
            if (c == "\\") { esc = 1; continue }
            if (c == q) q = ""
        }
    }
    return out
}

# An integer literal that is a token of its own: the digit run must not touch
# a letter, a digit, an underscore or a dot on either side, which rules out
# `x1`, `1.5` and `Dict.Int`.
function bump(s,   m, i, c, j, run, before, after) {
    m = mask(s)
    i = 1
    while (i <= length(m)) {
        c = substr(m, i, 1)
        if (c >= "0" && c <= "9") {
            j = i
            while (j <= length(m) && substr(m, j, 1) >= "0" && substr(m, j, 1) <= "9") j++
            before = (i == 1) ? "" : substr(m, i - 1, 1)
            after = (j > length(m)) ? "" : substr(m, j, 1)
            if (before !~ /[A-Za-z0-9_.]/ && after !~ /[A-Za-z0-9_.]/) {
                run = substr(s, i, j - i) + 1
                return substr(s, 1, i - 1) run substr(s, j)
            }
            i = j
            continue
        }
        i++
    }
    return ""
}

# The offset of the next occurrence of `pat` in `s` at or after `from`, as a
# whole word on its left edge, or 0.
function findword(s, pat, from,   at, rel, head) {
    at = from
    while (1) {
        rel = index(substr(s, at), pat)
        if (rel == 0) return 0
        at = at + rel - 1
        head = (at == 1) ? "" : substr(s, at - 1, 1)
        if (head !~ /[A-Za-z0-9_.]/) return at
        at = at + 1
    }
}

# The operand rooted at the parameter at offset `at`: the parameter itself,
# or a field path spelled from it.
function operand(s, p, at,   j, tail) {
    j = at + length(p)
    tail = substr(s, j, 1)
    if (tail ~ /[A-Za-z0-9_]/) return ""
    while (j <= length(s) && substr(s, j, 1) ~ /[A-Za-z0-9_.]/) j++
    if (substr(s, j - 1, 1) == ".") return ""
    return substr(s, at, j - at)
}

# A binary operator already applied to the parameter, duplicated. `++` and
# `//` are tried before `+` and `/` so the longer one wins.
function dup(s, p,   ops, nops, k, o, at, term, j, rest, before) {
    nops = split("++ // + - * /", ops, " ")

    at = 1
    while (1) {
        at = findword(s, p, at)
        if (at == 0) break
        term = operand(s, p, at)
        if (term != "") {
            j = at + length(term)
            rest = substr(s, j)
            for (k = 1; k <= nops; k++) {
                o = ops[k]
                if (substr(rest, 1, length(o) + 2) == " " o " ")
                    return substr(s, 1, j - 1) " " o " " term substr(s, j)
            }
        }
        at = at + 1
    }

    at = 1
    while (1) {
        at = findword(s, p, at)
        if (at == 0) return ""
        term = operand(s, p, at)
        if (term != "") {
            for (k = 1; k <= nops; k++) {
                o = ops[k]
                before = " " o " "
                if (at > length(before) && substr(s, at - length(before), length(before)) == before)
                    return substr(s, 1, at + length(term) - 1) " " o " " term substr(s, at + length(term))
            }
        }
        at = at + 1
    }
}

function mentions(s, p,   at, after) {
    at = 1
    while (1) {
        at = findword(s, p, at)
        if (at == 0) return 0
        after = substr(s, at + length(p), 1)
        if (after !~ /[A-Za-z0-9_]/) return 1
        at = at + 1
    }
}

END {
    n = NR
    np = split(params, p, " ")
    npoly = split(poly, pp, " ")
    done = 0

    if (klass == "E1") {
        for (i = def_start; i <= def_end && !done; i++) {
            edited = bump(line[i])
            if (edited != "") { line[i] = edited; done = 1 }
        }
    } else if (klass == "E2") {
        for (k = 1; k <= np && !done; k++)
            for (i = def_start; i <= def_end && !done; i++) {
                if (line[i] ~ /^[ \t]*--/) continue
                edited = dup(line[i], p[k])
                if (edited != "") { line[i] = edited; done = 1 }
            }
    } else if (klass == "E3" || klass == "E3poly") {
        # The body must start on its own line, or there is nothing to wrap.
        head = line[def_start]
        tail = substr(head, index(head, "=") + 1)
        gsub(/[ \t]/, "", tail)
        candidates = (klass == "E3poly") ? npoly : np
        if (candidates > 0 && index(head, "=") != 0 && tail == "" && def_end > def_start) {
            for (k = 1; k <= candidates && !done; k++) {
                cand = (klass == "E3poly") ? pp[k] : p[k]
                used = 0
                for (i = def_start; i <= def_end; i++)
                    if (index(line[i], "==") != 0 || index(line[i], "/=") != 0)
                        if (mentions(line[i], cand)) used = 1
                if (!used) { probe = cand; done = 1 }
            }
        }
    }

    if (!done) { print "skipped" > "/dev/stderr"; exit 0 }
    print "applied" > "/dev/stderr"

    for (i = 1; i <= n; i++) {
        if ((klass == "E3" || klass == "E3poly") && i == def_start + 1) { print "    always"; print "    (" }
        print line[i]
        if ((klass == "E3" || klass == "E3poly") && i == def_end) { print "    )"; print "    (" probe " == " probe ")" }
    }
}
AWK

classes="E1 E2 E3 E3poly"

# ---------------------------------------------------------------------------
# One whole-root dump. `$1` is the module name whose record to keep, `$2` the
# file to write it to. The error count goes to `$work/errors`, counted from
# the JSON diagnostics stream and never from the exit status: `beni dump`
# exits 0 on a type error, an unknown module and a parse failure alike.
# ---------------------------------------------------------------------------
# A run that FAILED TO RUN, recorded here rather than swallowed. The error
# count below is read out of `dump.err`, and an empty `dump.err` reads as
# zero errors — so a `beni` that never started scores every edit as a clean,
# interface-preserving measurement and the table comes out full of zeros in
# the `rejected` column. The status is what tells the two apart: `beni dump`
# exits 0 whatever it FOUND, so a non-zero status is the process itself
# failing and never a diagnostic.
spawn_failures="$work/spawn-failures"
: >"$spawn_failures"

dump_root() {
    status=0
    if [ -n "$core_flag" ]; then
        (cd "$work" && "$beni_abs" dump --stage=raw --core --diagnostics=json --root="$src_name" -- "$src_name" \
            >"$work/dump.out" 2>"$work/dump.err") || status=$?
    else
        (cd "$work" && "$beni_abs" dump --stage=raw --diagnostics=json --root="$src_name" -- "$src_name" \
            >"$work/dump.out" 2>"$work/dump.err") || status=$?
    fi
    if [ "$status" != 0 ]; then
        echo "bench/churn.sh: '$beni_abs dump' exited $status; the measurement below would be counted out of an empty diagnostics stream" >&2
        sed -n '1,20p' "$work/dump.err" >&2 || true
        # The sentinel, because this function is also called from inside the
        # declaration loop's pipeline subshell, where `set -e` unwinds no
        # further than that subshell and the `|| true` on its `done` would
        # swallow the status. The file outlives both.
        echo "exit $status" >>"$spawn_failures"
        return 1
    fi
    grep -o '"severity":"error"' "$work/dump.err" | wc -l >"$work/errors"
    awk -v want="$1" -f "$work/record.awk" "$work/dump.out" >"$2"
}

errors_seen() { tr -d ' \n' <"$work/errors"; }

module_name_of() {
    printf '%s' "${1%.beni}" | tr '/' '.'
}

# ---------------------------------------------------------------------------
# Drop modules the pristine root cannot resolve. A root that does not resolve
# has no baseline, so measuring against it would compare two broken records.
# ---------------------------------------------------------------------------
for m in $extra_excludes; do rm -f "$src/$m"; done
excluded=$extra_excludes
round=0
while [ "$round" -lt 20 ]; do
    round=$((round + 1))
    dump_root __none__ /dev/null
    [ "$(errors_seen)" != 0 ] || break
    blamed=$(grep -o '"file":"[^"]*"' "$work/dump.err" | sed 's/"file":"//; s/"$//' | sed "s|^$src_name/||" | sort -u)
    [ -n "$blamed" ] || break
    for m in $blamed; do
        [ -f "$src/$m" ] || continue
        rm -f "$src/$m"
        excluded="$excluded $m"
    done
done
if [ "$(errors_seen)" != 0 ]; then
    echo "bench/churn.sh: the corpus does not resolve even after dropping$excluded" >&2
    cat "$work/dump.err" >&2
    exit 1
fi

modules=$(cd "$src" && find . -name '*.beni' -print | sed 's|^\./||' | sort)
if [ -n "$only_module" ]; then modules=$only_module; fi

# The declaration loop runs on the right of a pipe and so in a subshell; it
# records one line per outcome here and the totals are counted from the log.
log="$work/outcomes"
: >"$log"

for module in $modules; do
    pristine="$work/pristine.beni"
    cp "$src/$module" "$pristine"
    mname=$(module_name_of "$module")

    dump_root "$mname" "$work/base_ann"

    decls=$(awk -f "$work/decls.awk" "$pristine")
    [ -n "$decls" ] || continue

    printf '%s\n' "$decls" | while IFS='	' read -r name ann_start ann_end def_start def_end params poly; do
        for variant in ann unann; do
            if [ "$variant" = ann ]; then
                cp "$pristine" "$src/$module"
                cp "$work/base_ann" "$work/base"
                vd_start=$def_start
                vd_end=$def_end
                base_source=$pristine
            else
                # No annotation to remove: the declaration is already
                # unannotated, so the two variants would be the same run.
                [ "$ann_start" -ne 0 ] || continue
                awk -v ann_start="$ann_start" -v ann_end="$ann_end" -v def_start="$def_start" \
                    -f "$work/unannotate.awk" "$pristine" >"$src/$module"
                removed=$((ann_end - ann_start + 1))
                vd_start=$((def_start - removed))
                vd_end=$((def_end - removed))
                dump_root "$mname" "$work/base"
                if [ "$(errors_seen)" != 0 ]; then
                    for klass in $classes; do
                        echo "  $module $name $klass unann rejected"
                    done
                    cp "$pristine" "$src/$module"
                    continue
                fi
                cp "$src/$module" "$work/variant.beni"
                base_source=$work/variant.beni
            fi

            for klass in $classes; do
                if awk -v klass="$klass" -v def_start="$vd_start" -v def_end="$vd_end" \
                    -v params="$params" -v poly="$poly" -f "$work/edit.awk" "$base_source" \
                    2>"$work/applied" >"$work/edited.beni"; then
                    applied=$(cat "$work/applied")
                else
                    echo "  $module $name $klass $variant awkfailed"
                    continue
                fi
                if [ "$applied" != applied ]; then
                    echo "  $module $name $klass $variant skipped"
                    continue
                fi
                cp "$work/edited.beni" "$src/$module"
                dump_root "$mname" "$work/after"
                if [ "$(errors_seen)" != 0 ]; then
                    echo "  $module $name $klass $variant rejected"
                elif cmp -s "$work/base" "$work/after"; then
                    echo "  $module $name $klass $variant unchanged"
                else
                    echo "  $module $name $klass $variant CHANGED"
                fi
                cp "$base_source" "$src/$module"
            done
        done
    done >>"$log" 2>&1 || true

    cp "$pristine" "$src/$module"
done

# The loop above runs in a subshell, so the counters are re-derived from the
# log, which is written for every run whether or not it is printed.
count_of() {
    n=$(grep -c " $1 $2 $3\$" "$log" 2>/dev/null || true)
    [ -n "$n" ] || n=0
    printf '%s' "$n"
}

if [ "$verbose" -eq 1 ]; then
    echo "declarations:"
    sort "$log"
    echo
fi

# Every module still in the copy is byte-identical to the one it came from.
# The excluded ones were deleted from the copy on purpose and are reported
# above, so they are not part of this claim.
restored=yes
(cd "$src" && find . -type f -print | sort | while IFS= read -r f; do
    cmp -s "$f" "$corpus_abs/$f" || exit 1
done) || restored=no

broken=$(grep -c ' awkfailed$' "$log" 2>/dev/null || true)
[ -n "$broken" ] || broken=0

# A failed spawn is a failed MEASUREMENT, and no table is printed for one:
# the numbers would be indistinguishable from a corpus that churns nothing.
if [ -s "$spawn_failures" ]; then
    echo "bench/churn.sh: the compiler failed to run $(wc -l <"$spawn_failures" | tr -d ' ') time(s); no table" >&2
    exit 1
fi

echo "corpus: $corpus"
[ -z "$excluded" ] || echo "modules excluded (the pristine root does not resolve them):$excluded"
echo "tree restored: $restored"
[ "$broken" = 0 ] || echo "edit program failed on $broken declarations"
echo
echo "edit    variant       changed/accepted  applied  skipped  rejected  decls"
echo "------  ------------  ----------------  -------  -------  --------  -----"
for klass in $classes; do
    for variant in ann unann; do
        ch=$(count_of "$klass" "$variant" CHANGED)
        un=$(count_of "$klass" "$variant" unchanged)
        sk=$(count_of "$klass" "$variant" skipped)
        rj=$(count_of "$klass" "$variant" rejected)
        accepted=$((ch + un))
        applied=$((accepted + rj))
        decls=$((applied + sk))
        label=$([ "$variant" = ann ] && echo annotated || echo unannotated)
        printf '%-6s  %-12s  %14s  %7d  %7d  %8d  %5d\n' \
            "$klass" "$label" "$ch/$accepted" "$applied" "$sk" "$rj" "$decls"
    done
done

if [ "$restored" != yes ] || [ "$broken" != 0 ]; then exit 1; fi
