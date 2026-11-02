## 2026-11-02 21:02 CET — Typed cells and optional runtime slots

**What I did**

Implemented core/platform-only Js.Cell and Js.Opt without changing Task or
Chain. Added typed field selection and stores, unboxed optional constructors
and safe branching/defaults, retained generic payload constraints, and release
representation protection. Added behavior, emission, refusal, worker-boundary,
ownership and warm-cache regressions. The isolated Link micro case retained
112 bytes per node with Ref/Maybe and 56 with Cell/Opt.

**What I learned**

An optional wrapper must remain boxed when unboxing could expose undefined,
and that fact must survive cache type-reference remapping. Interface decoders
must admit the new parameter kinds. A mutable cell's initial field set must
survive field pruning so later stores keep its hidden class. First-class
intrinsic functions need shared module identity. Existing JavaScript bytes and
user mappings stay unchanged; the edited Js source text in maps changes, as
confirmed with the delivery manager.
