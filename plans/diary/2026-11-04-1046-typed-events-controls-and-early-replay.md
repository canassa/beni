## 2026-11-04 10:46 CET — Typed events, controls and early replay ported; waiting on wiring

**What I did**

Took over lane wd-dom-events from a Codex agent. Finished and pushed the
event/control native catalogue (Node/Event/control reads and writes, capture
listeners, Set, the early-capture records and the early-listener table), then
wrote `platforms/browser/Rt/Events.beni` (fire, delegation, bubbling, the
element's own listener, controlled inputs on the 1.29 typed control chain)
and ported Inline's capture handoff, listener notes and replay to the typed
natives. Rt.Events is not wired; a dev and a release emit golden pin it.

**What I learned**

`written` on a host container's receiver makes v2 refuse every write through
a handle read from a map or cell (`unknown`) and every read after a write
(`later-use`), which is the only way such a table is used. The early-listener
append now borrows its receiver, as `Array.push` does; wd-hf-dom hit the same
wall with `rendererTruncate`. The 1.29 control chain costs 48 B in one object
for a one-property node, half the old 96 B in two. All browser/prerender
fixtures fail on the hostfree-dom base in their release prerender build
(`--check-call-graph`, #685), so the Inline replay port cannot be checked
by them yet.
