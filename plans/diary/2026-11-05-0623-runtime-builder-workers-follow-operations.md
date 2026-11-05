## 2026-11-05 06:23 CET — A runtime builder's workers follow the operations a build runs

**What I did**

- Measured #176 on master `99355536bc`: a program that built a dynamic schema paid 0.4–0.8 kB of release brotli for core's compiled makers beside the interpreter. The owner answered that the interpreter is removed (#1789, #1815), so I dropped my master prototype and closed #176 as superseded.
- Measured the same question on `workers-hostfree`. The two-engine cost is gone, but every runtime builder made all seven workers. `run/SchemaDescribe`, which only describes, paid 37 % of its release bytes for workers it never runs. The owner asked for a fix on `workers-hostfree` (#1943).
- Specified it (`schema.md` §6, A.15; `backend.md` §9, *An operation is a node*), then built it. Each operation is a Reach node. The runners and slot makers reach it. A worker field of a `core/Schema` worker set waits on it. Lower writes a dead worker field as `undefined` through `dead_arms`, so EmitPack's `arm_dead` fact lowers a packed unit again when the answer differs.
- Found #1944 on the way: `Schema.decode (Schema.erased (X.schema ⊤))` stopped the program when it called no `read`, on master and on `workers-hostfree`. A declaration's worker sets now wait on the same operation nodes, and `erased`'s read of `read` reaches that node. `run/SchemaErasedDecode` fails before and passes after.
- Gates on the base `e6e796fd5d` and on the head: the same 4 failing tests and the same 147 failing cases.

**What I learned**

- A guard that the release specialiser cannot see through costs more than it saves. The primitives as a worker set broke the fusion of `Schema.value`'s worker into its runner (`emit/release/app/SchemaWorkerFusion`, 1 627 → 1 775 raw bytes). I kept `scalarSchema` as it was and opened #1958.
- `--core-root` output is not comparable with the embedded core's output: compare two cores through `--core-root` on one compiler.
- BIR is post-order, so a record field's value is the instructions from its subtree's first instruction to its root; `Bir.operands` finds the first one.
- The ownership core golden names `core/Schema.beni` line numbers, so a core edit moves an already red golden. Compare the actual output of base and head, not only the pass or fail result.
