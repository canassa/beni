## 2026-11-01 12:07 CET — Compose native source and bound control

**What I did**

Composed independently reviewed native Phase1 patch9d2c6f1d, authority tests653acc1b,
Session request wiring4ac40bd6, and the accepted C bound-result refinementb795433f
with frozen realm source checkpoint6d760ef7 on emitter/Cbasebe99. Three Phase1
conflicts were resolved by keeping both the realm request and actual native source
supplier fields; InvalidRealmSelection and InvalidNativeBinding both remain.
Bindings.acceptsCached is still the FIRST common admission predicate, followed by
required source presence and current intrinsic-context/source inventory validation,
before installation. Native attestation cannot be replaced by lexical source data.
C SourcePlan schema2 advances private Dispatch20to21 intentionally; RealmSource
stays schema1 and public Interface18 remains unchanged. No consumer code was added.

Combined self-hosted Debug0778d9adbfb526b14b98516590ed63d738950e40f17f783f88efb1b71fc80da6
builds. Registered realm source3 and checked-control33 all pass on that exact CLI,
normal blackbox environment and actual Node24.19.0 metadata. Immediately before
C composition, native5 and source3 all passed on Phase1/sourceDebug79ca1c3f;
C did not change native source/acceptance semantics. The two native Session
candidate targets now pass with the actual source recorder wired and the existing
1000ms unit guard (filtered build88steps/11aggregate includes unrelated/import
checks). Their exact standalone replay also passes. Source semantic cache test now
explicitly expects outer private21 and retains its final source-column locator.

**What I learned**

The reviewed patches compose without weakening the two independent authorities:
ordinary native type/effect/supplier attestation, and complete original-source
inventory/context validation. Phase1's generated candidate remains awaiting_realm
and Emit still refuses its execution; no lowering was enabled. Actual selected
execution/value-port realm consumer, returned/field/static callable flow tests,
attested-seed discharge and any public completion/lowering remain future work.
No ownership-v2 work, new source/effect/type rules, privilege exception, budget
waiver, full gates, LLVM or timing claim here. Root will independently materialize
this concrete combined tree and run final unfiltered gates before subsequent work.

All six prerequisite patches were copied and hash-verified into this lane's
scratch/accepted-prerequisites. Current source, fixtures, used test ELFs and CLIs
have no runtime/build/input dependency on old workers-native-callable or
workers-control-bound-result lanes. Their parent-verified archives can be cleaned
by their owner; this active workers-native-realms lane must remain until root
retrieves and verifies its eventual full evidence archive.
