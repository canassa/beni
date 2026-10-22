## 2026-10-22 03:22 CEST — Colour record field names

**What I did**

Resumed #662 after dagon's filesystem recovered. Specified and implemented
release field colouring: one spelling per source text, distinct within every
co-occurring set, with unknown rows conservative and boundary/plain names kept.
Captured record sets independently of field-value type keys, persisted canonical
rows in type-key section v2, and supplemented them with RepKeys, all modules'
BIR, schema plans and emitted object props/spreads. Added a disjoint-record
golden and runtime coverage for rows, schema shapes/updates, nested records,
copy/comparison and opaque Js.Value round trips, plus cache round-trip and
warm-output assertions. The golden failed with the old allocator restored.
Reviewed all 25 changed existing release goldens with a property-token check.

The new capture exposed a quadratic insertion sort on the existing wide-record
tests (#666). Replaced the shared helper with the standard stable text sort;
kept all facts, fixtures and budgets. Removed temporary diagnostics. Updated
onto origin/master 86e2edc65. The whole wide-test file, test-run-hashes and
self-hosted zig build gates passed on dagon. No LLVM, local Zig, output-size
measurements or speed benchmarks. Inspected #659's slot-3 integration; schema
plans supply its field sets and its field-name leaf still uses the same table.
#655's threshold decision is unchanged.

**What I learned**

RepKeys alone omits open rows and rows with polymorphic/host-valued fields.
A row's labels do not need closed value types. Cache facts need canonical text
ordering independent of store allocation order. Compiler-created markup props
can spread outside BIR record updates, and shape copies need plan facts even
when no JsIr object literal exists. Field sets encode cliques without quadratic
edge storage. The runtime fixture retains actual field reads, both row types
share a spelling for their disjoint fields, and comparison keeps source order.
