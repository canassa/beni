# bench/corpus — the permanent pathological set

`zig build bench` runs every front-end phase (lex, parse, lower, format) over
every `.beni` file in this directory and prints one JSON line per phase
(`frontend.md` §5). This directory is **checked in and grows forever**: the
synthetic 100k-LOC corpus from `bench/gen.zig` is generated into the build
cache and never committed; this one is the real-shaped set the throughput
numbers are stated against, and it is where every slow file ever found is
frozen.

## What is here

Realistic modules of 150–400 lines, each written the way an application
module is written, valid under `docs/design/language.md`:

| File | Shape |
|---|---|
| `NotesApp.beni` | Model/Msg/update/view with undo history, search and tags |
| `JsonCodecs.beni` | decoders and encoders for a nested order domain |
| `DictExtra.beni` | Dict/Set utilities: grouping, counting, merging, ordered views |
| `ExprParser.beni` | tokenizer + precedence-climbing parser + evaluator + printer |
| `Router.beni` | URL routing: parse, print, breadcrumbs, guards |
| `PrettyPrinter.beni` | Wadler-style document algebra and a JSON printer on it |
| `FormValidation.beni` | accumulating validation, combinators, a sign-up form |
| `Counter.beni`, `Data/Parser.beni`, `Data/Token.beni`, `Ui/View.beni` | the skeleton's own small real-shaped modules |

Module names come from the path (`language.md` §1): `Data/Parser.beni` is
`Data.Parser`, so every segment is `UpperCamel` and subdirectories are
module paths, not categories.

## `pathological/` — the inputs that hurt

`bench/pathological/` (a sibling of this directory, deliberately outside it so
`beni check bench/corpus` stays clean) is the frozen abuse set: every input from the
black-box abuse scenarios (`tests/blackbox/abuse_test.zig`) that either took
more than 200 ms in ReleaseFast or exposed a bug. `zig build bench` prints
**one JSON line per file** for everything under it, so a single slow file
cannot hide inside a corpus average:

```
{"file":"bench/pathological/PlusChain8000.beni","bytes":32412,"lines":8,
 "tokens":16004,"nodes":8193,"insts":12286,
 "read_ms":0.02,"lex_ms":0.31,"parse_ms":0.24,"lower_ms":0.76,"ms":1.33}
```

| File | Why it is here |
|---|---|
| `PlusChain8000.beni` | an 8000-link `1 + 1 + …` chain — segfaulted `check` at 6000 links and `dump --stage=ast` at 4000 before M1d bounded the parser's iterative spines |
| `AccessChain8000.beni` | an 8000-link `r.a.a.a…` chain — the second iterative spine, same crash |
| `QuestionChain8000.beni` | an 8000-link `r????…` chain — the third |
| `AsWithoutName.beni` | `(x as)` with no name after `as` — panicked lowering in Debug and silently bound a variable called `main` in ReleaseFast |

**Two things about this directory are deliberate and slightly awkward.**
First, its files have diagnostics *on purpose*: three of them are what
`nesting_too_deep` looks like and one is a syntax error, so the rule "every
file in `bench/corpus` must be valid" does not apply here — check the rest
with `beni check bench/corpus/*.beni bench/corpus/Data bench/corpus/Ui`.
Second, `pathological` is not an upper identifier, so these files have no
module name and `beni check bench/corpus` reports `invalid_module_path` for
each of them; the bench does not care (it lowers with the name it is given),
and the lowercase name marks the directory as not-a-module-tree.

**Too big to check in.** Anything over 256 KB is a generator case instead,
so the repository does not carry ten megabytes of `1, 1, 1, …` forever:

```sh
zig build bench -- --pathological=big-list       # 10 MB one-line list literal, VALID
zig build bench -- --pathological=big-string     # 10 MB one-line string
zig build bench -- --pathological=big-ident      # 10 MB single identifier
zig build bench -- --pathological=deep-lambdas   # 100 000 nested `\x ->`
```

Each writes one file under `.zig-cache/bench-pathological` and measures it
with the same per-file line. `big-list` is the only input that is over
200 ms (500 ms, 228 MB peak); the other three are the same shapes one size
down, kept so the next regression has something to be measured against.

**Shapes that are not files.** Two of the abuse cases are project shapes
rather than sources and so cannot live here: a directory of 5 000 empty
modules, and a symlink loop (`dir/loop -> ..`, which used to kill the whole
run with the OS's `SymLinkLoop`). Both are black-box scenarios in
`tests/blackbox/abuse_test.zig`; see `SourceStore.walk` for why the walk
skips symlinks.

## How to add to it

- **A slow file.** When profiling (`--self-profile`) or the abuse scenarios
  find a file that is slow in any phase — the bar is 200 ms in ReleaseFast —
  or a file that exposed a bug, copy it into `pathological/` verbatim with a
  name that says what it stresses (`DeepRecordUpdateChain.beni`,
  `HundredKilobyteString.beni`). Add a `--` comment block at the top saying
  where it came from, which phase it hurt, and what it broke. Over 256 KB it
  becomes a `--pathological=<name>` case in `bench/gen.zig` instead. Never
  "fix" the file to be faster — that defeats the purpose.
- **A realistic module.** Translate a real Elm module (the `references/elm`
  checkout has plenty) rather than writing a toy; keep it 150–400 lines and
  valid, so `beni check bench/corpus` stays clean. Idiomatic input is what
  the `fast-compiler.md` §2 budget is stated against.
- Every file must be valid — the bench does not tolerate diagnostics, so a
  file that fails `beni check` is a bug in the file, not a benchmark. The
  one exception is `pathological/`, above, where the diagnostic IS the
  behaviour being frozen.
- Do not delete files. A file that has stopped being slow is still evidence
  that it stays fast.
