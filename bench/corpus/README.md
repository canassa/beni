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

## How to add to it

- **A slow file.** When profiling (`--self-profile`) or the abuse scenarios
  find a file that is slow in any phase, copy it here verbatim with a name
  that says what it stresses (`DeepRecordUpdateChain.beni`,
  `HundredKilobyteString.beni`). Add one `--` comment line at the top saying
  where it came from and which phase it hurt. Never "fix" the file to be
  faster — that defeats the purpose.
- **A realistic module.** Translate a real Elm module (the `references/elm`
  checkout has plenty) rather than writing a toy; keep it 150–400 lines and
  valid, so `beni check bench/corpus` stays clean. Idiomatic input is what
  the `fast-compiler.md` §2 budget is stated against.
- Every file must be valid — the bench does not tolerate diagnostics, so a
  file that fails `beni check` is a bug in the file, not a benchmark.
- Do not delete files. A file that has stopped being slow is still evidence
  that it stays fast.
