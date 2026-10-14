# Browser-direct effects: implementation and stop condition

2026-10-14. Native `zorg` backend, Node 24.19.0; LLVM was not used.

The resumed implementation supplies `Tea.element`, `Tea.document` and
`Tea.application` through compiled handlers. The beni command driver retains
Restart/Queue/Ignore/Concurrent policies, owned sends, value-taking commands,
subscription relays and scope cleanup. Subscription conflicts come from
anchored reads, including tagger captures. Dispatch end handles rendered waits
and after-render work; `flush` exports the specified no-op.

The paired browser corpus covers the command, policy, subscription, navigation
and document cases against one golden, in development and release, with value
fuzz. Four phase-instrumented cases retain separate platform transcripts under
Q2/Q3: `FlushLatched`, `FocusInFlush`, `SyncCommandOrder`, and
`DefectQueuedDropped`. No assertion was removed. The first three observe the
specified absence of a render loop; the last observes direct sends finishing
before the next command throws.

The saved attempt had two compiler defects: tuples were read as arrays, and
command closures captured the subsequently replaced model. Validation found
shared comparison evidence escaping a sibling handler's lexical scope,
record/tuple message access paths being discarded, and controlled checkbox
activation being restored between click and change. Corpus fixtures retain
those boundaries, including `ListKeyRestart`, `RecordMessagePath`,
`ControlledOnCheck`, `OwnedCommandSend`, `RenderedSends`, and `TodoRouting`.

Fifteen unchanged browser-tea programs still hit conservative ownership
summaries on direct. Their sources, correct transcripts and scripts are in
`tests/pending/browser/direct/`, CK-223, with exact diagnostics in `RED`.
The full editing TodoMVC is among them. No `List.copy` was introduced.

## Same-batch release bytes

The routing variant is `bench/todomvc/apps/beni/NoEditing.beni`, the specified
routing build without editing; the sandbox is that directory's `Sandbox.beni`.
Both were built from the same compiler with `--release --no-cache`, once per
platform. Sizes cover `_main.mjs`, the complete scope-hoisted release program,
compressed with Node's brotli quality 11, without HTML or CSS.

| Variant | browser-tea raw | browser-tea brotli | browser-direct raw | browser-direct brotli |
|---|---:|---:|---:|---:|
| Sandbox | 16,391 | 6,169 | 14,679 | 5,359 |
| Routing without editing | 21,757 | 8,258 | 28,919 | 9,691 |

Routing direct is **17.4% larger** than browser-tea. The existing TodoMVC parity
runner, opened at `#/active`, passes add, counter, toggle, initial filtering,
hash routing, persistence, toggle-all and clear-completed on both routing
builds, with no runtime errors. Editing is deliberately absent in this variant.

**`browser-direct.md` §13 kill criterion 6 fires.** The required routing
TodoMVC bytes do not improve on today's platform. Sandbox's smaller bundle
does not discharge that condition. Stop the design here: the three timed
messages, comparison to vanilla and Svelte, and slices S6/S7 are not pursued.
This is a negative result, not a speed or size parity claim. The implementation
is preserved for review; it must not be merged as a successful slice.

Reproduce sizes using `bench/todomvc/direct-size.mjs` and the parity runner with
each emitted routing `_main.mjs`. The full editing page's ownership blocker
remains independent of this size result.
