# Robustness audit by experiment — the formatter and the error paths

2026-09-19, against `master` at `0a0d017`, on a 32-thread machine with 31 GB.

Two surfaces had never been audited by experiment. The **formatter** rewrites
the user's files in place, so a formatter that changes a program's meaning,
drops a comment, or is not idempotent is a data-loss bug and not a cosmetic
one. The **error paths** are what M4's daemon and M5's LSP will drive all day
with half-typed files, and a compiler that panics, hangs or says `internal` on a
typo is broken for exactly the user who most needs a good message.

Method, in one line each: format everything twice and compare it against itself
and against its own AST; then mutate every corpus file that checks clean, tens
of thousands of times, and require a diagnostic rather than a crash.

**Result: the two surfaces held.** 613 files formatted, 86 900 mutants, and not
one idempotence failure, meaning change, lost comment, panic, hang, `internal`
diagnostic or bad span. The four defects below were all found beside the fuzz —
three by asking what an in-place write does to a file that is not an ordinary
private regular file, and one by reading the exit-code contract.

---

## Defects

Reproductions are out of tree, under the session scratchpad at
`robust/defects/<n>-<slug>/`, each with its input, a `command.sh`, the captured
`observed.txt` and a `README.md` arguing the expected behaviour.

| # | Severity | What |
|---|---|---|
| 1 | high | `beni check .` (and `fmt .`, `build .`) rejects every file with `invalid_module_path` |
| 2 | medium | `beni dump` exits 0 while printing an `error`-severity diagnostic |
| 3 | medium | `beni fmt` resets a rewritten file's mode to 0644 — `0600` becomes world-readable, `0444` is rewritten anyway |
| 4 | medium | `beni fmt` replaces a symlink with a regular file and leaves the target unformatted |

**1 — `.` is not a usable path.** `beni check .` from inside a project exits 1
with `invalid_module_path` on every file, pointing at the user's source for a
fault the driver introduced; `fmt --check .` and `build .` fail the same way and
`--root` does not help. The same directory named any other way — `$PWD`,
`../proj`, a relative subdirectory name — exits 0, and so does naming the file
(`check ./Aa.beni`). `frontend.md` §1 says the root is the directory argument,
and `language.md` §1 says the module name is the path **relative to the source
root**, which for `.` and `./Aa.beni` is `Aa.beni` → the module `Aa`. The walk
appears to join root and entry without normalising, leaving a `.` segment.
`fmt` is the sharpest case: §1 says formatting "is per file and resolves
nothing", so it has no business deriving a module name at all. No test anywhere
passes `.` as a path — `grep -rn '"\."' tests/blackbox/*.zig` is empty.

**2 — `dump` is silently successful.** Every one of the eight stages prints a
full error diagnostic on stderr and exits **0**: an unclosed delimiter, a
dangling `--|`, an invalid UTF-8 byte, a resolution error through
`--stage=interface`. `check` on the same file exits 1. `frontend.md` §1 and
`beni help` both state "`0` no errors, `1` at least one `error`-severity
diagnostic" for the binary, with no `dump` carve-out; `src/main.zig:6-15` says
the behaviour is deliberate, because "a dump of a broken file is still a dump".
That is a coherent position but it lives only in a source comment, so this is a
document/code disagreement and `CLAUDE.md` rule 1 says the document wins until
someone moves it. Either §1 and `beni help` gain the exception, or `runDump`
returns 1.

**3 — the formatter loses the file mode.** A file the formatter *changes* comes
back `0644` whatever it was: `600 → 644`, `640 → 644`, `700 → 644`, `755 → 644`,
`444 → 644`. A file it leaves alone keeps its mode, which localises this to the
rewrite path. Two consequences beyond tidiness: a source file the user made
private is world-readable after a format, and a `0444` file is rewritten at all
— the user's write protection is neither honoured nor reported.

**4 — the formatter destroys symlinks.** `beni fmt Link.beni` on a symlink reads
through the link, formats the text, and writes a **new regular file** over the
link. The link is gone, the real module still holds the old text, and `fmt`
exits 0. Formatting the directory afterwards finds the target still unformatted,
so the two disagree for as long as nobody looks.

3 and 4 are one mechanism — write to a temp file, `rename` over the destination.
`rename` takes the temp's `0666 & ~umask` mode with it and replaces a link
rather than following it. `fstat`ing the destination first and `fchmod`ing the
temp to match fixes both. `abuse_test.zig` pins that the *walk* does not follow
a symlink loop; nothing pins what an in-place write does to a link it is handed.

**Not defects**, recorded so the next audit does not re-derive them: a UTF-8
BOM is `invalid_character` at 1:1, a tab is `tab_in_source`, and a string inside
an interpolation is refused — three good diagnostics for three plausible
real-world inputs. `--platform` is refused with exit 2 on
`--stage=tokens|ast|bir`, which is documented; a fuzz harness that passes it
uniformly silently tests nothing on those stages, as mine did for one run.

---

## Part A — the formatter differential

**Corpus**: every `.beni` under `core/`, `platforms/`, `bench/` and `tests/` —
687 files. For each, four claims.

| | count |
|---|---|
| files | 687 |
| refused by `fmt` (68 `parse/bad`, 4 `bench/pathological`, 2 `check/depth`) | 74 |
| formatted | 613 |
| **`fmt(fmt(x)) == fmt(x)`** byte for byte | 613 / 613 |
| **`ast(fmt(x)) == ast(x)`**, import blocks sorted | 613 / 613 |
| **every comment of `x` in `fmt(x)`, in order, text intact** | 613 / 613 |
| `build(fmt(x))` emits byte-identical JS to `build(x)` (`run/`, `emit/`, `regress/`, dev mode) | 146 / 147 |

The one file not built is `regress/LetSiblingShadowedByLambdaParam.beni`, which
exits 1 on a `shadowing` diagnostic by design.

The comment check compares the `-- comments` trailer of `dump --stage=tokens`,
which carries every comment with its kind and text; six files differ on exactly
one comment each, and always the same way — `--|x` gains a space to become
`--| x`, which is what `fmt/DocNoSpace` exists to pin.

**What was already covered.** `tests/blackbox/corpus_test.zig`'s `format()`
already checks the fixed point and the AST equality, with the same
import-sorting normalisation this harness reuses — but **only for the 48
fixtures under `tests/corpus/fmt/`**. Nothing else in the repository is
differentially formatted, so the other 565 files had never been through it.

One documentation correction: `tests/corpus/README.md` says the `fmt/` kind
checks "`parse(fmt(s))` equals `parse(s)` modulo positions, **with the same
comments in the same order**". It does not. The AST dump carries doc comments as
`(doc "…")` and drops plain `--` comments entirely, so `format()` compares
everything except the comments. A lost plain comment would show only as a
golden diff at bless time. The mechanical check exists now — in this harness,
not in the suite — and the README sentence should either be softened or the
check moved into `format()`.

**Fixed points.** 111 tracked `.beni` files are not `beni fmt` fixed points.
Excluded by purpose: the 39 `fmt/` inputs (the kind's whole point is unformatted
input — the 9 `AlreadyCanonical*` fixtures are the fixed points) and the 27
under `parse/`, which exercise layout the formatter is meant to normalise. That
leaves **45** that could be formatted and are not:

- `check/depth/` (7) and `check/good/DeepInferredScheme` — deep generated
  shapes, 600–4 100 changed lines each; formatting them would bloat them.
- `run/` (26), `emit/app/` (2), `bir/` (2), `check/good/` (2),
  `check/bad/CycleDense/E`, `bench/runtime/` (4). Most are a **one-line** diff,
  and almost all of those are a blank line before `else` that §9 removes. The
  largest are `run/ReleaseNameCollision` (192) and `run/EvidenceCapture` (14).

Not reformatted here: it is churn across 45 goldens and belongs in a slice of
its own, but a repository whose fixtures are `beni fmt` fixed points is a
standing proof the formatter has not regressed, and it is nearly true already.

**Adversarial layout**, 16 hand-written inputs, each through all four claims:
comments in every position the grammar allows (trailing on an import, between an
annotation and its definition, inside tuples, records and lists, before `else`,
between `case` branches, after a `<-` bind, between `where` constraints, on
every declaration kind's doc block); CRLF with comments; a missing final
newline; a BOM; tabs; astral characters and a ZWJ sequence in strings and
comments; a 300-character string; a 40-argument call; a 30-field record; 200
nested parens, lists and tuples; a 60-term pipeline; leading operators;
`f (-1)` against `f - 1`; an empty file; a file of only comments; a file of only
blank lines. **13 passed all four claims; 3 were refused with a good
diagnostic** (BOM, tab, string-inside-interpolation).

Two numbers worth keeping. The formatter never broke a string literal, however
long. And `fits` measures **bytes**, as `language.md` §1 says a column does, so
a fourteen-emoji list that is 118 bytes and about 90 display cells wide goes
vertical — deliberate, now pinned by a fixture rather than assumed.

## Part B — mutation fuzz

**Seeds**: the 316 `.beni` files under `tests/corpus/`, `core/` and
`platforms/` (of 666) that `check` accepts with an empty stderr; whether a seed
needs `--platform=node` is discovered, not listed (149 do).

**Mutants**: eleven operators applied round-robin by index, so every seed gets
every kind — delete, duplicate, swap or insert a token from a vocabulary of beni
punctuation and keywords; truncate at a random byte; replace a byte with any of
256; re-indent one line by ±1..8 columns; delete or duplicate a line; delete or
insert a byte span. Truncations and byte edits land mid-UTF-8, mid-string and
mid-comment. Every mutant is a pure function of (seed path, index).

Each run is capped at 20 s and `ulimit -v 12000000`, and classified: exit 0, or
exit 1 with at least one well-formed diagnostic whose span lies inside the file,
is FINE. A signal, the timeout, the cap, an exit code outside {0,1}, a
diagnostic coded `internal`, an empty diagnostic list on exit 1, unparsable JSON
under `--diagnostics=json`, or a span outside the file or with end before start
is a finding.

| campaign | mutants | runs | findings |
|---|---|---|---|
| `check`, 1 mutation, 33/seed (calibration) | 10 428 | 10 428 | 0 |
| `check`, 1 mutation, 110/seed | 34 760 | 49 825 | 0 |
| `check`, **3 stacked** mutations, 55/seed | 17 380 | 20 462 | 0 |
| `fmt` in place, 44/seed | 13 904 | 13 904 | 0 |
| `dump --stage=tokens\|ast\|bir`, 33/seed | 10 428 | 31 284 | 1 (not reproducible) |
| **total** | **86 900** | **125 903** | **0 confirmed** |

The shape of the outcomes says the campaigns were doing work rather than
bouncing off no-ops: of the 110/seed `check` run, 19 695 mutants were diagnosed,
15 065 still checked clean, and only 1 190 were textually identical to their
seed. Stacking three mutations pushes further off the valid manifold, as
intended: 14 298 diagnosed against 3 082 still clean.

**Two parsers agreeing.** Every mutant `check` accepted was then handed to
`fmt`; a file one parser accepts and the other refuses is a disagreement. Across
18 147 accepted mutants, **zero** disagreements.

**A refused format is inert.** In the `fmt` campaign 6 359 of 13 904 mutants
were refused, and in every case the input file was byte-identical afterwards. In
place is the default (`beni fmt X.beni` writes), `--check` reports and writes
nothing, `--stdout` prints and refuses more than one file with exit 2, an
unreadable file is exit 2 with `cannot read '…': AccessDenied`, and `fmt` over
several files where one is bad formats the good ones and exits 1.

**The one dump finding** is a SIGKILL on `--stage=ast` for a mutant of
`check/depth/TypeParensOk.beni`, and it is an artefact of the harness, not the
compiler. It appeared 17, 15, 1 and 0 times across four runs of the same
campaign, never reproduced standalone or at 28-way parallelism on that seed
alone, and vanished when the cap was raised from 4 GB to 12 GB. The reason it
sits near a cap at all: `dump --stage=ast` on an 8 KB file of 2 000 nested
parentheses peaks at **≈2.1 GB of virtual address space** (the 64 MiB dump
thread stack plus arena reservations) for **30 MB resident**, and writes a
16.8 MB dump. Under `ulimit -v 2000000` it fails cleanly with exit 2. Nothing to
fix; a number M4's resident daemon may want.

---

## What was added to the tree

**Five `fmt/` fixtures**, for adversarial layout that behaves correctly and was
not covered:

- `UnicodeWidth` — astral characters and a ZWJ sequence in a string and in a
  comment; the byte-versus-cell width decision made visible by a list that fits
  in cells and not in bytes; a string literal past the limit printed unbroken.
- `CommentsBetweenAndInside` — the comment positions `CommentsUgly` does not
  reach: trailing on an import, between an annotation and its definition, on a
  `type alias` doc block, inside a tuple, inside a record, after a `<-` bind.
- `OperatorsAtLineStart` — the mirror of `OperatorsAtLineEnd`, with a comment
  between two operands of a chain and of a pipeline.
- `NegationVsBinaryMinus` — `f (-1)` against `f - 1` against `f x - 1` against
  `f (-1) (-2) -3`, the one rewrite that would silently change a program.
- `OnlyComments` — a file that is nothing but comments, where every byte of the
  file is the thing that could be dropped.

**`tests/fuzz.mjs`** (183 lines), the fuzzer above: self-contained, needs only
the pinned Node, discovers its own seeds, deterministic in (seed, index).
**It is not wired into any gate** — a useful campaign is minutes, and
`test-blackbox` must stay fast. Run it by hand when the lexer, parser, layout or
formatter changes:

```sh
zig build
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz check 110   # ~9 min, 32 threads
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz fmt    44
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz dump   33
FUZZ_STACK=3 node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz check 55
```

It exits 1 with one JSON line per finding, naming the seed and the index, and
`mutate(readFile(seed), rng(hash(seed) ^ (k+1)*0x9e3779b1), k % 11)` regenerates
that exact mutant.

The formatter differential harness stayed in the scratchpad
(`robust/fmtdiff.mjs`, `robust/jsdiff.mjs`): its claims are the ones
`corpus_test.zig`'s `format()` already makes, and the right home for the two it
adds — the comment comparison and the emitted-JS identity — is that function,
not a second tool.

## What `abuse_test.zig` already pins

Read first, and it is more than it looks: 28 tests covering 10 MB single-line
literals, 100 000 nested parentheses, lists and lambdas stopping at exactly one
`nesting_too_deep`, the three left-deep spines, 200 000 blank lines, **a file of
every byte value 0–255**, mixed CRLF/LF/bare CR, every unterminated construct at
EOF, a lone `--|`, a 1 MB comment, an empty directory, 5 000 empty modules, the
same file twice on the command line, a trailing slash, hidden files, a symlink
loop in the walk, a 200-constructor `case`, deeply nested constructor patterns,
a pathological expression **emitted** without a stack overflow, 600 modules at
every worker count, and the inferred-constraint cap.

What it does not reach, and this audit did: anything about the formatter beyond
`fmt/`'s 48 fixtures; anything about a file's mode, a symlink handed directly to
`fmt`, or `.` as a path; and the combinatorial middle ground between a valid
program and a hostile one, which is where a daemon and an LSP actually live.

## How to re-run the whole audit

```sh
zig build
# Part A, ~13 s: idempotence, AST equality, comment preservation over every .beni
node <scratch>/fmtdiff.mjs "$PWD/zig-out/bin/beni" <work> $(find core platforms bench tests -name '*.beni' | sort)
# Part A, stronger, ~3 s: build(fmt(x)) == build(x), byte for byte
node <scratch>/jsdiff.mjs  "$PWD/zig-out/bin/beni" <work> $(find tests/corpus/run tests/corpus/emit tests/corpus/regress -maxdepth 2 -name '*.beni' | sort)
# Part B, ~13 min for all four campaigns
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz check 110
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz fmt 44
node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz dump 33
FUZZ_STACK=3 node tests/fuzz.mjs ./zig-out/bin/beni /tmp/fuzz check 55
```

## Owed

1. Defects 1, 3 and 4 are behaviour changes with an obvious right answer and
   each wants a black-box test: `check .` from inside a project, and the mode
   and the symlink after an in-place `fmt`. None can be a corpus fixture — the
   corpus walker always names fixtures by an absolute temp path — so they belong
   in `tests/blackbox/abuse_test.zig`.
2. Defect 2 is a decision, not a fix: `frontend.md` §1 gains the `dump`
   exception, or `runDump` returns 1.
3. `tests/corpus/README.md`'s claim that the `fmt/` kind compares comments is
   not true today. Move the comparison into `corpus_test.zig`'s `format()` —
   it is the `dump --stage=tokens` trailer, and this audit shows it passes on
   all 613 formattable files — or soften the sentence.
4. The 45 fixtures that are not `beni fmt` fixed points, as a slice of its own.
