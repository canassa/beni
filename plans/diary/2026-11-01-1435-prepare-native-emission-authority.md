# Prepare exact native emission authority

2026-11-01T14:35:53Z on Dagon. Part of #1295 and PR #1304.

The internal native pipeline now consumes the exact attested TextEncoder row,
original source builder, selected zero-role Program/runtime, and final Reach.
It retains deferred code separately from actual generic constant initializers.
The earlier live-native/Compact-only draft missed a retained uninvoked helper;
the exact regression now refuses, with actual Reach live and zero Compact rows.
The initial zero-constructor/launch/role/type-arity slice supplies empty Compact
rather than running another discovery pass. Broader kinds remain refused.

The ordinary public guard is still present. Internal runPrepared tests exercise
the same authority, lowering and writer, without a builtin.is_test branch.
No native runtime delivery, EntryHost, C, Worker launch or owning proof is claimed.
Prerequisite rebased to frozen consumer tree2f3e0a3d, including diagnostic reset.

Focused Debug build host-bundle-test-attempt3:88/88 steps,20/20 overall tests.
Independent retained ELF replay with BENI_TEST_BUDGET_MS=1000:13 passed (10
semantic,1 structural,2 import roots),0 skipped/failed/leaked/logged errors.
Actual runtime CLI/dev/release/cache/refusal coverage remains required.

Attempt1 failed compiling the test host fixture ExtraIndex conversion. Attempt2
found preexisting JsIr.Builder.toOwned partial-transfer leaks under allocation
failure; its ELF/log are retained. The fixture now owns temporary IR in an arena
and prints final bytes into its caller allocator; the full allocation sweep
passes. No production builder ownership algorithm was changed.

Follow-up after parent review: #1544 tracks the generic JsIr.toOwned leak.
The arena-only host workaround above is superseded and retained only as a
historical checkpoint. The final helper again uses its caller allocator for IR.
All fallible auxiliary-column transfers now have errdefer ownership before the
infallible node transfer. Builder.deinit remains valid on failure. A new actual
registered all-column allocation sweep covers this general API independently.

Pinned Zig0.17 FailingAllocator resize_fail_index=0 forces both resize/remap
fallback, eliminating backing-address-dependent allocation counts in the host
printer sweep. Normal caller-gpa success bytes are compared exactly with the
forced-fallback successful output for both host modes. Full uncapped allocation
sweeps pass; the original nondeterministic attempt and leak ELF remain retained.
Focused attempt4 passes88/88 steps,21/21 overall. Retained ELF replay passes14:
11 semantic,1 structural,2 import roots, no skips/failures/leaks; unit1000 intact.
Public runtime activation and CLI cases remain pending; drafted blackbox files
are not part of this tested internal snapshot.

The native reuse question now carries exact closed strict-Unit constructor ABI1
in Fact.where. Actual candidate schema/identity/adapter revision must match.
Parent review identified the generic false==false negative-fact trap; decoder
and direct Lower handler now reject false native questions and old/unknown ABI
codes structurally. Actual serialized rows exercise code0/1/2 with both Boolean
answers; actual table tests include no-current-native and wrong declaration.
Mutated adapter revision refuses authority. No readiness bit is persisted.

ABI attempt2 failed a fixture setup precondition (empty emitted-unit payload);
its crashed ELF/log are retained. Opaque nonempty codec bytes corrected setup.
Attempt3 passes88/88 steps,22/22 overall; standalone15 passes (12 semantic,
1 structural,2 roots), no skipped/failed/leaked/logged errors, unit1000 intact.
