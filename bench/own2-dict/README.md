# own2-dict

Micro-benchmarks for the data-oriented work on the ownership checker v2
(`src/own2/`). Neither is a gate; nothing in `zig build` runs them.

- `bench.zig` replays the **real dictionary operations** of the checker against
  three layouts: the crit-bit `Ids.FixedDict` as it is, an open-addressing
  index of entry indices over dense key arrays, and a chain per key 0 (a dense
  id). It prints nanoseconds per operation, best of five.
- `soa.zig` times four ways to read a `MultiArrayList` column against a plain
  slice, for the node shape of `Shape.Table`.

## Record a trace

The counters are a hidden build option. Off, they are compiled away. Build a
compiler with them and a directory for the traces, then dump a module:

```sh
mkdir -p /abs/path/traces
zig build -Downership-v2-counters -Downership-v2-trace=/abs/path/traces \
    --prefix /abs/path/counted
/abs/path/counted/bin/beni dump --stage=ownership --ownership=v2 --jobs=1 \
    tests/corpus/ownership/FoldCertificate.beni
```

The dump ends with the counters and the census (`src/own2/Counters.zig` lists
them). The directory gets one file per table-resident dictionary, named for its
field path and key width: `shapes.memo_proj.k2`, `cells.sets.intern.k4`. A
file is `u32` records, a tag (0 a get, 1 a put) and the key's words. Run with
`--jobs=1`, and one module at a time: a later module's tables overwrite the
files of an earlier one. `gates` refuses the options.

## Run the replay

```sh
zig build-exe -OReleaseFast bench.zig -femit-bin=/abs/path/own2-dict
/abs/path/own2-dict /abs/path/traces/shapes.memo_proj.k2 \
    /abs/path/traces/cells.sets.intern.k4
```

Add `-fno-llvm` to build with the self-hosted backend, which the gates and the
test budget run on. The two backends disagree by a factor of ten and more on
this code, so quote both. Each line reads

```text
shapes.memo_proj.k2   ops=85730   max_key0=10513   critbit=47.0ns/op   open-addr=9.6ns/op   by-key0=5.1ns/op
```

A layout that does not fit a key says nothing: where key 0 is a kind or a flag
(`shapes.intern`), the by-key0 chains are as long as the table. An open-addressing
number is a lower bound on what a full replacement costs, since the benchmark
leaves out the account and the callers.

## Column reads

```sh
zig build-exe -OReleaseFast soa.zig -femit-bin=/abs/path/soa && /abs/path/soa
zig build-exe -OReleaseFast -fno-llvm soa.zig -femit-bin=/abs/path/soa && /abs/path/soa
```
