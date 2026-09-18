# M4 slice zero — the serialized interface

**Status:** plan, 2026-09-18, written at `b3156c6` against `plans/m4-plan.md` and its finding 1 fix
(`792bf76`). Nothing is started. The contract lives in two documents and this one holds only what is
a plan: the byte format is [`checker.md`](../docs/design/checker.md) §7, the hash, the flags and the
acceptance test are [`fast-compiler.md`](../docs/design/fast-compiler.md) §8.

**Why this slice and no other.** `plans/m4-plan.md` leaves nine owner decisions open (D1–D9) and
this is the work that is identical under every answer to all nine: make the interface record
serializable, hash it, and prove that a build whose every interface has been through the format is
byte-identical to a cold one. §3.4 of that plan states the reason in one sentence — *until `beni
check` can consume a serialized interface, every claim about the firewall is unfalsifiable* — and
§3.1 the other half: there is no interface hash and no interface comparison anywhere in `src/`.

Measurements marked *(measured)* were taken here on the M4 plan's machine (Ryzen 9 5950X, Zig
0.16.0, ReleaseFast, throwaway worktree at `b3156c6`), corpus `zig build bench -- --generate=100000`
— 624 files, 100 159 lines, 1 835 956 bytes.

---

## 1. What slice zero is

Six commits, each green on all three gates, in the order of §5. When they land:

- `Interface` has a byte format, a writer and a reader (`checker.md` §7).
- `check`, `build` and `dump` accept a hidden `--roundtrip-interfaces`: every module's record is
  written to bytes and read back **in place** the moment its check finishes, so every dependent,
  every dump, every dispatch table and every emitted file downstream is built from a record that has
  been through the format.
- `check` accepts a hidden `--iface-hash`: one `<package>:<Module> <32 hex digits>` line per module,
  `core` and the platform included, sorted by module path.
- The whole corpus asserts cold ≡ round-tripped, at `--jobs=1` and `--jobs=8`.
- `bench/churn.sh` reports the firewall by hash instead of by dump diff.

And what it is not is `fast-compiler.md` §8's closing paragraph: no cache directory, no key, no
invalidation, no `mmap`, no daemon.

## 2. The size of the thing, estimated

Row counts of `dump --stage=raw --jobs=1` over the 100k corpus *(measured)*, times the element
widths `checker.md` §7 fixes:

| Column | Rows | Bytes/row | Bytes |
|---|---:|---:|---:|
| `terms` (3 SoA columns) | 25 316 | 9 | 227 844 |
| `extra` | 53 120 | 4 | 212 480 |
| `symbols` + `strings` | 20 619 slots, 5 259 distinct, 57 332 distinct bytes | 4 + blob | ~140 000 |
| `ctors` | 3 436 | 20 | 68 720 |
| `type_refs` | 3 636 | 12 | 43 632 |
| `values` | 2 496 | 12 | 29 952 |
| `schemes` | 2 496 | 12 | 29 952 |
| `types` | 1 499 | 16 | 23 984 |
| **Total, 624 modules** | | | **~777 kB, ~1.25 kB/module** |

Against 1 865 423 bytes of `--stage=raw` text and 1 835 956 bytes of source: the binary form is
~42 % of the printed one and ~0.42× the source. **Caveat, and it matters:** the generated corpus is
monomorphic — its raw dump has zero `q`, zero `param` and zero `where` rows *(measured)* — so this
estimate counts no quantifier block and no `where` suffix at all. A real corpus is larger and
`static-dispatch-spike.md` §6.5's suffix is the part that grows. The exact number is the slice's
first output.

## 3. The hash, measured

3 kB input, the size of one module's record, ReleaseFast *(measured)*:

| Candidate | µs / 3 kB | GB/s | Verdict |
|---|---:|---:|---|
| `std.hash.XxHash3` | 0.057 | 54.3 | 64-bit |
| `std.hash.Wyhash` | 0.105 | 29.2 | 64-bit |
| **`std.hash.SipHash128(1,3)`** | **0.492** | **6.2** | **taken** |
| `std.hash.Fnv1a_128` | 3.321 | 0.93 | byte-at-a-time |
| `std.crypto.hash.Blake3` | 4.527 | 0.68 | cryptographic, unneeded |

`SipHash128(1,3)` with an all-zero key is the only 128-bit output in `std.hash` that is not
byte-at-a-time. 634 modules × 0.49 µs = **0.31 ms** for the whole corpus, against the 15 ms warm
budget. The 64-bit candidates are 5–9× faster and the margin they save is 0.3 ms, which is not a
reason to accept a birthday probability at all.

## 4. What checking reads that is not in the record

Walked over `src/check/` and `src/resolve/`. **None of these is slice zero's work** — the round
trip happens with every module's Bir in memory — but the disposition of each is decided here so
that M4-1's sidecar does not have to be invented under time pressure, and so that nobody closes one
hole believing it closes the firewall.

| Fact a check of M reads about another module | Site | Disposition |
|---|---|---|
| Every declaration of every module, to number `TypeId` — private types included | `src/check/Types.zig:364` | **sidecar, unhashed.** Not the record: a private type is not M's public face, and adding one must not move M's hash |
| Declaring module's `(package, name)` on every `Entry` | `src/check/Types.zig:365-366` | **sidecar** (module metadata) |
| interface `TypeIndex` → `TypeId`, via `Provenance` | `src/check/Types.zig:396-404` | **sidecar column.** `Provenance` itself is never written (`Interface.zig:337-348`) |
| `equatable`/`comparable`/`has_function`, a fixpoint over every type body in the project | `src/check/Types.zig:477`, `:497-517` | **sidecar**, three bits per declared type. The DAG order makes a dependency's bits final before a dependent needs them |
| `equatable foreign type` on a **private** type | `src/check/Types.zig:501-503` | **sidecar** (it is on the record already for `pub` ones, `Interface.zig:291-295`) |
| `declaresPubCompare` — does the declaring module supply `pub compare`? | `src/check/Types.zig:591-603` | **sidecar**, one bit. It cannot come from the published scheme: `Types.build` runs before any scheme exists (`Check.zig:187` precedes `:253`) |
| `resolveRefs`' name scan over the declaring module's declarations | `src/check/Types.zig:286-312` | **sidecar**, the same table |
| Cross-module alias expansion, read from the declaring module's Bir | `src/check/Types.zig:962-982` | **into the record, hashed** — `alias_body: TermIndex?`, the slot `checker.md` §7 already names, written the way `Ctor.arg_terms` is |
| `core/Basics.eq` reached with **no import edge** | `src/check/Solve.zig:2583`, `:3348` | **implicit dependency.** `core` is an unconditional input of every module's check; the key must say so, and "did `Basics` change?" invalidates more than `graph.dependencies` |
| The well-known types, same, with no edge | `src/check/Types.zig:706-731` | same |
| Derived-row existence: `Target.ext_derived` names a function another module emits, and nothing verifies it | `src/check/Dispatch.zig:118-123`, `src/check/Solve.zig:3337-3343` | **into the record, hashed** — the set of `(kind, type)` rows the module emits. Today the two sides agree only because both compute the gate from one `Types` table |
| Derived-name sort key reads another module's name through the graph | `src/check/Check.zig:1234` | **recompute, free.** `Types.Entry.module_name` (`Types.zig:74`) is the same symbol; one line, no new data |
| `privateInOtherModule`, to say `private_method` instead of `unknown_method` | `src/check/Solve.zig:3058-3066` | **degrade.** Its own comment (`:3050-3057`) already specifies the answer when the Bir is absent |
| `whyMissing` / `owningTypeName`, to say `private_name` / `opaque_constructor` | `src/resolve/Resolve.zig:333-347`, `:355-360` | **degrade** to `unknown_import_name`, for the same reason |
| Sibling constructor sets for exhaustiveness | `src/check/Exhaustive.zig:1151-1168` | **already the record** |
| Every imported value, constructor and method-rule lookup; every "did you mean" hint | `src/check/Solve.zig:1388`, `:1409`, `:2865`; `src/check/Diagnostics.zig:891`, `:1345`, `:1932` | **already the record** |
| `Exhaustive.Context.graph` / `.artifacts` | `src/check/Exhaustive.zig:377-378` | **dead fields** — delete |

One divergence found on the way and **not** M4's to fix, logged so it is not rediscovered: a `pub
opaque type` has `ctors_start == ctors_end` in the record, so `allNullary` (`src/check/Solve.zig:2947-2970`)
answers `false` in a dependent where the declaring module answers `true`. That is a pre-existing
cross-module asymmetry in the "`eq` is `===`" decision, visible today, not caused by caching.

## 5. The ordered change list

Each step is green on `zig build test && zig build test-blackbox && zig build fmt-check` on its own.

**S0-a — finish the bounds-checked posture.** `Interface.term` (`src/resolve/Interface.zig:419`),
`scheme` (`:432`), `valueScheme` (`:471`) and `symbol` (`:477`) stop trusting their index, joining
the six accessors at `:411-467` that already do. No output moves; no fixture, because nothing can
reach an out-of-range index until S0-b exists. *First, so that every later step may be wrong about a
length without crashing the compiler* — which is what `:407-410` says the posture is for.

**S0-b — the format.** A new `src/resolve/iface_bytes.zig` with `write(gpa, iface, interner) ![]u8`
and `read(gpa, bytes, interner) !?Interface`, to `checker.md` §7. The `symbols` column becomes
offsets into a `strings` blob on write and is re-interned on read. **Reading re-interns through a
new non-mutating `InternPool.Global.find(bytes) ?Symbol`, never `getOrPut` (`src/InternPool.zig:410`),
and a miss is `internal`:** a record round-tripped inside one session can only name strings that
session already interned, and `Global` is thread-confined (`src/InternPool.zig:24-26`), so a worker
that appended to it would race. M4-1, which loads a record a previous process wrote, does that load
serially before workers start — the same rule enumeration follows (`src/Session.zig:9-10`) — and
may use `getOrPut` there. In-source tests round-trip the records the existing `Interface` and
`Schemes` tests already build. Nothing observable changes.

**S0-c — `--roundtrip-interfaces`.** A `bool` on `Cli.Common` (`src/Cli.zig:77-95`), through
`Session.Options` (`src/Session.zig:109`), honoured in `ModuleCheck.fillInterface` **between**
`writer.attach(iface)` (`src/check/Check.zig:1092`) and the `ref_ids` fill (`:1101-1103`): write the
record, read it back, replace `interfaces[m]` wholesale, then resolve refs against the new one.
Wholesale replacement is also why `Schemes.Writer.attach`'s non-idempotence
(`src/check/Schemes.zig:473-483`, `plans/m4-plan.md` §2.6) does not bite here and must not be
"fixed" by re-attaching. Absent from `--help` (`src/Cli.zig:27-64`) and from `checker.md` §2's table.

**S0-d — `--iface-hash`.** Same plumbing; printed after the check, in module-path order, over every
module including `core` and the platform. It exists because `dump --stage=raw` prints only the
modules named on the command line — 624 `module` lines for the corpus's 624 app files *(measured)*,
with core's nine records invisible — and because the firewall's quantity is the hash, not a dump.

**S0-e — the acceptance matrix.** `tests/blackbox/corpus_test.zig`: `Case.run` (`:333-355`) gains
the cross of §6 for every kind that runs the checker. This is the slice's point and the first test
in the project that asserts the firewall's premise.

**S0-f — churn by hash.** `bench/churn.sh` (`:566`, `:569`) reports "importers re-checked" from
`--iface-hash` instead of diffing `--stage=raw`, and gains edit class **E4**: add a type to a module
the observed module does not import. Expected 0, and the class that would have caught the `TypeId`
leak `792bf76` fixed.

## 6. The acceptance test

For every corpus case of every kind that runs the checker — `check_good`, `check_bad`, `check_args`,
`check_depth`, `dispatch`, `run`, `emit`, `regress` (`tests/blackbox/corpus_test.zig:54-90`) — four
runs:

```
{ plain, --roundtrip-interfaces } × { --jobs=1, --jobs=8 }
  assert equal: exit code, stdout, stderr, and every file written
  (diagnostics, --stage=raw, the .iface golden, --stage=dispatch, the emitted JavaScript)
```

The emitted JavaScript is byte-compared in the three extra runs and executed once, as today, so
`node` is not spawned four times. At 9.4 ms per small-fixture invocation *(measured, 20 runs of
`check tests/corpus/check/good/OpaqueType.beni`)* the added axis is ~20 s over ~576 cases.

This closes a gap the corpus has today and `tests/corpus/README.md:82-84` misdescribes: the corpus
runner never passes `--jobs` at all, so the determinism claim is carried entirely by the synthetic
projects of `tests/blackbox/blackbox_test.zig:457`, `:3445`, `:3569` and
`tests/blackbox/abuse_test.zig:1242`. That README line should be corrected when S0-e lands.

## 7. Fixtures, by intent

1. **The interner-order fixture — the one that fails first, and the one `--stage=raw` cannot see.**
   Project `P` = `{ src/Zeta.beni }`; project `P'` = `P` plus `src/Aardvark.beni`, an unrelated
   module full of identifiers and sorting before `Zeta`. `check --iface-hash` over both must print
   the same line for `Zeta`, at `--jobs=1` and at `--jobs=8`. Write the writer's `symbols` column as
   raw `Symbol` ids first and watch it go red — `Aardvark`'s identifiers are interned first and
   shift `Zeta`'s numbering — then write it as text. **`dump --stage=raw` is blind to this**: it
   resolves symbol indices to text before printing (`src/dump/interface.zig:113-117`).
2. **`quantified_start` and `constraints_start` survive the round trip.** Those two fields are
   exactly what `--stage=raw` does not print (`checker.md` §7), so no existing golden can see them
   lost. Run `writeRecordShapes`' 12-module project (`tests/blackbox/blackbox_test.zig:3399`) with
   `--roundtrip-interfaces` and require `--stage=raw` byte-identical, including its `  q `,
   `  param ` and `    where ` lines.
3. **Purity, by hash.** The four cumulative edits of `blackbox_test.zig:3569` — a `pub` type, a
   private type, a new file, and a type in a module `Zeta` *does* import but never names — restated
   as "`Zeta`'s hash line did not move".
4. **The converse, by hash**, so 3 is not vacuous: the three edits of `blackbox_test.zig:3675` (a
   renamed type the record names, a new constructor on an exported type, a changed local arity) must
   each move the line.
5. **A record full of `<error>` round-trips.** A project where one module publishes `err` terms
   (`Check.zig:1049-1086`) must produce identical diagnostics under `--roundtrip-interfaces` —
   `Term.Tag.err` and `SchemeIndex.none` are the two encodings nothing else exercises.
6. **Empty and never-checked records round-trip.** `Interface.empty` (`Interface.zig:384`) and a
   module that failed to lower, whose `Ctor.arg_terms` is `no_terms` (`:335`).
7. **Corrupt input, in-source (supplement, and a stated limitation).** Truncated, wrong magic,
   unknown version, a column offset past the end, a `strings` record whose length overruns the blob:
   each returns null and never traps. These cannot be black-box in slice zero because no file exists
   to corrupt; they become corpus fixtures in M4-1, when one does.

## 8. What this makes measurable, before D1–D9 are taken

1. **Interface bytes per module** on the 100k corpus — §2 estimates ~1.25 kB and says why the
   estimate is low. Also the total, which `plans/m4-plan.md` §8 lists under "could not determine".
2. **Serialize, deserialize and hash time**, per module and as `--self-profile` rows, against the
   4.68 ms whole-program serial floor (`plans/m4-plan.md` §4.3).
3. **The fraction of check time spent on imports' interfaces.** `instantiations` is already counted
   (`src/Profile.zig:13-14`) but never timed; a profile event around `Schemes.instantiate`
   (`src/check/Schemes.zig:599`) and `instantiateCtor` (`:701`) gives the number the firewall's
   value depends on.
4. **The firewall's cutoff rate, by hash**, over `bench/churn.sh`'s four edit classes plus E4 —
   report 19 §4's annotated/unannotated split, restated as "importers re-checked" instead of "bytes
   moved", which is report 19 §16's own open question.

## 9. What stays PENDING, and on which decision

| Pending | Decision |
|---|---|
| Where a record is written, what a cache entry contains, how it is named, the `stat` fast-path, `boundary.md` §7.3's sibling `.js` hash, and the "produced by a clean check" bit that keeps a broken module's `<error>` holes out of a cache (`plans/m4-plan.md` §3.2) | **D1** |
| Whether effects' two bits are reserved — taken: they are not, the `format_version` field is the mechanism, and `checker.md` §7's alignment padding is padding and not a reserved field | **D4** (taken) |
| `mmap` and therefore any commitment to host alignment and byte order; the record's own bytes are little-endian and host-independent, a cache directory is not | **D1** |
| Memory ceiling, watching, cancellation | **D7, D8, D9** |
| The sidecar of §4 — its format version, and whether the declared-type table ships beside the record or the type table is made incremental instead | **D1**, and `plans/m4-plan.md` §4.3's open item on `types` |

## 10. Risks, and what could not be determined

1. **The re-intern race is the one real hazard in the slice.** S0-b's answer — a non-mutating
   `find` on the parallel path, `getOrPut` only before workers start — is a rule, and rules erode.
   If a later change makes a round-tripped record name a string the session has not interned, the
   `internal` fires rather than the pool corrupting, which is the correct failure but is not free of
   thought.
2. **The estimate in §2 is from a monomorphic corpus.** Zero quantifier blocks and zero `where`
   suffixes were measured in it, and those are the columns static dispatch made grow.
3. **A round trip inside one session is a weaker test than a load across processes.** Symbols come
   back identical because the same interner answers, so only fixture 1's file-set axis and the
   `--jobs` axis exercise the numbering at all. The genuine cross-process test arrives with M4-1.
4. **Could not determine: what a warm rebuild costs.** Unchanged from `plans/m4-plan.md` §8 —
   slice zero makes the byte-identity assertion possible, not the timing one. The timing needs a
   cache, which is D1.

---

## 11. Measured — 2026-09-19, slice zero as landed

Ryzen 9 5950X (32 threads), Zig 0.16.0, ReleaseFast for the bench rows and the installed Debug
binary for `bench/churn.sh` and `zig build test-blackbox`. Every bench row is `zig build bench`'s
new `iface` line, best of the stated iterations after a warm-up, at `--jobs=1`. Raw output, one
line per corpus.

### 11.1 The record's size, and what the three operations cost

```
{"phase":"iface","corpus":"--generate=100000","modules":633,"bytes":980920,"bytes_per_module":1549,"min_bytes":440,"median_bytes":1512,"max_bytes":6708,"source_bytes":1919214,"write_ms":1.098,"hash_ms":0.201,"read_ms":0.636,"cold_check_ms":127.4,"roundtrip_check_ms":128.8}
{"phase":"iface","corpus":"--generate=100000 --dispatch","modules":633,"bytes":990904,"bytes_per_module":1565,"min_bytes":440,"median_bytes":1528,"max_bytes":6708,"source_bytes":1969165,"write_ms":1.136,"hash_ms":0.207,"read_ms":0.657,"cold_check_ms":136.9,"roundtrip_check_ms":136.6}
{"phase":"iface","corpus":"bench/corpus","modules":20,"bytes":69932,"bytes_per_module":3496,"min_bytes":440,"median_bytes":3068,"max_bytes":8500,"source_bytes":145742,"write_ms":0.051,"hash_ms":0.012,"read_ms":0.032,"cold_check_ms":8.6,"roundtrip_check_ms":8.9}
{"phase":"iface","corpus":"core","modules":9,"bytes":31552,"bytes_per_module":3505,"min_bytes":440,"median_bytes":3068,"max_bytes":6708,"source_bytes":83258,"write_ms":0.027,"hash_ms":0.008,"read_ms":0.017,"cold_check_ms":3.4,"roundtrip_check_ms":3.6}
{"phase":"iface","corpus":"tests/corpus/run","modules":116,"bytes":55028,"bytes_per_module":474,"min_bytes":104,"median_bytes":104,"max_bytes":6708,"source_bytes":281515,"write_ms":0.062,"hash_ms":0.018,"read_ms":0.044,"cold_check_ms":14.6,"roundtrip_check_ms":13.7}
{"phase":"iface","corpus":"tests/corpus/dispatch","modules":37,"bytes":50100,"bytes_per_module":1354,"min_bytes":196,"median_bytes":856,"max_bytes":6708,"source_bytes":121002,"write_ms":0.048,"hash_ms":0.012,"read_ms":0.032,"cold_check_ms":4.9,"roundtrip_check_ms":5.1}
```

Every row counts core's nine records, which is why `min_bytes` is 440 wherever core holds the
smallest module in the tree and why `max_bytes` is 6 708 — `core:Dict` — on four of the six.
104 bytes is a header and a column table and nothing else: the record of a module with no `pub`
declarations, which most of `tests/corpus/run` is.

**§2's estimate was 777 kB over 624 modules, ~1.25 kB each. Measured: 981 kB over 633 modules,
1 549 bytes each** — 24 % over, and §2 said which way it would be wrong and why (it counted no
quantifier block and no `where` suffix). The ratio to source is 0.51×, against the 0.42× §2
predicted, and the `--stage=raw` text of the same corpus is 1 865 423 bytes, so the binary form is
**53 %** of the printed one rather than §2's 42 %.

**The monomorphic caveat, now quantified.** The generated corpus has zero `where` rows; the
`--dispatch` generator's corpus has them, and the whole difference is **+1.0 %** (1 549 → 1 565
bytes per module). So the shape §2 warned about is real but small at this corpus's polymorphism.
The two corpora that are not generated are the ones that differ, at 3 496 and 3 505 bytes per
module — 2.3× the generated figure, because a generated module has one `pub` value and a written
one has thirty.

**Time.** Over the 100k corpus, 633 modules: write 1.098 ms, hash 0.201 ms, read 0.636 ms —
1.73 µs, 0.32 µs and 1.00 µs per module. The hash runs at 4.9 GB/s over 981 kB, against §3's
6.2 GB/s at a 3 kB input, and costs 0.201 ms for the whole project against the 15 ms warm budget.
§3's claim holds.

### 11.2 What fraction of a check a warm build would replace

`read_ms` against `cold_check_ms` is the number `plans/m4-plan.md` §8 could not determine:

| Corpus | cold check | read every record | fraction |
|---|---:|---:|---:|
| `--generate=100000` | 127.4 ms | 0.636 ms | **0.50 %** |
| `--generate=100000 --dispatch` | 136.9 ms | 0.657 ms | 0.48 % |
| `bench/corpus` | 8.6 ms | 0.032 ms | 0.37 % |
| `core` | 3.4 ms | 0.017 ms | 0.50 % |

**A warm build that loaded every record instead of computing it would spend half a percent of a
cold check's time on the loading.** That is the firewall's ceiling stated as a number, and it is
the first time it has been one. It is a CEILING and not a prediction: it excludes reading the
files, hashing the sources and the sidecar of §4, none of which exist yet, and it assumes a 100 %
cutoff rate, which §11.3 measures and which is not 100 %.

`--roundtrip-interfaces` costs **+1.1 %** of a cold check on the 100k corpus (127.4 → 128.8 ms)
and is inside the noise on the four small ones — which is what a flag doing a write, a read and a
free per module should cost, and is why the acceptance matrix's price is process startup and not
the format.

### 11.3 The firewall, by hash — `bench/churn.sh`

`bench/churn.sh` now takes `check --iface-hash` instead of a `--stage=raw` byte-diff, so it
reports two things per edit: whether the OBSERVED module's own hash moved (`changed/accepted`,
the old question) and how many OTHER modules' hashes moved (`others`, the new one).

```
corpus: bench/corpus
modules excluded (the pristine root does not resolve them): JsonCodecs.beni NotesApp.beni

edit    variant       changed/accepted  applied  skipped  rejected  decls  edits w/ others  others
------  ------------  ----------------  -------  -------  --------  -----  ---------------  ------
E1      annotated               0/20       20       83         0    103                0       0
E1      unannotated             0/19       25       78         6    103                0       0
E2      annotated                0/1        2      101         1    103                0       0
E2      unannotated              0/1        8       95         7    103                0       0
E3      annotated               0/70       84       19        14    103                0       0
E3      unannotated            29/68       85       18        17    103                0       0
E3poly  annotated                0/0        5       98         5    103                0       0
E3poly  unannotated              4/4       11       92         7    103                0       0

E4: a private type added to one module — modules whose interface hash moved
Counter, Data/Parser, Data/Token, DictExtra, ExprParser, FormValidation,
PrettyPrinter, Router, Ui/View — 0 of 18, every one.
E4 worst case: 0 modules moved (expected 0)
```

```
corpus: core

edit    variant       changed/accepted  applied  skipped  rejected  decls  edits w/ others  others
------  ------------  ----------------  -------  -------  --------  -----  ---------------  ------
E1      annotated               0/15       15      125         0    140                0       0
E1      unannotated             0/15       15      125         0    140                0       0
E2      annotated                0/7        8      132         1    140                0       0
E2      unannotated              0/7        8      132         1    140                0       0
E3      annotated               0/74      107       33        33    140                0       0
E3      unannotated            50/90      107       33        17    140                0       0
E3poly  annotated                0/0       15      125        15    140                0       0
E3poly  unannotated            12/12       15      125         3    140                0       0

E4: Basics, Char, Debug, Dict, List, Maybe, Result, Set, String — 0 of 9, every one.
E4 worst case: 0 modules moved (expected 0)
```

**Three findings.**

1. **E4 is 0 everywhere, on both corpora.** A private type added to a module moves no module's
   interface hash at all — not even the edited module's own, which is the stricter claim and the
   one the `TypeId` leak of `plans/m4-plan.md` §2.2 broke. It is not a blind zero: the same edit
   written `pub` instead of private moves exactly one line, the edited module's own, and no other
   (checked by hand for `app:Counter` and for `core:Basics`). This is the firewall's first real
   measurement and the row `fast-compiler.md` §8 asked for.

2. **`others` is 0 on every one of the 366 accepted edits.** When an interface DID move, no second
   module's interface moved with it: the wave stops at one record. That is not "no importer is
   re-checked" — an importer of a changed module still has to be re-checked — it is the stronger
   and more useful fact that the re-check does not then propagate. A cutoff at depth one is what
   makes the firewall worth having, and this is the first evidence for it.

3. **Report 19 §4's annotated rows were 0 by dump-diff. They are 0 by hash too** — every
   `annotated` row above is `0/n`, on both corpora, over E1, E2, E3 and E3poly alike. The hash is
   strictly more sensitive than the dump on the two fields `--stage=raw` does not print
   (`Scheme.quantified_start`, `Quantified.constraints_start`) and on the `symbols` column's
   identity, so this is a confirmation and not the same measurement twice. The unannotated rows
   are unchanged as well: 29/68 and 4/4 on `bench/corpus`, 50/90 and 12/12 on `core`, which is
   `plans/state-of-the-compiler.md` §7's split — an annotation is what makes a body edit safe —
   restated in the quantity a cache will use.

### 11.4 What the acceptance matrix cost

336 fixtures × four runs, over `check_good`, `check_bad`, `check_args`, `check_depth`,
`dispatch`, `run`, `emit` and `regress`. `zig build test-blackbox` went from **86.4 s to 111.8 s,
+25.4 s (+29 %)**. The spec estimated ~20 s from a measured 9.4 ms per small-fixture invocation;
the installed Debug binary on this machine costs ~101 ms per `check` and ~113 ms per `build`, so
the honest serial figure is ~240 s of work. What keeps it at 25 s is that the matrix is its own
test binary — `zig build test-blackbox` runs its binaries concurrently — and that it spreads its
own fixtures over eight workers. No fixture and no kind was dropped to get there; what is
deliberately not in the cross is the `--release` half of a `run/` fixture, which is downstream of
the record exactly as the development build already is.
