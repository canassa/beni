# 2026-10-31 21:04 CET — standalone DAG limit is enforced

Dagon's actual clock was 2026-10-31 21:04:16 CET when this entry was recorded.
The full gate's tuple-DAG failure was an ownership_limit diagnostic, not an
elapsed threshold: t needs1,276,786 logical summary entries against262,144.
The unchanged accepted Debug baseline returns0 with chain-null (the old explicit
ownership-everywhere enforcement bug#1509) but returns1 with --platform=node
and exactly the same diagnostic. Baseline runs took21.99s and22.23s respectively;
these diagnostic timings are not performance acceptance.

The checked-control norm was clarified before editing tests. The original
OwnershipAnnotationDag.beni remains byte-for-byte unchanged and now has an
explicit full structured diagnostic assertion on both enforced routes. A separate
s-only pure tuple fixture retains positive repeated-path/guard coverage. No
production ownership code, annotation merging, summary codec, cap, timeout, or
budget changed. The original fixture hash remains0fe04fadc3cfcf9d9dd857d5614cd3a9150b54b7c3a4b29b17adbfdea2bd77fa.

Self-hosted Debug focused runner executes2actual named tests: smaller DAG passes,
and original large DAG's standalone/node negative passes.0skipped,0failed,
0leaked,0logged errors. Compiler8c0389516fcaec5b0062ff2ef9ea5082e4f6b50ba383ccf0ee71560d235d9968.
No full gate was rerun here; parent owns final gates. Temporary instrumentation
was considered but never applied or built, and Ownership.zig is unchanged.
