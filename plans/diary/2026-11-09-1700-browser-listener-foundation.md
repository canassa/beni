## 2026-11-09 17:00 CET — Renderer-free listener foundation

**What I did**

Added the renderer-free browser-base package and its scoped listener entry.
The Node EventTarget fixture failed before the package existed and passes
in development and release. It checks nested registration, captured entry
identity, restoration after a recognized exception, direct mode and removal.
Generated the package API reference and updated platform and ownership
registries. Existing renderers still use their original Listen modules;
removing those duplicates together is the next slice.

The manager granted sequential gates and Chrome runs for the foundation
plus the separately committed driver repair and clean master 620c322a45.
All used zorg 0.17.1+zorg.3 and Node 24.19.0, with no Contract.zig patch.
Gate failure identities match exactly: six ownership goldens, two ownership
CPU budgets and two APFS case-folding tests. Chrome passes 744 of 745 cases
on both; only tea/DomCapabilities fails. No golden or budget changed.
Saved exact comparisons in zig-out/scratch/foundation-final-*-comparison.json
and released the slot with no job running.

**What I learned**

A renderer-independent listener can retain a checked synchronous entry
without importing either renderer. Empty inline output remains byte-for-byte
identical, including prerendered variants. Cmd/Sub, capability moves and
inline command/subscription completion remain outstanding. Next, wire both
renderer chains to this shared listener and prove nested reader/send order
with a fixture that fails first. All commits remain local.
