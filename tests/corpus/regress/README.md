# regress

Fixtures named after bugs (`Shadowing2.beni`, `TailRecursion_ListAny.beni`).
Each carries either an `X.diag` (it must fail, exactly so) or an `X.ast` (it
must parse, exactly so); the walker picks the behaviour from which golden
exists, and a fixture with neither is a failure.

A fixture under a `core/` subdirectory here is run with `--core` (`foreign`
declarations legal, language.md §5.4); its goldens sit next to it.
