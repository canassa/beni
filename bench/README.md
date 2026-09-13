# bench — measured numbers

`fast-compiler.md` §12: the budget is tracked as a visible trend, not a gate.
This file is the trend. **Newest entry first**, each dated, each naming the
machine it was taken on, because a number without a machine is not a number.

How to reproduce an entry:

```sh
direnv exec . zig build -Doptimize=ReleaseFast
direnv exec . zig build bench -- --generate=100000     # writes .zig-cache/bench-gen
time ./zig-out/bin/beni check --jobs=1 .zig-cache/bench-gen
```

Wall times are **best of 5** on an otherwise idle machine. Check the load
average first: an early draft of the M1d table was taken while another build
was saturating the four cores and read 784 ms where the real number was
51 ms — a 15× error that looked entirely plausible.

---

## 2026-09-13 — M1d (parallel driver, formatter on the workers)

**Machine:** Intel N100, 4 cores / 4 threads, 6 MiB L3, single memory
channel, 16 GB RAM, Linux 7.2, Zig 0.16.0, ReleaseFast.
**Corpus:** `bench/gen.zig --generate=100000` — 627 files, 100 073 lines,
1 825 939 bytes, 300 416 tokens, 221 471 AST nodes. `beni check` on it is
clean (zero diagnostics).

### Wall time by worker count

| command | `--jobs=1` | `--jobs=2` | `--jobs=4` | default (4) | speedup at 4 |
|---|---:|---:|---:|---:|---:|
| `check` | 51 ms | 31 ms | 25 ms | 25 ms | **2.1×** |
| `fmt --check` | 57 ms | 35 ms | 26 ms | 26 ms | **2.2×** |

`beni version` — the empty run — is 2 ms, so ~8 % of the `--jobs=4` wall
time is process start and exit. `--jobs` is capped at four times the CPU
count: `--jobs=20000` on one six-byte file used to spend 7.6 s building
twenty thousand arenas, interners and threads.

### Where the time goes (`--self-profile`, same corpus)

| | `check` j=1 | `check` j=4 | `fmt --check` j=1 | `fmt --check` j=4 |
|---|---:|---:|---:|---:|
| profiled span | 48.3 ms | 19.1 ms | 55.1 ms | 20.4 ms |
| total worker CPU | 47.8 ms | 65.5 ms | 54.6 ms | 71.4 ms |
| `read` | 5.0 | 7.0 | 4.9 | 6.5 |
| `lex` | 14.9 | 19.4 | 14.6 | 18.9 |
| `parse` | 11.2 | 16.1 | 11.4 | 16.8 |
| `lower` | 14.2 | 20.4 | — | — |
| `format` | — | — | 21.2 | 26.8 |
| `enumerate` + `merge_interners` + `render` (serial) | 2.6 | 2.6 | 2.5 | 2.4 |

Worker busy time at `--jobs=4` is 18.6 / 15.8 / 15.7 / 15.4 ms for `check`
and 20.0 / 17.3 / 17.2 / 17.0 ms for `fmt`: the work-stealing counter
balances the four queues to within 20 %, so nothing is waiting on a straggler.

### Why 2.1×, and not 4×

The serial part is not the limit. It is 2.6 ms — enumerate, the interner
merge and the render — against 48 ms of per-file work, so Amdahl alone would
predict 48/4 + 2.6 = 14.6 ms at four workers, not the 19.1 ms measured.

The gap is that **the same per-file work costs 37 % more CPU when four
workers do it** (47.8 → 65.5 ms). Every phase inflates, including `read`
(+40 %), which is a syscall and a memcpy and contends on nothing of ours.
That points at the machine, and the machine says so directly: **four
independent single-threaded `beni check` processes** over the same corpus
take **67-74 ms** wall against **51 ms** for one alone — an aggregate of
2.8-3.0×, not 4× (`fmt --check`: 78-81 ms against 57 ms, so 2.8-2.9×).
This is an N100: four Alder Lake-N E-cores sharing 6 MiB of L3 and one DDR
channel, and a front end that streams 1.8 MB of source into tens of
megabytes of token, tree and BIR arrays is memory-bound long before it is
core-bound.

Against that ~2.9× ceiling the driver gets 48.3/19.1 = **2.5×, or ~86 % of
what the machine will give**; for `fmt` it is 55.1/20.4 = 2.7×, or **~93 %**.
What remains is the 2.6 ms serial tail and ~5 ms of process start and
teardown outside the profiled span. Nothing in the driver is worth changing
for this workload on this machine; the numbers to re-take on a machine with
more memory bandwidth are the ones in the first table.

### `fmt` on the workers

Formatting was serial until M1d: `fmt --check` ran the parse phases in
parallel and then formatted every file on the main thread. It is now a
per-file worker phase (`Session.format_phases`) writing into a session-owned
buffer per file, and the command walks the files in index order afterwards
to compare, write and print — so the listing and the bytes are a function of
the sorted path list alone. `format` is 39 % of the per-file work at
`--jobs=1`, which is what the speedup reflects.

Measured effect at four workers: **34 ms → 26 ms**. At `--jobs=1` it is
50 ms before and 57 ms after — the same work plus one copy of each file's
canonical text into a session-owned buffer, which is what buys the
parallelism, and what the `formatted_bytes` counter now reports
(1 856 438 bytes for this corpus).

### Abuse inputs (`tests/blackbox/abuse_test.zig`)

`beni check --diagnostics=json`, best of 3, peak RSS from
`getrusage(RUSAGE_CHILDREN)` around the run. Every one of these exits
normally — none is a signal, a hang, or a partial write.

| input | diagnostics | exit | time | peak RSS |
|---|---:|---:|---:|---:|
| 10 MB one-line list literal (valid) | 0 | 0 | **500 ms** | **228 MB** |
| 10 MB one-line string literal | 0 | 0 | 64 ms | 22 MB |
| 10 MB file that is one identifier | 1 | 1 | 39 ms | 31 MB |
| 100 000 nested parentheses | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lists | 1 | 1 | 9 ms | 13 MB |
| 100 000 nested lambdas `\x -> \x -> …` | 4096 | 1 | 19 ms | 19 MB |
| 8 000-link `1 + 1 + …` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r.a.a.a…` chain | 1 | 1 | 3 ms | 13 MB |
| 8 000-link `r????…` chain | 1 | 1 | 3 ms | 13 MB |
| 200 000 blank lines | 0 | 0 | 2 ms | 13 MB |
| every byte value 0–255 | 162 | 1 | 2 ms | 14 MB |
| mixed CRLF / LF / bare CR | 3 | 1 | 1 ms | 13 MB |
| unterminated string / char / interpolation at EOF | 1 / 1 / 2 | 1 | 1 ms | 13 MB |
| unterminated `(` / `[` / `{` at EOF | 2 each | 1 | 1 ms | 13 MB |
| a file that is only `--\|` | 1 | 1 | 1 ms | 13 MB |
| a file that is only `\` | 1 | 1 | 1 ms | 13 MB |
| 1 MB `--` comment line | 0 | 0 | 3 ms | 13 MB |
| `(x as)` with no name | 1 | 1 | 1 ms | 13 MB |
| empty directory | 0 | 0 | 1 ms | 13 MB |
| 5 000 empty modules, `--jobs=1` | 0 | 0 | 32 ms | 19 MB |
| 5 000 empty modules, default jobs | 0 | 0 | 19 ms | 19 MB |
| directory with a non-`.beni` file and a hidden subdirectory | 0 | 0 | 1 ms | 13 MB |
| `.hidden.beni` named explicitly | 2 | 1 | 1 ms | 13 MB |
| symlink loop `dir/loop -> ..` | 0 | 0 | 1 ms | 13 MB |
| the same file twice on the command line | 1 | 1 | 1 ms | 13 MB |

The 13 MB floor is the empty process. Only one input is over 200 ms — the
10 MB list literal, which is 3.5 M tokens and 3.5 M nodes of *valid*
program, at 22 bytes of front-end memory per source byte. It is the
`--pathological=big-list` generator case.

**No diagnostics cap is needed.** The 100 000 nested lambdas were the
candidate — every parameter but the first shadows the one outside it — and
they produce 4096 diagnostics, not 100 000, because the parser's nesting
limit stops the parse first. Peak RSS is 19 MB, three orders of magnitude
under the 2 GB bar. A cap would only ever fire on input the nesting guard
has already bounded, and it would cost every honest run a counter.

### Per-phase throughput, single-threaded (`zig build bench`)

```
{"phase":"read","files":627,"bytes":1825939,"ms":2.1,"mb_per_s":815.9}
{"phase":"lex","files":627,"bytes":1825939,"tokens":300416,"ms":9.7,"mb_per_s":180.4}
{"phase":"parse","files":627,"nodes":221471,"ms":6.2,"mb_per_s":280.6}
{"phase":"lower","files":627,"insts":205562,"ms":8.8,"mb_per_s":198.4}
{"phase":"total","files":627,"ms":26.8,"mb_per_s":65.1}
```

These are warm best-of-5 per-phase numbers with everything preallocated, so
they are lower than the cold `check` above (48 ms) by design: `check` reads,
allocates and keeps every artifact once.
