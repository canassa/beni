## 2026-11-02 16:59 CET — Omit stable worker Wire plans

**What I did**

Removed the normalization interpreter and runtime plans from built-in worker
entries whose reachable connections all have clone-stable Wire roles. Lowering
passes their payloads directly; reachability drops the unused interpreter. Lists,
open rows and type variables keep selective normalization. The build-wide field
and tag assignment still uses the complete Wire artifacts. No runtime storage or
core module changed.

Added primitive and List Chrome fixtures plus development/release assertions on
interpreter source maps and plan metadata. The emission assertions failed with
the implementation stashed. All managed Chrome fixtures passed in both modes.
Measured the original paired hosted pages before and after with the byte-ledger
script, including imported files and core in each entry's transfer total.

**What I learned**

The decision belongs to each entry's live connections, not all Programs in the
source graph. A page and a worker can need different normalization machinery.
Embedded runtime lowerings must also bypass their ordinary cached emit rows when
this entry-specific decision changes their code. Only the built-in runtime
accepts omitted stable plans; custom runtimes retain their existing plan contract.
The full hash recorder also reached Node’s default heap limit on existing
400,000-fiber stress programs. Their emitted trees matched baseline exactly;
recording them needs a larger Node heap, without changing the tests.

The stream/chunk normalization request is future transport work: no public
stream operation or Stream/Chunk send is built yet. The manager declined a
fixture-only wrapper and moved that issue to streaming. I discarded the partial
four-line runtime change before starting this optimization.
