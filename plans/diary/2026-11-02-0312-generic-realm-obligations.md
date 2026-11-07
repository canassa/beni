## 2026-11-02 03:12 CET — Generic realm obligations

**What I did**

Replaced the concrete writer-name stopgap with realm-only dependencies on
unknown scheme variables. Generic writers and erasers now publish their
obligations through interfaces and discharge them at each caller's concrete
type, including dot calls, aliases, local copies and imported wrappers. The
interface format rejects records from before this contract. Updated the worker
contract and developer skill to remove the generic-erasure gap.

Added sixteen bad regressions and their portable twins, plus shared concrete
and generic store cases used independently by the page and worker. Each bad
probe builds on the parent compiler. Checked cold/warm imported interfaces,
Chrome development/release pages, and byte-identical ordinary development and
release output, including local pure and suspending callbacks.

**What I learned**

Unknown types need realm source nodes without acquiring effect rungs. A local
generic copy must connect its concrete callable realms without joining that
callback's purity or suspension class. Chromium's Unix socket limit also needs
a short path to this lane's disk-backed scratch directory.
