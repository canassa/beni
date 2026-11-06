# Workers harvest

Tracking: #1612. Source range: `f0db9633deadf55baed6bb4dd07b7e04272815eb` to `4c326adfe263868a770da617cfd8a07dccbf6773`.

Lines are additions/deletions in the complete source-range numstat (binary entries show `-/-`). A keep row imports only the named contract hunks; other hunks in a mixed file are dropped or assigned below. Current master remains the base.

## Separate fixes

| Issue | Original commit | Files | Disposition |
|---|---|---|---|
| #1509 | 47b2ff1119 | src/own2/Enforce.zig; tests/blackbox/check_test.zig | Standalone enforcement and its DAG-limit finding go to the fixes lane. |
| #1337 | d61f2d338a | src/js/Emit.zig; tests/blackbox/platform_test.zig | Nominal Program identity check and shadowing test excluded here. |
| #1338 | d61f2d338a | src/js/Spec.zig; src/js/Emit.zig; tests/corpus/browser/prerender/RendererEntryRoot/ | Indexed renderer exports and their fixture excluded here. |
| #1378 | 67f7e61a97 | platforms/browser-inline/zig/inline.zig; browser/inline and emit/inline StringClass fixtures | Confirmed master defect, tracked by #1378; fixes lane owns it. |
| #1539 | 6bb3f0f7ea | src/Session.zig; tests/blackbox/devloop_test.zig | Resident diagnostics repair excluded here. |
| #1544 | deb1b262bd | src/js/JsIr.zig | Allocation-failure cleanup excluded here. |
| #1551 | deb1b262bd | docs/design/ownership-checker.md | Ledger marker repair excluded here. |

## Phase 2 extraction decision

`src/js/Emit.zig`'s selected-entry extraction (`EmitPack`, `EmitPackRecord`, `entry/Selection`, commit `6bb3f0f7ea`) is **drop** for this base. Lane A will need independent per-entry state for projection and bootstrap, so the manager should assess that refactor then. Its existing proof/control consumers are excluded; this is not a request to port them.


## bench

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `bench/bench.zig` | 23/0 | drop | Outside the approved fresh-base scope; no port. |

## root

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `build.zig` | 170/8 | keep | Explicit native-bindings/test-native-bindings steps only; remain outside gates under the owner directive. |

## core

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `core/Js/Buffer.beni` | 27/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |

## docs

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `docs/design/backend.md` | 24/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/boundary.md` | 26/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/browser-inline.md` | 180/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/checker-v2.md` | 20/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/frontend.md` | 20/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/jsir-dynamic-import.md` | 13/0 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `docs/design/language.md` | 9/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/ownership-checker.md` | 17/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `docs/design/ownership-v2.md` | 8/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/prerender-specialiser-roots.md` | 34/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/research/48-effect-parity-ledger.md` | 19/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/research/workers-api-research.md` | 401/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers-host-and-wire.md` | 206/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers-realm-options.md` | 404/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/binding-surface-counts.json` | 33/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/compat.json` | 62/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/compatibility.md` | 777/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/emission-evidence.json` | 42/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/host-access-classified-counts.json` | 80/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/host-access-classified.csv` | 2857/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/host-access-counts.json` | 51/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/host-accesses.csv` | 2857/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/inline-upcasts.csv` | 33/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/realm-options-migration.csv` | 727/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/sources.json` | 14/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/spec-sources.json` | 339/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/structured-types.json` | 324/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/structured-types.md` | 52/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/webref-idl-3.86.0.tgz` | -/- | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/research/workers/worker-surface.idl` | 729/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/schema.md` | 11/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/transparent-effects-proposal.md` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/webgpu.md` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `docs/design/workers-api.md` | 885/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-callback-contracts.md` | 97/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-canonical-index.md` | 116/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-checked-control-bodies.md` | 722/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-continuation-plan.md` | 304/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-cross-artifact-cursor.md` | 367/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-declaration-heads.md` | 39/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-emission.md` | 161/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-entry-compact.md` | 780/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-entry-implementation.md` | 121/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-entry-role-transfers.md` | 58/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-example.md` | 278/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-inspection-section-order.md` | 9/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-bindings.md` | 141/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |
| `docs/design/workers-native-callable-constructor.md` | 262/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-emission-authority.md` | 364/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-realm-builder.md` | 236/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-realm-component.md` | 316/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-realm-consumer.md` | 323/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-native-receiver-getter.md` | 91/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-nominal-layouts.md` | 239/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-selected-emission.md` | 135/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-solved-representations.md` | 55/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-typed-entry-roots.md` | 422/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers-typed-runtime.md` | 272/0 | drop | Agent-written specification for dropped proof/native/typed-buffer machinery; phase work follows #1612. |
| `docs/design/workers.md` | 813/0 | keep | Ratified worker contract or its pinned research; redirect links to dropped specifications to #1612. |

## plans

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `plans/diary/2026-10-30-0227-browser-worker-design.md` | 35/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-0335-worker-design-revision.md` | 44/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-1115-worker-design-round-three.md` | 43/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-1126-worker-reference-anchor.md` | 14/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-1453-worker-callback-contracts-and-owner-brief.md` | 54/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-1532-apply-worker-owner-decisions.md` | 57/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-1607-worker-implementation-blockers.md` | 47/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-2038-worker-compiler-foundations.md` | 51/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-2147-preserve-buffer-make-argument-evaluation.md` | 21/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-2156-generate-static-ui-measurements.md` | 19/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-2220-lower-string-class-attributes.md` | 18/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-30-2344-complete-handler-tail-facts.md` | 33/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0026-preserve-symbolic-worker-metadata.md` | 25/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0035-bound-complete-tail-probes.md` | 38/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0111-omit-unused-tail-probe-analyses.md` | 19/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0136-meter-tail-setup-and-preserve-routes.md` | 41/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0215-integrate-validated-worker-metadata.md` | 34/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-0330-compact-entry-kernel-review-corrections.md` | 47/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1048-validate-complete-handler-facts.md` | 27/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1058-preflight-typed-entry-inspection.md` | 27/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1102-merge-upstream-ownership-checks.md` | 22/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1125-reject-aliased-suspending-runtimes.md` | 32/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1153-private-nominal-layout-foundation.md` | 78/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1234-validate-compact-typed-entry-evidence.md` | 42/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1336-discard-dependency-tainted-worker-evidence.md` | 28/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1458-validate-private-nominal-layouts.md` | 69/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1554-owned-cross-artifact-type-cursor.md` | 40/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1603-strengthen-imported-layout-test-authority.md` | 20/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-1920-checked-control-body-foundation.md` | 179/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-2103-validate-cross-artifact-cursor-budgets.md` | 51/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-2104-standalone-dag-limit-is-enforced.md` | 22/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-2124-profile-the-ordinary-generated-batch.md` | 25/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-2219-generated-controls-enforce-ordinary-ownership.md` | 36/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-10-31-2352-separate-selected-entry-emission-state.md` | 66/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-0048-attest-native-constructor-candidate.md` | 50/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1047-check-bound-control-input.md` | 11/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1157-realm-source-capture-foundation.md` | 58/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1207-compose-native-source-and-bound-control.md` | 43/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1215-specify-source-realm-builder.md` | 11/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1237-validate-integrated-worker-foundations.md` | 38/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1251-build-source-realm-origins.md` | 13/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1322-select-native-realm-execution-evidence.md` | 15/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1411-corpus-test-resident-diagnostics.md` | 11/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1435-prepare-native-emission-authority.md` | 57/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1530-execute-checked-native-constructor.md` | 58/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1604-validate-selected-realm-and-resident-diagnostics.md` | 36/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1627-integrate-upstream-worker-foundations.md` | 17/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1637-reconcile-upstream-write-accounting.md` | 22/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1652-review-native-constructor-emission.md` | 28/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1710-own-anchored-role-transfer-evidence.md` | 21/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1818-publish-ordinary-solved-provenance.md` | 13/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1852-integrate-owned-entry-proof-inputs.md` | 33/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1900-validate-combined-inspection-boundaries.md` | 29/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1920-workers-upstream-sanitiser-integration.md` | 13/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-1935-native-encoding-getter.md` | 17/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-2131-workers-canonical-types-native-getter.md` | 19/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-implicit-native-receiver-coverage.md` | 7/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/diary/2026-11-01-native-implicit-receiver-and-totality.md` | 9/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/workers-implementation.md` | 150/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |
| `plans/workers-ui-validation.md` | 56/0 | drop | Old branch diary, implementation plan or evidence receipts; preserve in origin history, use #1612 delivery plan. |

## platforms

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `platforms/browser-inline/zig/inline.zig` | 34/9 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |

## skills

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `skills/beni/SKILL.md` | 2/0 | keep | Platform-author entry runtime documentation; exclude buffer and hidden inspector guidance. |
| `skills/beni/references/api-core.md` | 7/0 | drop | Outside the approved fresh-base scope; no port. |
| `skills/beni/references/entry-runtimes.md` | 26/0 | keep | Platform-author entry runtime documentation; exclude buffer and hidden inspector guidance. |
| `skills/beni/references/markup.md` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `skills/beni/references/platforms.md` | 1/1 | keep | Platform-author entry runtime documentation; exclude buffer and hidden inspector guidance. |

## src

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `src/Cli.zig` | 39/2 | drop | Outside the approved fresh-base scope; no port. |
| `src/Profile.zig` | 55/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/Session.zig` | 236/10 | keep | Entry plan lifetime and manifest module roots only; #1539 separate, all evidence plumbing dropped. |
| `src/SourceStore.zig` | 74/1 | drop | Outside the approved fresh-base scope; no port. |
| `src/beni.zig` | 54/0 | keep | Entry metadata/runtime contract only; omit generated buffer assets and all proof imports. |
| `src/build/Command.zig` | 2/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/cache/Entry.zig` | 31/5 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/cache/Key.zig` | 5/1 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/cache/NominalLayoutBytes.zig` | 183/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/cache/SolvedRepresentationBytes.zig` | 186/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/cache/dispatch_bytes.zig` | 355/5 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/cache/realm_source_bytes.zig` | 212/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/AnnotationReadings.zig` | 104/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/CanonicalIndex.zig` | 290/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/CanonicalIndexTest.zig` | 216/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Check.zig` | 37/1 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Command.zig` | 140/7 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Context.zig` | 2/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/ContinuationPlan.zig` | 612/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/ControlBuild.zig` | 303/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/ControlProof.zig` | 429/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/ControlSourcePlan.zig` | 406/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/CtorTypes.zig` | 41/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Dispatch.zig` | 16/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Dot.zig` | 7/1 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Driver.zig` | 30/3 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Effects.zig` | 11/3 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/EntryRoots.zig` | 310/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/GeneratedUnit.zig` | 297/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Incremental.zig` | 20/4 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Instantiate.zig` | 1/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Module.zig` | 191/1 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/NominalLayouts.zig` | 250/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/PrivateTerms.zig` | 236/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Publish.zig` | 5/20 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/RealmBuild.zig` | 490/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/RealmBuildTest.zig` | 717/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/RealmRecord.zig` | 157/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/RealmSource.zig` | 492/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/RealmValues.zig` | 223/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Realms.zig` | 298/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Schemes.zig` | 105/2 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/ScopedTerms.zig` | 118/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/SolvedCoverage.zig` | 97/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/SolvedRepresentationBuild.zig` | 138/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/SolvedRepresentationTest.zig` | 62/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/SolvedRepresentations.zig` | 129/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/TypeRead.zig` | 58/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/TypeStore.zig` | 21/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/Types.zig` | 35/48 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/constrain/Decl.zig` | 3/1 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/constrain/Expr.zig` | 18/2 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/constrain/Tree.zig` | 1/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/check/rules_test.zig` | 24/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/core_assets.zig` | 35/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/core_pack_main.zig` | 19/93 | drop | Outside the approved fresh-base scope; no port. |
| `src/diagnostic.zig` | 6/0 | keep | Entry metadata/runtime contract only; omit generated buffer assets and all proof imports. |
| `src/dump/checked_controls.zig` | 217/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/dump/continuations.zig` | 33/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/dump/entries.zig` | 1065/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/dump/writes.zig` | 37/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/Compact.zig` | 253/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactBuild.zig` | 776/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactDiscover.zig` | 414/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactEvidence.zig` | 138/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactEvidenceTest.zig` | 174/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactExports.zig` | 99/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactGraph.zig` | 226/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactLive.zig` | 71/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactShapes.zig` | 150/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CompactSolve.zig` | 1323/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/CursorInspect.zig` | 234/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/NominalInspect.zig` | 37/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/Plan.zig` | 160/0 | keep | Entry metadata/runtime contract only; omit generated buffer assets and all proof imports. |
| `src/entry/RealmConsume.zig` | 362/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/RealmInspect.zig` | 141/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/RoleInspect.zig` | 148/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/RolePairTest.zig` | 178/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/RoleRoots.zig` | 240/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/Selection.zig` | 40/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/SolvedInspect.zig` | 77/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/TypeCursor.zig` | 461/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/TypedInspect.zig` | 140/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry/ViewKernel.zig` | 80/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `src/entry_fixture_main.zig` | 49/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/Emit.zig` | 1257/582 | keep | Generic runtime validation/emission and a2ab6b6e35 alias fix only; #1337/#1338 separate; selected-entry extraction deferred. |
| `src/js/EmitPack.zig` | 52/2 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/EmitPackRecord.zig` | 102/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/JsIntrinsic.zig` | 23/2 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/JsIr.zig` | 67/8 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `src/js/Lower.zig` | 87/4 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/Manifest.zig` | 69/0 | keep | Entry metadata/runtime contract only; omit generated buffer assets and all proof imports. |
| `src/js/Opt.zig` | 5/5 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `src/js/Print.zig` | 95/1 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `src/js/Reach.zig` | 4/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/js/Spec.zig` | 21/6 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `src/js/Suspend.zig` | 2/2 | lane A may need it | ec03f09fc4 dynamic-import expression and effect/printer support: compiler-emitted bootstrap loading (workers.md §7); do not port here. #1338/#1544 fixes in mixed files remain separate. |
| `src/main.zig` | 61/1 | drop | Outside the approved fresh-base scope; no port. |
| `src/native/Bindings.zig` | 131/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Emission.zig` | 272/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Exposure.zig` | 152/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Generate.zig` | 342/0 | keep | Import catalogue-only d61f2d338a stage; exclude callable candidate and realm dependencies. |
| `src/native/HostFixture.zig` | 169/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Idl.zig` | 410/0 | keep | Import catalogue-only d61f2d338a stage; exclude callable candidate and realm dependencies. |
| `src/native/PackFixture.zig` | 84/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Receiver.zig` | 192/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/Source.zig` | 56/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native/TextEncoder.binding.zon` | 185/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/native_host_fixture.zig` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `src/own2/Enforce.zig` | 1/2 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `src/platform.zig` | 23/7 | keep | Entry metadata/runtime contract only; omit generated buffer assets and all proof imports. |
| `src/resolve/Graph.zig` | 2/1 | drop | Outside the approved fresh-base scope; no port. |
| `src/static_ui_main.zig` | 386/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/typed_buffer_main.zig` | 97/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `src/writes/Writes.zig` | 632/50 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |

## tests

| Path | Lines +/− | Class | Reason |
|---|---:|---|---|
| `tests/blackbox/check_test.zig` | 29/1 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/blackbox/checked_controls_test.zig` | 776/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/continuation_test.zig` | 1346/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/devloop_test.zig` | 90/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/blackbox/entry_discovery_test.zig` | 936/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/entry_roles.zig` | 259/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/entry_solved.zig` | 213/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/native_callable_test.zig` | 145/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/native_emission_test.zig` | 395/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/native_realm_consumer_test.zig` | 266/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/native_realms_test.zig` | 158/0 | drop | Unused discovery, control, realm or evidence machinery; re-derive only when delivery consumes it. |
| `tests/blackbox/nominal_layouts_test.zig` | 695/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/platform_test.zig` | 688/0 | keep | Runtime behaviour, metadata diagnostics and alias/suspension cases; omit shadowing, complete-tail and inspector tests. |
| `tests/blackbox/role_transfer_test.zig` | 164/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/run-hashes.txt` | 15/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/session_api_test.zig` | 28/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/solved_representations_test.zig` | 422/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/blackbox/typed_buffer_test.zig` | 150/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/blackbox/typed_entry_roots_test.zig` | 584/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/browser/inline/StringClass.beni` | 41/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/inline/StringClass.expected` | 62/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/inline/StringClass.run-hash` | 2/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/inline/StringClass.steps` | 6/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/inline/StringClass.v2.unchecked` | 3/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/RendererEntryRoot/Main.beni` | 15/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/RendererEntryRoot/_expected.expected` | 4/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/RendererEntryRoot/_expected.run-hash` | 4/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/RendererEntryRoot/_expected.steps` | 0/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/RendererEntryRoot/_expected/index.html` | 10/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/Main.beni` | 44/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/_expected.expected` | 67/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/_expected.run-hash` | 4/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/_expected.steps` | 5/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/_expected/index.html` | 11/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/beni.json` | 1/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/browser/prerender/StringClass/shell.html` | 11/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/build/bad/inline/StringClassList/Main.beni` | 11/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/build/bad/inline/StringClassList/_expected.diag` | 1/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/build/bad/inline/StringClassSvg/Main.beni` | 11/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/build/bad/inline/StringClassSvg/_expected.diag` | 1/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/check/bad/JsBufferOutsidePlatform.beni` | 7/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/check/bad/JsBufferOutsidePlatform.diag` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/check/bad/core/TypedBufferForEachSuspends.beni` | 22/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/check/bad/core/TypedBufferForEachSuspends.diag` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/emit/core/TypedBuffer.beni` | 22/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/emit/core/TypedBuffer.js` | 22/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/emit/inline/StringClass.beni` | 41/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/emit/inline/StringClass.js` | 41/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/emit/release/inline/StringClass.beni` | 41/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/emit/release/inline/StringClass.js` | 1/0 | separate-PR | Master defect; issue and original commit are listed in Separate fixes. Omit worker-specific hunks. |
| `tests/corpus/entry/role-transfers/Main.beni` | 55/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/entry/role-transfers/README.md` | 3/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/entry/role-transfers/error.expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/run/TypedBuffer/Main.beni` | 10/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBuffer/_expected.expected` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBuffer/_expected.run-hash` | 2/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBuffer/beni.json` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBuffer/platform/BufferProbe.beni` | 93/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBuffer/platform/beni.json` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/Main.beni` | 7/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/_expected.expected` | 7/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/_expected.run-hash` | 2/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/_expected.v2.unchecked` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/beni.json` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/platform/Probe.beni` | 59/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/run/TypedBufferMakeArgument/platform/beni.json` | 1/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/corpus/session/diagnostic-wave/README.md` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/session/diagnostic-wave/error.beni` | 2/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/session/diagnostic-wave/expected.json` | 6/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/session/diagnostic-wave/repaired.beni` | 2/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/session/diagnostic-wave/warning.beni` | 4/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/corpus/writes/CompleteTailBudget.beni` | 44/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailBudget.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailBudget.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailBudgetAfterReset.beni` | 44/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailBudgetAfterReset.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailBudgetAfterReset.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailCaller.beni` | 44/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailCaller.writes` | 21/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailCoreSummary.beni` | 45/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailCoreSummary.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailEvidence.beni` | 49/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailEvidence.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineCommand.beni` | 60/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineCommand.writes` | 19/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineWide256.beni` | 1596/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineWide256.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineWide512.beni` | 3132/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailInlineWide512.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailKnownCore.beni` | 45/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailKnownCore.writes` | 21/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyKeys.beni` | 359/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyKeys.writes` | 146/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyKeys.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyPrograms.beni` | 201/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyPrograms.writes` | 643/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailManyPrograms.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailOpaque/Helper.beni` | 5/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailOpaque/Main.beni` | 37/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailOpaque/_expected.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailRecursive.beni` | 52/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailRecursive.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailRepeated.beni` | 45/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailRepeated.writes` | 23/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedBudget.beni` | 49/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedBudget.writes` | 22/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedBudget.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedLateBudget.beni` | 49/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedLateBudget.writes` | 22/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailSharedLateBudget.writes-work` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailWide128.beni` | 307/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailWide128.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailWide512.beni` | 1075/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/CompleteTailWide512.writes` | 20/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/StatsPairs.writes` | 1/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/corpus/writes/TodoMVC/_expected.writes` | 8/0 | drop | Complete-tail analysis, synthetic sweeps and internal counters have no delivery consumer. |
| `tests/fixtures/checked-controls/bound-result/Main.beni` | 6/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/direct-input-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/ownership-conflict-v1-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/ownership-conflict-v2-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/parked-input-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/same-type-operand-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/suspending-job-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/wrong-input-slot-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-result/wrong-slot-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/bound-unsupported/Main.beni` | 11/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/callback-identity/Main.beni` | 6/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/late-platform/Main.beni` | 4/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/late-platform/platform/Rt.beni` | 2/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/late-platform/platform/Start.beni` | 7/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/late-platform/platform/beni.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/no-supported/Main.beni` | 2/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/no-supported/expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/ownership/OwnershipFailure.beni` | 4/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/ownership/expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/source/Main.beni` | 31/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/source/app-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/source/ownership-conflict-v1-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/source/ownership-conflict-v2-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/source/suspending-job-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/warning/Warning.beni` | 4/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/checked-controls/warning/wrong-slot-expected.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/Main.beni` | 45/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/platform/Rt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/platform/Start.beni` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/platform/Worker.beni` | 21/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/platform/WorkerRt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/entry-discovery/basic/platform/beni.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-callable/Main.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-callable/TextEncoder.beni` | 6/0 | drop | Deferred typed buffer/static driver or native callable/realm implementation; not the catalogue stage. |
| `tests/fixtures/native-emission/Main.beni` | 6/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-emission/platform/Rt.beni` | 3/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-emission/platform/Start.beni` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-emission/platform/beni.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realm-consumer/Evidence.beni` | 27/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realm-consumer/pending-native.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realm-consumer/physical-sibling.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realm-consumer/unrelated-sibling.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realms/source/platform/Helper.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/native-realms/source/platform/SourceEvents.beni` | 26/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/Library.beni` | 29/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/Main.beni` | 62/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/_expected.cursor` | 219/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/_expected.nominals` | 392/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/platform/Rt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/platform/Start.beni` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/platform/Worker.beni` | 20/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/platform/WorkerRt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/basic/platform/beni.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/cursor/Library.beni` | 31/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/cursor/Main.beni` | 88/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/nominal-layouts/cursor/_expected.cursor` | 373/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/ownership-annotation-dag/Main.beni` | 16/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/Main.beni` | 65/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/_expected.typed` | 507/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/platform/Rt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/platform/Start.beni` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/platform/Worker.beni` | 17/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/platform/WorkerRt.beni` | 5/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/fixtures/typed-entry-roots/basic/platform/beni.json` | 1/0 | drop | Outside the approved fresh-base scope; no port. |
| `tests/native_bindings.zig` | 115/0 | keep | Import catalogue-only d61f2d338a stage; exclude callable candidate and realm dependencies. |
| `tests/session_driver.zig` | 55/0 | drop | Outside the approved fresh-base scope; no port. |

File totals: drop: 348, keep: 41, lane A may need it: 6, separate-PR: 30.

## Commit disposition

Commits with mixed changes are harvested by file/hunk, never wholesale. Merge commits contribute no independent worker feature.

| Commit | Class | Reason |
|---|---|---|
| `d89089960a` | keep | Retain only ratified contract/research paths listed above. |
| `ff8e02df3b` | keep | Retain only ratified contract/research paths listed above. |
| `3e69ebb2f6` | keep | Retain only ratified contract/research paths listed above. |
| `3be7689175` | keep | Retain only ratified contract/research paths listed above. |
| `9d98177312` | keep | Retain only ratified contract/research paths listed above. |
| `b46f4835ca` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `3d353822c8` | keep | Retain only ratified contract/research paths listed above. |
| `7ba0b013fe` | keep | Retain only ratified contract/research paths listed above. |
| `1148877b0e` | keep | Retain only ratified contract/research paths listed above. |
| `c7ee46a23f` | keep | Retain only ratified contract/research paths listed above. |
| `44aaab2f47` | keep | Retain only ratified contract/research paths listed above. |
| `128902faf2` | keep | Retain only ratified contract/research paths listed above. |
| `aae4c97aed` | keep | Retain only ratified contract/research paths listed above. |
| `ffe27b1bf2` | keep | Retain only ratified contract/research paths listed above. |
| `2e1fb13f04` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `ed355f96fd` | keep | Retain only ratified contract/research paths listed above. |
| `93f0ec1890` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `810bfc9212` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `cff1b44175` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `ff806b1480` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `6e220157fa` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `455ce88479` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `fdbffc0dd4` | keep | Retain only ratified contract/research paths listed above. |
| `ea77baeee9` | keep | Retain only ratified contract/research paths listed above. |
| `d61f2d338a` | keep | Harvest entry runtime contract and catalogue only; master fixes separate, typed buffer dropped. |
| `f249522836` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `e9dc0c1791` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `ec03f09fc4` | lane A may need it | Dynamic-import IR, effects and printer support for bootstrap loading; only src/static_ui_main.zig is dropped. |
| `e615870cd5` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `67f7e61a97` | separate-PR | #1378 scalar String class master defect. |
| `eb89c341fd` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `97d15b3c61` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `b532980a9f` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `1b8304b6cb` | keep | Retain only ratified contract/research paths listed above. |
| `a2ab6b6e35` | keep | Runtime arrow alias transparency and behavioural tests. |
| `7eca9716c9` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `a4c75f36c8` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `fef928da42` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `07cd108a9c` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `47b2ff1119` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. Extract master fixes listed above into separate PRs. |
| `6bb3f0f7ea` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. Extract master fixes listed above into separate PRs. |
| `deb1b262bd` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. Extract master fixes listed above into separate PRs. |
| `a98cb76c45` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `25638416c7` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `bfa1d9e40e` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |
| `4c326adfe2` | drop | Proof/evidence, deferred code, old implementation notes or merge-only changes. |

## Cleanup and correctness checks

All 19 old `workers-*` worktrees were inventoried and removed. None had
commits absent from both source branch and master. Tracked source diffs,
untracked source archives, status and short human notes are preserved under
`~/worktree-evidence/workers-*/`; the queue prototype and native/type drafts
are included. The full path/HEAD/branch/status inventory and untouched-lane
sizes are in `~/worktree-evidence/wd-triage/cleanup.md` on dagon. Disk use
fell from 583G to 447G (about 136G); `df -h ~` reported 1.4T available.
No other lane or the shared Zig cache was deleted.

`test-native-bindings` passed, including a real compiler check of all 1,165
generated nominal types. The generator suite stays outside gates under the
owner directive. No generator-speed or budget claim is made.
The generator imports only Idl and std; no native solver or callable rows.

There are no changes under `src/check/` or `src/cache/`, no dispatch/cache
format bump, and no new per-module analysis. Entry contract validation returns
immediately when the build has no `entryKinds`.

Alias regression: `build/bad/EntryRuntimeAlias` was accepted (exit 0) with
only a2ab6b6e35 removed, and refused with the complete expected
`entry_runtime_suspends` diagnostic (exit 1, no output) after restoration.

Byte identity: master `08d708a361280b81c5757be17161523b52b810e1`, built once before the port in this worktree.
The existing corpus harness compiled both versions with the same inputs,
flags and output paths, then recursively byte-compared every emitted file.
Run and browser fixtures used their dev/release passes; emit fixtures also
compiled in the opposite mode to cover both. Counts (including harness variants):

```text
   1777 dev
   1768 release
```
No output differences, including 15 Cloudflare corpus projects in both modes.
The full unfiltered `zig build gates` passed once under the shared lock with
the watcher stopped. The two new generic-runtime fixtures have no master
equivalent and are tested by their behaviour and diagnostic fixtures.
