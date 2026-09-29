# bench/markup — markup-heavy modules for the lexer

`frontend.md` §9.3's lexer-only input: four modules written almost entirely
in markup, so the lexer's mode stack — tags, text runs, holes, closing
tags — is what a measurement over them measures.

| Module | Shape |
|---|---|
| `BenchmarkTable.beni` | js-framework-benchmark's table view (research 29): a keyed `For`, rows, buttons |
| `SignupForm.beni` | a form: labelled inputs, attribute strings with interpolation, a select from a list |
| `StaticPage.beni` | a page of mostly static text, with character references (research 29's static-heavy page) |
| `DeepTree.beni` | forty nested wrappers, and a recursive view of a file tree |

Nothing past the lexer reads markup yet, so the directory is measured with
the lexer alone:

```sh
zig build bench -- --corpus=bench/markup --phases=lex
```

It moves up the pipeline as the parser, the checker and a lowering learn
markup (`--phases=lex,parse`, then every phase), and joins `bench/corpus/`
only when it builds under the `node` platform — until then `bench/corpus/`
must stay buildable end to end, because `--library` builds of it are the
size benchmark (`backend.md` §9).
