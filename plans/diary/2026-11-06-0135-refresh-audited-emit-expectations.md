## 2026-11-06 01:35 CET — Refresh audited emit expectations

**What I did**

Rebuilt all 77 inherited cases on f6059fac92, reran the program-AST, runtime,
host/IO, focused shape and worker import audits, and refreshed only the 56
individually approved emit rows. Kept the 18 temporary typed-List costs in
separate commits. Replaced SpecStatements' untyped callback escape with a
synchronous typed test adapter, and added a development/release execution test
that also invokes the retained callback from the host. The original fixture
and new scenario failed before the adapter; both pass with it. No production
code, budget or publication rule changes.

**What I learned**

Five approved snapshots shrink further after the token-free browser queues:
EmptyPage 835 B, TemplateOneFlag 2853 B, WindowSize 3038 B, HolesPage 3363 B,
and WorkerEventsLeaf 11914 B. The old snapshot failures hide worker-entry and
file-inventory expectations, which need their own audits. WorkerEventsLeaf's
accepted cost remains #2109 debt before master. Html.text proof work is #2110
and stays deferred. Twenty diagnostic/Schema/native-wrapper failures remain
outside this refresh.
