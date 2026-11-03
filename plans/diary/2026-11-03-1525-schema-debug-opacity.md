# Keep Schema engine state out of Debug output

The Schema storage rewrite changed its implementation from a foreign value to a
Beni opaque constructor. The existing DebugToStringModules fixture therefore
printed private identities, callbacks and worker state where its golden requires
`<internals>` (also under Just).

The checked Debug descriptor now uses its opaque code for core Schema.Schema.
This keeps the existing public output without adding a runtime check or changing
checked-data validation. The language and backend documents state that rule.

The original mismatch reproduces twice in development and release. The existing
golden then passes twice in both modes, first with a one-shot Debug compiler,
then through the targeted ReleaseSafe corpus test. No expected output is changed.
A watcher started before its first build was ready produced a stale compiler; it
was stopped and the one-shot build's changed build ID verified before validation.

Evidence: `~/worktree-evidence/hostfree-review1/schema-debug/`. Full gates and the
complete run-hash refresh remain for the completed hostfree PR under the shared
lock. This checkpoint addresses review item6, part of #1295 and #1612.
