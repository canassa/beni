# Schema release size recovery — #1859

Base: `46ea0f6676` from `workers-hostfree`. Measured compiler source:
`e790d951d`; final fixture-only edits make the positive array-length fold explicit.
Node 24.19.0 on dagon (Ryzen 9 5950X).

## Changes

- Correct `Number.isFinite`, `Number.isInteger` and `Number.isSafeInteger` to pure in the native catalogue and regenerate Data.beni. Carry these non-coercing operations through JsIr so literal arguments fold. `Array.isArray` remains impure: a revoked proxy may throw.
- Refine repeated comparisons between a uniquely declared immutable local and the same held object inside a branch. Copy the affected branch before applying context-specific facts, then solve the copied graph before using per-node facts. Generic nested optional payload checks remain.
- Fold an unmodified, unescaped array allocation's known length; retain dynamic or mutated arrays and element effects. Recognise a small return inside a sole unlabelled block.

Generic representation specialisation is deferred to #1865 by the manager. This is a partial fix; #1859 remains open.

## Per-golden sizes

Brotli quality 11, gzip level 9 secondary. Before means the **actual output of the base compiler**, not an inherited committed snapshot. Each compiler built the same fixture source through the normal corpus harness. Both emit captures completed successfully.

Existing outputs: 23 changed JavaScript goldens, -1640 brotli bytes in total. None grows after brotli. New regression fixtures are excluded from that sum.

Only SchemaReaderTest, SchemaSharedValidators and SchemaWorkerFusion had base output equal to their committed golden. Those three are refreshed. Every inherited mismatch stays red.

| Golden under `tests/corpus/emit/release/` | Before B | After B | Delta B | Disposition |
|---|---:|---:|---:|---|
| app/CaseAcrossClosure.js | 2146 | 2051 | -95 | inherited; unchanged golden |
| app/PayloadReassign.js | 1577 | 1491 | -86 | inherited; unchanged golden |
| app/PayloadUnreadField.js | 932 | 824 | -108 | inherited; unchanged golden |
| app/SchemaDeadTags.js | 881 | 769 | -112 | inherited; unchanged golden |
| app/SchemaDeadTagsShapes.js | 1600 | 1506 | -94 | inherited; unchanged golden |
| app/SchemaReaderTest.js | 1103 | 1007 | -96 | refreshed |
| app/SchemaSharedValidators.js | 1270 | 1170 | -100 | refreshed |
| app/SchemaWorkerFusion.js | 861 | 752 | -109 | refreshed |
| app/ShapeRecordNames/_expected.js | 985 | 976 | -9 | inherited; unchanged golden |
| app/ShapeThresholdAt.js | 1655 | 1572 | -83 | inherited; unchanged golden |
| app/ShapeThresholdBelow.js | 1280 | 1164 | -116 | inherited; unchanged golden |
| app/ValidatorFused.js | 1010 | 893 | -117 | inherited; unchanged golden |
| app/ValidatorNoPath.js | 900 | 771 | -129 | inherited; unchanged golden |
| app/ValidatorRun.js | 841 | 737 | -104 | inherited; unchanged golden |
| app/ValidatorRunsApart.js | 1341 | 1227 | -114 | inherited; unchanged golden |
| app/ValidatorWorker.js | 885 | 776 | -109 | inherited; unchanged golden |
| core/NumberPredicates.js | 130 | 100 | -30 | new fixture |
| core/OptHeldGuard.js | 122 | 117 | -5 | new fixture |
| dedicated/WorkerEventsLeaf/_expected.js | 9849 | 9841 | -8 | inherited; unchanged golden |
| dedicated/WorkerEventsLeaf/_expected.worker-entry.js | 6263 | 6263 | 0 | inherited; unchanged golden |
| inline/ShapeConstantBuilt/_expected.js | 1660 | 1653 | -7 | inherited; unchanged golden |
| inline/ShapeConstants/_expected.js | 2348 | 2330 | -18 | inherited; unchanged golden |
| inline/ShapeLoader/_expected.js | 2356 | 2351 | -5 | inherited; unchanged golden |
| inline/SnapshotFromTable/_expected.js | 2360 | 2352 | -8 | inherited; unchanged golden |
| prerender/HydratingMount.js | 1746 | 1733 | -13 | inherited; unchanged golden |
| core/ArrayLengthFacts.js | 114 | 111 | -3 | new fixture |

The before-fix compiler emits different code for each new shape fixture. The runtime fixtures exercise non-coercion, first-class predicate calls, absence versus `some(none)`, different slots, mutation and element effects.

## Paired runtime measurements

Unmodified `bench/schema-library/run.mjs`, 15 interleaved samples of 20 ms per cell, CPU 8, two before/after pairs under the shared gates lock. All answers were checked by the driver. All four runs exit 0. Medians below are nanoseconds per operation; raw JSON also records each IQR.

- Pair 1 load averages (before / after): `2.74 2.32 2.91` / `2.36 2.27 2.86`.
- Pair 2 load averages (before / after): `1.74 2.12 2.79` / `2.05 2.15 2.76`.

| Operation | Pair 1 before → after ns | Change | Pair 2 before → after ns | Change |
|---|---:|---:|---:|---:|
| JSON.parse flat (floor) | 511 → 520 | 1.8% | 501 → 500 | -0.2% |
| parse flat valid | 1477 → 1503 | 1.8% | 1487 → 1473 | -0.9% |
| read flat valid (no JSON.parse) | 805 → 757 | -6.0% | 788 → 767 | -2.7% |
| parse flat wrong_type | 1137 → 1177 | 3.5% | 1141 → 1129 | -1.1% |
| parse flat missing_key | 1005 → 1039 | 3.4% | 1007 → 1002 | -0.5% |
| parse flat unknown_key (Reject, AllErrors) | 1665 → 1679 | 0.8% | 1635 → 1615 | -1.2% |
| JSON.parse list (floor) | 445238 → 446105 | 0.2% | 438018 → 437980 | -0.0% |
| parse list valid | 1149701 → 1194964 | 3.9% | 1143964 → 1133852 | -0.9% |
| decode flat (typed to typed) | 591 → 583 | -1.4% | 581 → 585 | 0.7% |
| JSON.stringify flat (floor) | 506 → 516 | 2.0% | 505 → 506 | 0.2% |
| print flat valid | 1530 → 1557 | 1.8% | 1523 → 1522 | -0.1% |
| JSON.stringify list (floor) | 478001 → 496547 | 3.9% | 476143 → 472753 | -0.7% |
| print list valid | 1241966 → 1283224 | 3.3% | 1228409 → 1222398 | -0.5% |
| specialised parse flat valid | 841 → 861 | 2.4% | 848 → 859 | 1.3% |
| specialised parse flat wrong_type | 865 → 883 | 2.1% | 853 → 861 | 0.9% |
| specialised parse flat missing_key | 768 → 800 | 4.2% | 770 → 782 | 1.6% |
| specialised parse flat unknown_key (Reject, AllErrors) | 993 → 996 | 0.3% | 965 → 944 | -2.2% |
| specialised parse list valid | 473451 → 477363 | 0.8% | 471928 → 467398 | -1.0% |
| specialised print flat valid | 833 → 830 | -0.4% | 812 → 808 | -0.5% |
| specialised print list valid | 507154 → 509106 | 0.4% | 512457 → 509774 | -0.5% |

Specialised flat valid parsing measures +2.4%/+1.3%, and missing-key parsing +4.2%/+1.6%; specialised flat printing measures −0.4%/−0.5%. **The owner judged these parse deltas noise and instructed the lane to skip per-change isolation and proceed.** These measurements do not close #1814; its final HostFree integration re-measurement remains due.

## Validation and evidence

The three focused corpus fixtures pass in development and release. Native generation byte-exact checks and generated skill API checks pass. Full gates ran once under the shared lock after the focused checks. Base and final both report `271/284 steps succeeded (9 failed); 2208/2234 tests passed (16 skipped, 10 failed)`. The normalized failure comparison has **zero added cases and zero added failed tests**: 160 baseline failing corpus cases versus 159 final cases. `run/CancelManyWaitersDeferred` passed in the final run; this is not claimed as a fix. Inherited emit, checker, ownership, browser and formatting failures remain.

Raw evidence is saved on dagon at `~/worktree-evidence/wd-schema-size/`: before/after emit trees, per-golden raw/gzip/brotli data, paired benchmark JSON with IQRs, focused checks, native checks and full baseline/final gates logs.
