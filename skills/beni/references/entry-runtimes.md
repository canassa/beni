# Custom entry runtimes

A custom platform can use an entryKinds manifest row to select a beni runtime
module for its Program type. The module exports run with one Program argument
and a unit result. Run must return without suspension. It can start a root fiber
whose initialization suspends. A runtime module does not need a markup lowering.
The compiler checks the runtime contract in check and build. Worker entry discovery
and worker launch APIs require the other worker implementation steps.

The generated Browser.Host.TextEncoder module exports new with type
⊤ → TextEncoder. A custom runtime can use it when its selected Program has no
type parameters and its entry kind has no constructor, launch or callback roles.
The compiler checks the current entry and retained functions before emission.
An unresolved callback, library or program-lowering obligation reports
not_implemented. The constructor evaluates its unit argument once, then calls
the host constructor with no arguments. An unexpected host error stops execution.

Sources: `docs/design/workers-entry-implementation.md`; `docs/design/boundary.md` §5;
`docs/design/workers-native-emission-authority.md` §§8–20.
