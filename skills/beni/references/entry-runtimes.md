# Custom entry runtimes

A custom platform can use an entryKinds manifest row to select a beni runtime
module for its Program type. The module exports run with one Program argument
and a unit result. Run must return without suspension. It can start a root fiber
whose initialization suspends. A runtime module does not need a markup lowering.
The compiler checks the runtime contract in check and build. Invalid metadata
or a wrong runtime signature reports invalid_entry_kind. A run that may suspend
reports entry_runtime_suspends.

Sources: `docs/design/workers-entry-implementation.md`; `docs/design/boundary.md` §5.
