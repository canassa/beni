# Custom entry runtimes

A custom platform can use an entryKinds manifest row to select a beni runtime
module for its Program type. The module exports run with one Program argument
and a unit result. Run must return without suspension. It can start a root fiber
whose initialization suspends. A runtime module does not need a markup lowering.
The compiler checks the runtime contract in check and build. Invalid metadata
or a wrong runtime signature reports invalid_entry_kind. A run that may suspend
reports entry_runtime_suspends.

Entry parameters marked `wire` must contain serializable values. Functions, native
handles and `Js.Value` cannot cross. The compiler reports
`worker_message_not_serializable` with the field path. Convert that field to a
concrete value before sending it. Worker-local state can contain functions and
native handles. Generic functions retain the obligation until they are applied.

Sources: `docs/design/workers.md` §3, §5; `docs/design/workers-entry-implementation.md`; `docs/design/boundary.md` §5.
