## 2026-11-01 12:15 CET — Specify source realm builder

### What I did

Created the isolated workers-realm-builder lane from exact combined tree 7de8d098eefc918dd7e358edb54780576f1c9aa6. Wrote the normative builder input/output, identity, lifetime, residual and linear field-directory contract before implementation. Coordinated exact consumer accessors and the distinction between code retention, callable value flow and demanded execution. Part of #1295 and PR1304.

### What I learned

The current Source artifact retains original child IDs but field names must come from the same checked BIR.Field rows. Imported values need Interface.Provenance.valueDecl, not value-index-as-declaration. A known function result can forward to its original body port without specializing actuals; formal-dependent results remain residual. CompactGraph.live_nodes alone does not establish function execution. The independent builder and selected-root consumer need a shared original-port obligation boundary without transitive environment products.

No compiler edits, builds or tests in this checkpoint. Root boundary review precedes broad implementation; parent full gates run separately.
