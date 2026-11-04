## 2026-11-04 19:06 CET — Map hand-written JavaScript in release source maps

**What I did**

Built part 1 of #141: `beni build --release --source-maps` maps the hand-written JavaScript that `Minify` compacts back to its `.js` file. I wrote the rules first, as a dated amendment to `backend.md` §11.2 (*Hand-written JavaScript*). `Minify.print` records a mark at each token it prints, and `markNames` gives the names. `Emit.linkHoisted` makes each hand-written piece a stretch of the hoisted map with its `.js` file as a source, and keeps the link step's aliases unmapped. `produceHandWritten` writes a map beside each compacted file in the multi-file layout. A markup runtime that `rewriteProgramImports` rewrote gets its marks moved back to the file as written (`HandText.fileOffset`). Three `build_test` tests decode the maps with the test's VLQ reader and with Node's `SourceMap`, and run the crash under `--enable-source-maps`. Each new rule was checked red by a revert. Without the flag no byte moves: the gates ran no program again, and `bench/corpus`, Conduit and Sternhalma wrote master's bytes. The cost is inside the spread of five runs.

**What I learned**

- Node's `--enable-source-maps` names a frame by the mapping at the start of the enclosing function. A parameter that begins an arrow (`run=a=>…`, `map(k=>…)`) is that start. With the parameter's name there, the frames read `at program` and `at part`. So a function's first token carries the function's name, and a parameter there carries none. Part 3 (parameter names for beni code) meets the same byte in `Print`.
- A red run left the red binary in `zig-out/safe/bin/`. My next manual check read that binary and showed the old behaviour. Rebuild after `git checkout` of a revert, before any manual check.
- The only hand-written JavaScript that ships now is `core/Js.js`, `core/List.js` and `core/Record.js`; `bench/corpus`, Conduit and Sternhalma reach only `Record.js`. The `hand` test platform in `build_test` is the useful fixture.
- `backend.md` on master holds about 1 221 double-encoded section signs (`Â§`, #854, #886). An edit that copies text from the Read view copies them. Write new lines in UTF-8 and check the bytes.
- `--release --library` drops a runtime file's `import` of its runtime module but keeps the use (#1877, opened).
