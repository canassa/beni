# Custom entry runtimes

A custom platform can use an entryKinds manifest row to select a beni runtime
module for its Program type. The module exports run with one Program argument
and a unit result. Run must return without suspension. It can start a root fiber
whose initialization suspends. A runtime module does not need a markup lowering.
The compiler checks the runtime contract in check and build.

A launch declared in entryKinds needs a reference to a top-level Program value.
Aliases and finite if or case choices between these references are supported.
A runtime factory fails with worker_entry_not_static. Build discovers nested
launches and emits each worker at `_workers/<stable-id>/_main.mjs`. Each entry
has its own reachable definitions and initializers. Worker URLs are relative to
the generated module. Library builds refuse reachable launches and exported
worker Program values. The public browser platforms have no worker API yet.

Sources: `docs/design/workers-entry-implementation.md`; `docs/design/workers.md`
§2–§3, §7; `docs/design/boundary.md` §5.
